# Techniques in this project

What each technique is, why it matters on a 1 vCPU / 2 GB box, and where it lives. Items marked
**(planned)** are in `plan.md` and not in the code yet.

The budget to keep in mind: at 310k users the server answers ~29k requests a second on one core,
so a request may cost about 34 µs of CPU in total. Roughly 18–19 µs of that is the kernel's TCP
path, which every entry pays. Everything below is about the rest.

## 1. Network: io_uring

**io_uring.** Two ring buffers shared between the process and the kernel: a submission queue
(SQ) where you write requests ("receive on socket 7", "send these bytes") and a completion queue
(CQ) where the kernel writes results. One `io_uring_enter` system call submits a whole batch and
collects a whole batch. With epoll you pay one system call per receive and per send; here a pass
with 30 requests costs one. `main.lua`: `ring_new`, `ring_enter`, `get_sqe`, `reap`.
[Intro paper](https://kernel.dk/io_uring.pdf).

**Raw system calls through FFI.** The server calls `io_uring_setup/enter/register` directly and
maps the rings itself, so there is no liburing and no C helper. LuaJIT's FFI lets Lua read and
write the ring memory as C structs. `cdefs.lua` holds every declaration.

**`SINGLE_ISSUER` + `DEFER_TASKRUN`.** Normally the kernel finishes io_uring work whenever an
interrupt or wake-up happens, which interrupts your code at random points. With these two flags
it promises to run that work only when this one thread calls `io_uring_enter`. Result: the work
is batched, and the thread isn't woken for every packet. Needs Linux 6.1+.

**Batch wait.** `io_uring_enter` is asked to return after N completions or T microseconds,
whichever comes first (`TD_BATCH`, `TD_WAIT_US`). A longer wait means more requests per pass, so
fixed per-pass costs (one transaction, one commit, one system call per ring) are spread over
more requests. The price is latency, and the scoring allows p95 up to 500 ms.

**Direct descriptors.** An accepted socket normally takes a slot in the process's file
descriptor table, limited to 65,535 here. A direct (or "fixed") descriptor lives in a table that
belongs to the ring instead, so it doesn't count against that limit, and the kernel skips a
lookup and a reference count on every operation. `OP_ACCEPT` with `file_index = 0xffffffff`.

**Several rings.** A ring's descriptor table can hold at most `RLIMIT_NOFILE` entries, so one
ring carries ~65k connections. When a ring is nearly full, accepting moves to the next ring
(`choose_accept_ring`). The margin exists because an accept that finds no free slot has already
taken the connection off the listen queue and it would be dropped.

**Multishot accept.** One submitted accept keeps producing a completion per new connection
until it is cancelled, instead of one request per connection. The completion flag `F_MORE` says
it is still armed; without it you arm again.

**`SO_REUSEPORT` listeners.** Eight listening sockets on the same port. The kernel spreads new
connections over them. Each listen queue is capped at `somaxconn` (4,096), so eight queues hold
32k pending connections during a ramp instead of refusing them.

**Multishot receive with provided buffers.** One receive request per connection stays armed
for the connection's life. The data lands in a buffer the kernel picks from a shared pool (a
"provided-buffer ring") and the completion says which one. An idle connection therefore holds no
receive buffer at all, which matters with 300k mostly idle connections. `arm_recv`, `on_recv`.

**ENOBUFS and bounded re-arming.** If the pool is empty, a receive ends with `ENOBUFS`. After a
stall, every connection has data waiting; re-arming them all at once just empties the pool again
and repeats. So those connections wait in a queue and each pass re-arms at most half a pool's
worth (`drain_rearm`).

**Drain first.** A pass reads up to 16,384 completions but answers at most 2,048 requests; the
rest are copied into the connection's own buffer and queued (`ready_push`, `drain_ready`).
Reading is cheap, and a request left unread in its socket holds a 3–4 KB kernel buffer. Emptying
the sockets first keeps the kernel's TCP memory low after a burst.

**Generation numbers.** Every request carries `user_data` that comes back in its completion.
Here it holds the slot and a per-slot generation counter. A late completion for a connection
that was closed and whose slot was reused has an old generation and is ignored.

**CQ overflow.** If completions arrive faster than the CQ has room, the kernel parks them in an
overflow list and hands them over on later calls. Multishot requests are ended instead of
overflowing. Sizing the CQ (32,768 here) to the worst burst avoids both.

**Registered ring fd (planned).** `io_uring_enter` takes the ring's file descriptor and looks
it up on every call. Registering it once removes that lookup. Small gain.

## 2. Database: SQLite

