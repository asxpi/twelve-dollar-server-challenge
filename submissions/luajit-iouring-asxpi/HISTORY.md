# Improvement history

Every change and experiment, in order, with what was measured and what was decided. New entries
go at the bottom. `plan.md` holds what is still to try; this file holds what happened.

Conventions:

- **µs/req** is the service's CPU time (cgroup, user + system) divided by requests: the
  leaderboard's metric. "Box" is the 1 vCPU Xeon 8260 test box (Ubuntu 24.04, kernel 6.8), loaded
  by five load generators running `mload` (the `bench/load.js` user model).
- Run labels (`z200-lua`, …) name the files in `bench/results/`.
- Laptop numbers were taken on battery at a 2.0 GHz cap over loopback. They are only good for
  comparing two runs of the same series.

## Sources and credits

- **[rust-iouring-kensac](https://github.com/arjaythedev/twelve-dollar-server-challenge/tree/main/submissions/rust-iouring-kensac)**
  (PR #264, #1 at 310k): the design this server follows. `shim.c` shares 10 of its function names
  and 23 of its 180 non-trivial lines with that entry's `csrc/shim.c`, and the event loop uses the
  same scheme (direct descriptors over several rings, eight `SO_REUSEPORT` listeners, drain-first
  with a 16,384 / 2,048 cap, checkpoint thread with a 250 ms write hold). It is also the entry
  every measurement here is compared against.
- **[c-iouring-pavlyhalim](https://github.com/arjaythedev/twelve-dollar-server-challenge/tree/main/submissions/c-iouring-pavlyhalim)**
  (PR #245, 295k): the C entry installed on the test box as a reference. Its code shares
  nothing with this server's shim (one line in common).
- `mload`, the load generator on the box rig, comes from
  [c-uring-willwang](https://github.com/arjaythedev/twelve-dollar-server-challenge/tree/main/submissions/c-uring-willwang)'s
  `tests/official/mload`.

The organiser ruled on 2026-11-04 that building on another entry is fine when the README
credits it, so the PR's README must name rust-iouring-kensac.

## 2026-11-14

### 0. Baseline

Commit `4fa8083`: the server before any of the changes below (1 ms / 512 batching window, byte
loop in `json.escape`).

Laptop profile (share of total CPU): `io_uring_enter` 47%, `json.escape` 12%, users seek in
`post_emit` 8%, `get_feed` 5%, COMMIT 4%, like insert 4%, `post_object` 3%.

### 1. Comparison with the #1 entry (Rust, 310k)

`rust-iouring-kensac` built unchanged and run through the same harness.

| Where | Load | Lua µs/req (user / sys) | Rust µs/req (user / sys) |
|---|---|---|---|
| Laptop | think-time, 20k users, round 1 | 24.08 (11.77 / 12.31) | 22.16 (8.92 / 13.24) |
| Laptop | think-time, 20k users, round 2 | 28.34 (14.00 / 14.34) | 26.52 (11.03 / 15.50) |
| Laptop | saturating, 256 connections | 24.90, 25.61 | 20.64, 20.20 |
| Box | 200k users, 60 s ramp (`x200-lua`, `x200-rust`) | 31.68 (12.39 / 19.29) | 26.13 (7.93 / 18.20) |
| Box | 200k users, 120 s ramp (`z200-lua`, `z200-rust`) | 29.50 (12.60 / 16.90) | 25.33 (8.29 / 17.04) |

Finding: the gap is 16–21% and almost all of it is user time. Rust's box figure matches its
leaderboard figure (25 µs), so the rig is comparable to the real benchmark.

### 2. Word-at-a-time `json.escape`, first attempts (rejected)

- 32-bit words in a loop, pointer cast per call: about 1 µs/req **slower** than the byte loop on
  the laptop (A 20.0 / 20.1 / 19.9 against B 21.7 / 22.0 / 20.35).
- Microbenchmark of nine variants (`bench/esc-microbench/`), µs per feed: byte loop 5.7–6.0;
  scan then copy 4.8; class-table scan 3.7; table scan unrolled 3.6; 32-bit words 6.1; 64-bit
  words in a loop 5.2–5.4; copy only (floor) 0.4.
- 64-bit words, no loop, with a helper function for the word test: 58 µs per feed. The helper
  was blacklisted by the JIT and ran in the interpreter.

Finding: the per-call cost of entering a small loop from another trace dominates, and helpers on
the hot path are dangerous.

### 3. Generated straight-line `json.escape` (kept)

Commit `5011927`. Overlapping unaligned 64-bit words, no loop up to 128 bytes, code generated at
load time; the byte loop remains as fallback. Record buffers +8 bytes.

- Microbenchmark: 2.6 µs per feed against 6.0. Fuzzed against a reference on 300k strings.
- Laptop, saturating load, three alternated rounds: 21.2 / 22.1 / 21.3 against 23.5 / 22.8 / 23.6
  µs/req (−8%).
- Box, 200k (`z200-esc`): 28.00 µs/req (user 9.84, sys 18.15), but 1.4% of requests failed, so
  only the user-time drop of 2.8 µs is trusted. A clean `escape`-only box run does not exist.

### 4. Batching window 1 ms → 4 ms (kept)

Commit `416009e`.

- Laptop, think-time load: no difference within ±1.2 µs noise; checkpoints/s fell from 1.16 to
  0.87 (4 ms) and 0.73 (8 ms).
- Laptop, saturating load: 4 ms looked 9–15% cheaper, but throughput differed between runs.
- Box, 100k against 200k users on the 1 ms window: user time 16.2 against 12.4 µs/req, which
  suggests about 67 µs of fixed cost per pass (inferred from two runs).
- Box, 200k, `escape` + 4 ms / 4096 (`w200-escw4`): **25.21 µs/req** (user 10.04, sys 15.18),
  no failed requests, p95 53 ms, p99 216 ms. Level with Rust (25.33), 15% below baseline.

### 5. Collapse at 200k with the 1 ms window (open)

Box, `escape` + 1 ms window (`w200-esc`): 51.95 µs/req (user 23.40, sys 28.56), box 75% busy at
13k req/s, p95 4.7 s, p99 10 s, 0.14% failed. Not reproduced. Cause unknown.

### 6. v2: integer formatting, one rowid call, SQLite flags (kept, unmeasured)

Commits `13098b9`, `2efb923`.

- `json.uint` in straight-line code, two digits per step, no division: 6.8 ns for a 7-digit id.
  Checked against `string.format` for 0..30M and 4M random values up to 2^53.
- `get_feed`: one `td_rowid` call per row instead of two.
- `build.sh`: six more `OMIT_*` flags, as the Rust entry builds.
- Tests 42/42. Not yet measured on the box; expected 1–2%.

Laptop profile with `escape` and the 4 ms window, before these: `io_uring_enter` 43%, users seek
9%, COMMIT 7%, `get_feed` 6%, `post_object` 4%, `escape` 3%, `uint` 3%, like insert 3%, post
insert 3%, SHA-256 3%.

### 7. 280k probe: failed (open)

Box, `escape` + 4 ms window, 280k users, 180 s ramp, 5-minute hold (`p280-escw4`).

- 153,677 requests timed out, nearly all `GET /feed`; feed p95 29.8 s.
- 431,063 dials for 280k users: clients timed out after 60 s and reconnected.
- Open sockets on the box climbed past the user count to 320k; available memory fell from
  558 MB to 381 MB; the kernel OOM-killed the server 8 minutes after start.
- The service used 344 s of CPU for 8.8M answered requests: 38.5 µs/req, far above the 25.2
  measured at 200k.
- First timeouts fall about 60 s after the fifth ring came into use (four rings hold 242k
  connections). No earlier run used a fifth ring. This is a suspicion, not a finding.

Monitor log: `bench/box-logs/mon280.log`.

### Rig lessons

- The command sandbox and the host's conntrack drop k6's SYNs on the laptop; laptop runs go
  through `unshare -Urn`.
- Runs started straight after another run had 12–100% of dials time out. A stop-and-drain step
  fixed the worst of it, but the second and later runs of a series still lost 0.03–9%. Leaving
  10 minutes between runs has given clean runs every time. Cause not found.
- After 100k clients disconnect at once, about 98k server sockets stay in CLOSE-WAIT (Rust left
  about 200k). With 40k on one ring all closed. Likely the kernel's multishot-receive missed-EOF
  race; not confirmed for this kernel.
- `test/test.sh` needs `openssl` on PATH; without it every authenticated check fails.

### 8. 280k probe of v2 with server stats: saturated, and why (open)

Box, v2 (commit `2efb923`), `TD_STATS=1`, 280k users, 180 s ramp, 150 s hold (`s280-v2`;
per-second server stats in `bench/box-logs/s280-v2.server-stats.log`).

Result: no failed requests and no OOM this time, but p95 4.7 s and p99 16 s. 30.71 µs/req (user
8.59, sys 22.11), box 76% busy over the whole run.

What the stats show:

- Up to 230k connections the loop is healthy: 120–200 passes/s, passes of 2–12 ms.
- At 02:14:07 the fifth ring is created: one pass takes 204 ms and 31k requests are deferred.
- From then on the loop runs 13–15 passes a second of 70–80 ms each. Every pass answers exactly
  `ANSWER_CAP` = 2,048 requests, all of them from the ready queue, and defers every request that
  arrives meanwhile (about 28k deferrals a second). That caps throughput near 27k req/s.
- 280k users send about 29.9k req/s in steady state (0.107 per user, measured at 200k), so the
  cap is below the arrival rate and the queue only grows. Twice the queue emptied for a second
  and filled again.
- The service's own CPU is 84–87% in that regime; with interrupt work on top the core is full.

Findings:

- The earlier estimate that 280k needs ~23k req/s was wrong: it used a run average that included
  the ramp. Steady state is about 30k req/s, which at 25 µs is already 75% of the core before
  interrupt work.
- Once behind, every request takes the deferred path (a copy into a per-connection buffer that
  is allocated and freed each time, and one extra pass of latency), which costs more per
  request than the direct path: falling behind makes the server slower.
- Creating a ring mid-ramp stalls the loop for 0.2 s. Rings should exist before they are needed.
- User time per request (8.59) is close to Rust's (8.29) with v2, even in this regime.

Not known yet: whether this box can carry 280k at all. The Rust entry is being run at 280k on
the same rig as calibration.

### 9. v3: rings made at startup (kept, not yet measured on the box)

Section 8 showed a 0.2 s stall when the fifth ring was created mid-ramp. Each ring holds 60,535
connections (65,535 slots minus a 5,000 margin), so 310k users need six.

- `TD_RINGS` (default 6) rings are made at startup; more are still added on demand.
- A ring with no connections, no accept armed and nothing queued is not entered, so the extra
  rings cost no system call per pass.
- The long idle sleep now applies whenever only ring 1 is in use (before, never with more than
  one ring: 980 passes/s at zero load on the box).
- Tests 42/42. Local check with a 4,096-descriptor limit: 9,000 connections spread over three
  rings, 9,000 correct responses in each of two rounds, all closed afterwards.

### 10. Calibration: the Rust entry at 280k on this rig also fails

Box, `rust-iouring-kensac` unchanged, 280k users, 180 s ramp, 150 s hold (`r280-rust`; monitor
log `bench/box-logs/r280-rust.monitor.log`).

| 280k users on this rig | µs/req | user | sys | p95 | p99 | failed |
|---|---:|---:|---:|---:|---:|---:|
| Lua v2 (`s280-v2`) | 30.71 | 8.59 | 22.11 | 4.7 s | 16.2 s | 0% |
| Rust (`r280-rust`) | 29.91 | 7.59 | 22.32 | 10.4 s | 12.7 s | 0% |

Findings:

- The #1 entry, scored at 310k on the organiser's rig, does not hold 280k here. So this rig is
  harsher than the real benchmark, and a result here cannot be read as a leaderboard score.
  Results have to be compared at equal load on the same rig.
- At 280k the two servers are level: 30.7 against 29.9 µs/req (3%), with the same kernel time.
  Lua's user time is 1.0 µs above Rust's.
- Kernel time is 22 µs/req for both at 280k against 15–17 at 200k. With the core full,
  interrupt work is charged to the service, so µs/req is only comparable at equal load.
- Likely reason the rig is harsher: the load generators are 17 ms away over the internet (the
  organiser's are 0.25 ms away in the same datacenter). Not verified.

### 11. Rig: a load generator in the box's datacenter (set up, not yet used)

A second machine at the same provider, on the box's subnet: 8 vCPU, 10 GB RAM, Ubuntu 24.04,
six IPv4 addresses, 0.34 ms from the box (the Linodes are 17 ms away).

- `bench/mload/` is a copy of the load tool with one addition, `-src`: a list of local
  addresses to dial from. One source address reaches about 64k connections to one target
  address and port, so six cover about 387k users from one machine.
- Generator settings (`/etc/sysctl.d/90-loadgen.conf`): local ports 1024–65535,
  `tcp_max_orphans` 524,288, `tcp_tw_reuse` 1, a larger `tcp_mem`, `fs.nr_open` 2,097,152. The
  box itself stays stock.
- Checked: the tool starts with all six source addresses.
- Smoke test (`t2k-v3`): 2,000 users through the six addresses, no failed requests, connect
  time 0.37 ms at p95, response time 8 ms at p95.
- `box.sh` takes extra `mload` arguments from `hosts.env` (`LG_ARGS`) and merges the results
  of any number of generators.
- The five Linode generators were deleted the same day; the last files from the first one are
  in `bench/box-logs/linode-lg1/`. Runs up to section 10 came from them.

### 12. First 280k runs from the new generator: the generator is the limit above ~200k

Box, v3 and Rust at 280k from the generator in the box's datacenter.

| Run | Ramp | µs/req (user / sys) | Overall p95 | Failed |
|---|---|---|---:|---:|
| `n280-v3` | 60 s | 30.07 (8.98 / 21.09) | 21.0 s | 0.06% |
| `n280-rust` | 60 s | 26.19 (8.14 / 18.05) | 18.8 s | 0% |
| `m280-v3` (stats on) | 180 s | 25.84 (9.47 / 16.37) | 21.2 s | 0.01% |
| `m280-rust` | 180 s | 24.53 (8.33 / 16.19) | 15.4 s | 0.005% |

- With the 180 s ramp both servers were healthy up to 187k users (19.9k req/s; p95 21 ms for
  Lua, 6 ms for Rust) and both stalled at the same moment near 210k users, while the box was
  under 45% busy. The generator's load average was 25–36 on 8 shared vCPUs: above about 200k
  users this rig measures the generator. Latency from these runs says nothing about either
  server.
- With the 60 s ramp the generator was already behind after a minute (204k of 280k users
  started). At the end of that run Rust was serving 30.3k req/s at p95 20 ms; Lua v3 was at
  21.2k req/s and p95 7.6 s.
- CPU per request is still valid: Lua v3 uses about 5% more than Rust at equal load, with the
  same kernel time and about 1.1 µs more user time.
- To do: give the generator 16 vCPUs (the five Linodes had 20 between them) or a lighter tool.

### 13. The generated `escape` made the JIT unstable; replaced by a scan in the shim (kept)

Found on the laptop while preparing the next change: the same build ran at 22–23 µs/req in one
run and at 37–105 in the next.

| Build | Runs | Normal | Slow |
|---|---:|---:|---:|
| baseline (byte loop) | 2 | 2 (24.7) | 0 |
| generated `escape` (`5011927`) | 2 | 2 (22.9) | 0 |
| + integer formatting (`13098b9`) | 2 | 1 (22.8) | 1 (36.9) |
| v3 (`65e7fc8`) | 2 | 1 (22.8) | 1 (51.6) |
| v3, `escape` reworked to keep fewer values live | 13 | 8 (22.0–24.6) | 5 (39–105) |
| scan in the shim | 8 | 8 (22.3–24.5) | 0 |
| + JSON reader changes below | 6 | 6 (22.6–23.3) | 0 |

Cause, from `luajit -jv` logs: in slow runs LuaJIT aborts 1,000–2,200 traces in 20 s with "NYI:
register coalescing too complex", all side traces that start inside the generated `escape`
(its branches on the string length) and have to link back into the feed loop. It never
succeeds and never gives up, so that path stays in the interpreter, FFI calls included. In
normal runs the traces happen to form in an order that avoids it. This is the "collapse" of
section 5 (user time 23 µs/req on the box) and probably part of sections 7 and 8.

Changes:

- `td_json_clean` in `shim.c`: the length of the prefix of a string that needs no escaping (a
  byte scan, eight bytes at a time). `json.escape` calls it and copies that prefix in one
  piece; the byte loop takes the rest. A C call is a fixed boundary for the JIT. The shim is no
  longer "no JSON in C": this one scan is.
- JSON reader: the whitespace loop moved out of `ws` (it was entered on every call and left at
  once, so `ws` got blacklisted and no trace calling it could be compiled), and string scanning
  uses the same shim scan up to the first backslash. Compared with the old reader on 600k
  generated inputs: identical results.
- After both: no trace is blacklisted any more, 24–37 aborts per run (was 84–124), no
  "register coalescing" aborts in 14 runs.
- Tests 42/42. Speed in the laptop runs is that of the generated version's good mode.

Lessons: a microbenchmark and three A/B rounds did not show this; it needed repeated runs of the
whole server. From now on a change to hot Lua code is run at least six times with `-jv`, and the
abort and blacklist counts are part of the result.

### 15. SHA-256 with eight rounds per loop iteration (kept)

HS256 verification was 3% of CPU: about 5 µs per token on the laptop, 8 µs on the box.

- Tried first: all 64 rounds written out as one block of generated code. 1.9 µs per token, but
  LuaJIT refuses it with "trace too long" unless `maxrecord` and `maxirconst` are raised for the
  whole process, which changes how every other trace forms. Not used.
- Kept: a loop of 8 iterations with 8 rounds written out in each. After 8 rounds the working
  variables are back under their own names, so the per-round shuffle disappears. 2.0 µs per
  150-byte token against 5.1, with the default JIT limits.
- Verified: one published HMAC-SHA256 test vector, and equal output to the previous
  implementation on 450k random inputs with three key lengths. Tests 42/42.
- Stability series, laptop, eight runs with `-jv`: 22.4–23.4 µs/req (mean 22.9), no blacklisted
  traces, no "register coalescing" aborts, 25–54 aborts per run. The six runs before the change
  were 22.6–23.3 (mean 22.9): the gain for the whole server is inside the noise here, as expected
  for something that is 3% of CPU and only on writes.

### 16. The load generator's own limit: source ports (fixed)

Every run from the new generator stalled just past 190–200k users, with 8 vCPUs and with 16,
while the generator spent 98% of its CPU in the kernel (load average 30–70).

- Cause: with `-src`, each connection was bound to a source address and the kernel chose the
  port. `bind()` to port 0 searches the port range under a lock; choosing at `connect()` time
  instead (`IP_BIND_ADDRESS_NO_PORT`, tried first) did not help either, because `connect()`
  tries the even ports first and scans all of them once they are used up: about 32k per
  address, and 280k users over six addresses need 47k each.
- Fix in `bench/mload`: every user binds its own source address and port (1024 upward, with
  `SO_REUSEADDR`); after a failed dial it falls back to a kernel-chosen port.
- After the fix, at 280k users: generator 87% idle, kernel time 4%, load average 3, users
  ramping exactly on schedule.
- Runs `q280-*` never started (a quoting mistake in the queue: zsh does not split `$var`), and
  `f280-v5` was taken with the first, ineffective fix. Sections 12's latency figures and these
  runs say nothing about the servers.

### 17. First valid 280k runs: Rust holds with spikes, Lua v5 runs out of memory

Box, organiser's protocol unless noted (60 s ramp, 5-minute hold), healthy generator.

| Run | Outcome | req/s | p95 / p99 | µs/req (user / sys) |
|---|---|---:|---|---|
| `g280-v5` (120 s ramp, 180 s hold) | collapsed to 15k req/s, OOM-killed at the end | 19,691 | 10.0 s / 59.7 s | about 28 |
| `h280-rust` | held, no failures, periodic spikes | 26,905 | 943 ms / 4.15 s | 23.69 (7.14 / 16.55) |
| `k280-v5` (stats on) | OOM-killed after 5 min 25 s | – | – | – |

- Rust at 280k: most 5-second samples at p95 22–34 ms, with spikes to seconds around 100, 140,
  220 and 320–340 s. By the organiser's thresholds this is a fail on this rig.
- `mload` sends about 0.105 requests per user per second; the leaderboard's k6 figures work out
  to about 0.095. So 280k users here is roughly the request rate of 310k there (inferred from
  the two sets of numbers). Compare by requests per second.
- Why Lua died (`bench/box-logs/k280-v5.server-stats.log`, `k280-v5.monitor.log`): the WAL
  stopped restarting. It went from 19,824 frames to 258,652 (about 1 GB) in under two minutes;
  commits took 90–340 ms; the loop made 5–14 passes a second and fell behind; available memory
  fell from 610 MB to 354 MB; clients timed out and reconnected (336k sockets); OOM.
- Cause: the checkpoint thread runs at idle priority, and with the core 85% busy it gets no
  CPU. The hold on writes gives up after 250 ms, the log is not reset, and every later round
  has more to copy than the one before. The Rust entry has a last resort here (the loop
  checkpoints by itself past 65,536 frames), which this server had replaced by a priority
  boost at 16,384 frames.

### 18. Checkpoints that keep up under load (kept, not yet run on the box)

- The checkpoint thread has normal priority while a round runs (and while the log is long),
  idle priority otherwise.
- A hold that ends without the log being copied doubles the next hold's limit (250 ms up to
  2 s); a successful one resets it.
- Past 65,536 frames (`TD_CKPT_FORCE`) writes stay held until the log has been copied. Reads
  go on.
- New counter in the stats line: `hold_fail`.
- Tests 42/42. Laptop, saturating load: unchanged behaviour when healthy (log never above
  5,000 frames, holds of 240–260 ms). With a busy loop stealing the server's core, the old code
  let the log grow without bound (117,726 frames after 60 s and rising); the new code peaked
  at 39,712 and reset it, at the price of holds up to 2.9 s (p99 0.9 s in that test).

### 19. v6 at 265k against Rust at 265k: level

Box, organiser's protocol (60 s ramp, 5-minute hold), healthy generator.

| 265k users | Lua v6 (`v265-v6`, stats on) | Rust (`r265-rust`) |
|---|---:|---:|
| Requests/s | 25,313 | 25,119 |
| p95 / p99 | 1.22 s / 3.51 s | 2.68 s / 6.31 s |
| Failed requests | 0 | 0 |
| µs/req (user / sys) | 25.09 (7.03 / 18.06) | 25.13 (7.27 / 17.86) |
| Box busy / softirq | 79% / 39% | 79% / 38% |
| Peak RAM | 1,678 MB | 1,160 MB |

- The checkpoint change (section 18) holds on the box: no out-of-memory kill, the log reset
  throughout and mostly stayed between 1,000 and 20,000 frames.
- Same CPU per request as Rust; Lua's user time is slightly lower. Latency is in the same class;
  Lua's figures are better in this pair, but Rust's own runs differ more than that (p95 943 ms
  at 280k, 2.68 s at 265k), so this is a tie.
- Still strained: 80 holds ended unfinished, longest hold 4.8 s, one commit of 3.4 s, log peak
  61,650 frames. The backlog state (13 passes a second, everything deferred) still shows up for
  a few seconds at a time.
- Lua peaks 500 MB above Rust in memory, on a 1,967 MB box. Not yet explained.
- Neither server passes the organiser's thresholds on this rig at 265k.