**WAL and `synchronous=NORMAL`.** In write-ahead-log mode a commit appends the changed pages to
a `-wal` file instead of rewriting the database file. With `NORMAL`, a commit is a write into
the OS page cache with no `fsync`; `fsync` happens at checkpoint. A crash of the process loses
nothing; a power loss may lose the last commits but cannot corrupt. The rules allow this.
[WAL](https://www.sqlite.org/wal.html).

**Group commit: one transaction per pass.** All requests of a pass run inside one transaction.
Reads share one snapshot; writes share one commit. No response from a pass is sent before its
COMMIT returns, so a 201 always means the row is committed (rule 6). `td_begin`, `td_commit`.

**B-tree reads instead of SQL.** A `SELECT` runs through SQLite's parser-generated bytecode
engine and copies values in and out. The shim calls SQLite's own B-tree cursor functions
(`sqlite3BtreeTableMoveto`, `Next`, `Previous`, `PayloadFetch`) and returns the raw record
bytes; Lua decodes them. It is still SQLite reading its own file, unmodified, which the
organiser has ruled allowed. Writes still go through SQL. `shim.c`.

**Record format.** A row is a header of varints (one "serial type" per column, giving type and
length) followed by the values. Integers are big-endian in 0–8 bytes; text has serial type
`13 + 2·length`. `app.lua`: `varint`, `intval`, `post_emit`.
[File format](https://www.sqlite.org/fileformat2.html).

**The feed plan.** The index `posts_created_at_id_idx` is already in feed order, so its first
20 entries are the feed. If the 20 ids fall in a narrow range (they normally do), three range
scans answer it: the index for the ids, `likes_post_id_idx` over `[lowest, highest]` for all
like counts, and the posts table walked backwards. Anything unexpected falls back to a seek per
row, so the answer never depends on the data being tidy. `get_feed`, `get_feed_slow`.

**`unix-excl` VFS.** SQLite's stock "exclusive" file layer: the process locks the file once and
keeps the WAL index in heap memory, so there is no `-shm` file and no file locking per
transaction, yet two connections in the same process can still share it.

**Checkpoint on a second thread.** A checkpoint copies WAL pages back into the database file
and `fsync`s, which can take tens of milliseconds. It runs on its own thread and connection, so
the event loop never waits for it. `PASSIVE` mode never blocks readers or the writer.

**`SCHED_IDLE` with a boost.** The checkpoint thread runs at idle priority: it only gets the
CPU when the event loop sleeps. If the loop is saturated the thread would starve and the WAL
would grow without bound, so past 16,384 frames it is switched to normal priority until the log
is small again (`td_ckpt_boost`).

**Write hold.** A WAL can only restart from the beginning once every frame has been copied.
Under steady writes a checkpoint never catches up, so after a round the loop briefly holds
writes (reads continue) while a short second round copies the rest. Capped at 250 ms.

**Page cache, not mmap.** Reads go through SQLite's own page cache (64 MB). A cached page keeps
its parsed header and needs no WAL-index lookup; an mmap'd page pays both on every fetch.

**Compile-time options.** `THREADSAFE=2`, `DEFAULT_MEMSTATUS=0`, the `OMIT_*` flags and
friends remove locking, bookkeeping and unused features from every call.
[Options](https://www.sqlite.org/compile.html).

**Custom VFS for WAL writes (planned).** Stock SQLite writes each WAL frame with two `pwrite`
calls (header, page). A thin VFS layer can gather a commit's frames into one write. A VFS is a
public SQLite plugin interface, so this is allowed. [VFS](https://www.sqlite.org/vfs.html).

**Custom page cache (planned).** `SQLITE_CONFIG_PCACHE2` lets the application supply the page
cache: simpler lookup than the default, and memory you control (see huge pages).

**Huge pages (planned).** The CPU translates addresses through a small cache (TLB). With 4 KB
pages, 64 MB of page cache is 16,384 entries and misses are frequent; in a VM each miss costs
double. `madvise(MADV_HUGEPAGE)` asks for 2 MB pages: 32 entries.

**`sync_file_range` (planned).** Lets the checkpoint thread start writeback in small pieces
before the final `fsync`, so the `fsync` has little left to do and causes no I/O spike.

## 3. Request path

**No allocation on the hot path.** Requests, records, tokens and the response are built in
fixed buffers indexed by plain numbers. Nothing is allocated per request, so LuaJIT's garbage
collector has no work.

**HTTP parsing.** `memchr` finds the end of the head and each line end (libc's version is
vectorised). Only `Content-Length`, `Authorization`, `Connection` and `Transfer-Encoding` are
looked at. A request split across packets is kept per connection until complete.

**HS256 with precomputed pads.** HMAC is `H(key⊕opad ‖ H(key⊕ipad ‖ message))`. The two
key-dependent blocks are hashed once at startup, so each token costs only the message blocks
plus one final block. The signature is still verified for every request (rule 5).

**Constant-time compare.** The signature check ORs together the XOR of every byte pair and
tests once at the end, so the time doesn't reveal how many leading bytes matched.

**JSON escaping, word at a time.** Almost no string needs escaping, so the fast path only has
to prove that and copy the string in one piece. Eight bytes are loaded as one 64-bit number and
tested with bit tricks: `(x − 0x2020…) & ~x & 0x8080…` is non-zero if any byte is below 0x20,
and XOR-ing with a repeated byte first turns "equals that byte" into "equals zero". Three tests
(control characters, `"`, `\`) cover everything JSON must escape.
[Bit hacks](https://graphics.stanford.edu/~seander/bithacks.html#HasLessInWord).

**Overlapping words, no loop.** For a 20-byte string, check the words at offsets 0, 8, 4 and
12: the last two are aligned to the end and overlap the first two. Every length from 16 to 32
takes the same four checks with no loop and no tail handling. `json.lua`, the generated
`escape`.

**Runtime code generation.** The word-check expression is repeated up to 16 times. Written as
a helper function it is slow in LuaJIT (see below), so the code is built as text at startup and
compiled with `loadstring`. Only a runtime with a compiler on board can do this.

## 4. LuaJIT

**Tracing JIT.** LuaJIT interprets code until a loop has run 56 times, then records the exact
path taken once around ("a trace") and compiles that path to machine code. Branches become
guards; when a guard fails often enough, a side trace is compiled from that exit.

**Why a small loop inside a function is expensive.** A loop gets its own trace. Calling a
function that loops over a 20-byte string means leaving the caller's trace, entering the loop's
trace, and coming back: tens of nanoseconds, more than the loop body itself. Straight-line code
is compiled into the caller's trace and costs nothing extra. This is why the looped
word-at-a-time `escape` lost to the plain byte loop and the loop-free one won.

**Blacklisting.** If recording a trace fails repeatedly at the same spot, LuaJIT stops trying
and runs that code in the interpreter from then on, 10–100× slower, silently. A hot helper
function can end up there. `luajit -jv` prints every trace and abort.

**NYI.** Some operations can't be compiled ("not yet implemented"). A trace that meets one is
aborted or stitched. Keep them off the hot path.

**FFI and allocation sinking.** A pointer such as `buf + 5` is a small heap object. In a
compiled trace the allocation is removed ("sunk") if the pointer doesn't outlive the trace. If
it escapes into another root trace or the interpreter, it is really allocated, and the garbage
collector has work. Hence fixed buffers indexed by numbers.
[FFI semantics](https://luajit.org/ext_ffi.html).

**JIT parameters (planned).** `hotloop`, `maxtrace`, `maxmcode` and others are set with `-O`
on the command line. A server with many request shapes can hit the default limits.
[Options](https://luajit.org/running.html).

**The profiler.** `jit.p` samples the running program; `TD_PROFILE=Fl3,24,file` writes which
lines are hot. That is how `escape` (12%) and the users seek (8%) were found.

## 5. The kernel side you can't change but must understand

**TCP memory limit.** The kernel caps the memory all TCP sockets together may hold
(`net.ipv4.tcp_mem`; about 175 MB on a 2 GB box). Above it, it prunes buffers and aborts
connections, which clients see as timeouts and retransmits of 1–3 s. This is how a short stall
turns into a multi-second p99: every connection queues a request, each holding a 3–4 KB buffer.

**Orphans.** A socket whose process is gone but which still has data to deliver lives on as an
orphan. The box allows 8,192; beyond that the kernel resets them at once. Killing a server with
200k connections floods this limit, so wait for it to drain before the next test.

**CLOSE-WAIT.** The state of a socket whose peer has closed (FIN received) while the local side
hasn't. A server that misses the end-of-stream completion leaves sockets here forever.

**Listen queue.** Completed handshakes wait here until accepted. When it is full, new SYNs are
dropped and the client retries after 1 s, 3 s, 7 s.

## 6. Tail latency

**Why p99 fails before the CPU is full.** At 85% utilisation any stall of a few hundred
milliseconds (a checkpoint, a noisy neighbour, a burst) creates a backlog that drains slowly,
because only 15% of capacity is spare. Top entries fail on p99 at 80–97% CPU with no errors.

**FIFO or LIFO under backlog (planned).** Answering the oldest request first makes every
request in a backlog late. Answering the newest first keeps most requests fast and lets a few
wait long, which is better when the limit is "99% under one second".

## 7. Measuring

**µs per request.** The service's CPU time (from its cgroup, user + system) divided by the
number of requests. It is the leaderboard's metric and is far steadier than throughput.

**User and system time.** User is Lua plus SQLite; system is the kernel working on the
process's behalf. The split says where to look: the gap to Rust is mostly user time.

**A/B in alternation.** Run old, new, old, new. Drift (temperature, power state, background
load) then hits both equally, and a real difference shows in every pair.

**Open and closed loop.** The real test is open loop: users think for seconds whether or not
the server is fast. A closed loop (a few connections sending as fast as they can) gives steadier
CPU numbers but changes batch sizes, so it can flatter or hide an effect.

**Ramp.** Every request in a run counts, including those during the ramp. In short runs the
ramp dominates the latency percentiles; compare CPU per request, or run the full five minutes.
