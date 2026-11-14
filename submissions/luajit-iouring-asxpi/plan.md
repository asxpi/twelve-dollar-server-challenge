# Plan: things to try

Written 2026-11-14. Goal: get the LuaJIT build to the level of the top entries (310k users).

## Where it stands

Measured on the Xeon 8260 test box at 200k users, app CPU per request from the
service's cgroup (the leaderboard's metric). Only these two runs are clean so far:

| Build | µs/req | user | sys |
|---|---:|---:|---:|
| Lua, current | 31.68 | 12.39 | 19.29 |
| Rust `rust-iouring-kensac` (#1, 310k) | 26.13 | 7.93 | 18.20 |

- Gap: 5.5 µs/req (21%), of which 4.5 user and 1.1 kernel.
- Rust's 26.1 matches its leaderboard figure (25), so the rig is comparable to the real benchmark.
- If both fail at the same CPU level, the current build lands around 255k. That is an
  extrapolation, not a measured score.
- The top ten (280k–310k) are within the benchmark's run-to-run noise (5% steps).

Profile on the laptop (share of total CPU): `io_uring_enter` 47%, `json.escape` 12%, users seek in
`post_emit` 8%, `get_feed` 5%, COMMIT 4%, like insert 4%, `post_object` 3%.

## Done

- [x] Generated straight-line `json.escape` (64-bit word checks, no loop up to 128 bytes), record
      buffers +8 bytes. Tests 42/42. Laptop: −1.8 µs/req. Microbenchmark: 2.6 vs 6.0 µs per feed.

- [x] v2 (2026-11-14, tests 42/42, not yet measured on the box):
  - 4 ms / 4096 batching window is the default in `main.lua` (was 1 ms / 512).
  - `json.uint`: straight-line, two digits at a time, no division (6.8 ns for a 7-digit id).
  - `get_feed`: one `td_rowid` call per row instead of two.
  - `build.sh`: `OMIT_AUTOINIT`, `OMIT_UTF16`, `OMIT_TRACE`, `OMIT_COMPLETE`, `OMIT_GET_TABLE`,
    `OMIT_TCL_VARIABLE`, as the Rust entry builds.
  - Expected gain beyond the window: small (1–2%). Previous sources are in `bench/orig-v1/`.

Profile after `escape` and the window (laptop, share of total CPU): `io_uring_enter` 43%, users
seek in `post_emit` 9%, COMMIT 7%, `get_feed` 6%, `post_object` 4%, `escape` 3%, `uint` 3%,
like insert 3%, post insert 3%, SHA-256 3%.

## To try, in order

### 1. Confirm on the box

Second series, 200k users, 120 s ramp (only the first run of a series is clean; see Measuring):

| Build | µs/req | user | sys | failed requests |
|---|---:|---:|---:|---:|
| Lua, current | 29.50 | 12.60 | 16.90 | 0% |
| Lua + `escape` | 28.00 | 9.84 | 18.15 | 1.4% |
| Rust | 25.33 | 8.29 | 17.04 | 0.03% |
| Lua + `escape` + `TD_WAIT_US=4000 TD_BATCH=4096` | 24.20 | 8.34 | 15.86 | 8.8% |

Re-run after a 10-minute pause, same load, no failed requests (3.90M requests):

| Build | µs/req | user | sys | failed requests |
|---|---:|---:|---:|---:|
| Lua + `escape` + `TD_WAIT_US=4000 TD_BATCH=4096` | 25.21 | 10.04 | 15.18 | 0% |
| Lua + `escape`, 1 ms window (collapsed, see below) | 51.95 | 23.40 | 28.56 | 0.14% |

- [x] `escape` + 4 ms window, clean: 25.21 µs/req, level with Rust (25.33) and 15% below the
      current build (29.50). User time is still 1.7 µs above Rust; kernel time is 1.9 µs below.
      Passed: p95 53 ms, p99 216 ms.
- [ ] **Collapse to explain first.** The `escape`-only run with the 1 ms window went wrong:
      CPU per request doubled (52 µs), the box was 75% busy at only 13k req/s, p95 4.7 s and
      p99 10 s, with just 0.14% failed requests. This is what a failed probe looks like. Not
      reproduced, cause unknown. Suspect: a backlog puts connections on the ready/re-arm queues,
      the loop then stops waiting (`wait = 0`) and runs many near-empty passes, each paying the
      fixed per-pass cost. Reproduce with `TD_STATS=1` and look at passes/s, deferred, rearm.
- [ ] `escape` alone at 200k, clean (still missing because of the collapse above).
- [ ] Make the window the default in `main.lua` once 2 ms and 8 ms have been compared.
- [ ] If the window helps, try 2000 / 8000 and pick by µs/req; latency budget is p95 500 ms.

### 2. Per-pass overhead

- [ ] Measure one pass with nothing to do: BEGIN/COMMIT, opening four cursors, one
      `io_uring_enter` per ring, clock calls. Skip the transaction when a pass has no requests.
- [ ] Idle spin: with more than one ring the loop never takes the long sleep (980 passes/s at
      0 req/s on the box, 1–2% CPU). Let extra rings be idle too.

### 3. Lua layer (remaining user-space gap)

- [ ] `get_feed`: three FFI calls per row (`td_prev` + two `td_rowid`). One shim call that
      returns rowid and payload.
- [ ] Users seek in `post_emit` (now the largest user-space item, 9% + 2% from single posts):
      20 root-to-leaf descents per feed. Idea: one users cursor per feed position. Within a pass
      the feed rarely changes, so the next feed request asks each cursor for the row it is
      already on, and `sqlite3BtreeTableMoveto` returns at once (its own same-key fast path); the
      bytes are still read from SQLite's page for every request. Could be worth ~2 µs/req.
      **Rule question first:** it reuses a cursor position from an earlier request in the same
      transaction. Other entries already rely on the same fast path for consecutive ids, but ask
      the maintainer or state it plainly in the README before shipping it.
- [ ] Generate the record decoders the same way as `escape` (straight-line, specialised to the
      schema).
- [ ] Run the server with `-jv` under load on the box: look for aborted or blacklisted traces
      on the hot path. A helper function got blacklisted once already and ran 10× slower.
- [ ] JIT parameters in `start.sh`: `-Omaxtrace=…`, `maxmcode`, `hotloop`. Cheap A/B.
- [ ] HMAC-SHA256 in pure Lua (writes are ~9% of requests): measure before touching.

### 4. Kernel side (1.1 µs more than Rust)

- [ ] `perf` on the box (installed) for both servers at the same load; diff the kernel symbols.
- [ ] Compare accept strategy (multishot here, single-shot in Rust) and batch size (512 vs 256).
- [ ] Registered ring fd for `io_uring_enter` (small).

### 5. SQLite

- [ ] Add the flags Rust builds with: `OMIT_AUTOINIT`, `OMIT_UTF16`, `OMIT_TRACE`,
      `OMIT_COMPLETE`, `OMIT_GET_TABLE`, `OMIT_TCL_VARIABLE` (expected small).
- [ ] Custom VFS that writes a commit's WAL frames in one write (allowed by the 2026-10-31
      ruling; several entries do it). Stock SQLite does two `pwrite`s per frame.
- [ ] Huge pages for the page cache (`MADV_HUGEPAGE`; THP is `madvise` on the box).
- [ ] Custom page cache through `SQLITE_CONFIG_PCACHE2` (allowed, 12 entries use it).
- [ ] `sync_file_range` to spread checkpoint writeback.

### 6. Tail latency

Top entries fail on p99 at 80–97% CPU with zero errors, not on average CPU.

- [ ] LIFO for the ready queue while a backlog exists (FIFO makes everyone late).
- [ ] Find the limit on the box: probes at 240k / 260k / 280k once the build is settled.

### 7. Bugs found on the way (not score-relevant)

- [ ] After 100k clients disconnect at once, ~98k sockets stay in CLOSE-WAIT (server alive, FINs
      received, never closed). Fine with 40k on one ring. Rust left ~200k open too. Likely the
      kernel's multishot-receive missed-EOF race (fixed upstream in 2026); not confirmed for
      6.8.0-117. The benchmark restarts the app per probe, so the score is unaffected.

## Tried and dropped

- Word-at-a-time `escape` with a loop (32- or 64-bit): slower than the byte loop. The per-call
  cost of entering a small loop dominates, and a pointer that escapes its trace is not free.
- `escape` with a helper function for the word check: the helper is blacklisted by the JIT.

## Don't (rule flags on the leaderboard)

- Coalescing reads across requests, or reusing one request's result for another (rule 5).
- Reads that see uncommitted writes.
- Patching SQLite, an own engine for its file format, or writing `BtCursor` fields.
- PGO profiles committed to the repo.
- Anything needing root or a sysctl (the service runs as `deploy`).

## Measuring

- Box (address in `bench/hosts.env`): `tds.service` runs `submissions/$SUB` from `/etc/tds.env` (original saved as
  `/etc/tds.env.orig`). Variants live in `/home/deploy/tds/submissions/`:
  `luajit-iouring-asxpi-cur`, `-esc`, `rust-iouring-kensac`.
- Load: `mload` on five Linodes (`claude-test-tds-lg1…5`), same user model as `bench/load.js`.
- Between runs: stop the service and wait until `/proc/net/sockstat` shows sockets and orphans
  near zero on the box and the load generators. Restarting straight away leaves the box in TCP
  memory pressure and the next run times out.
- Leave about 10 minutes between runs. Even after a full drain, the second and later runs of a
  back-to-back series had 1–9% of connection attempts time out while the box logged no listen
  drops; the first run after a pause was always clean. Cause not found (suspect: SYN rate
  limiting on the path between Linode and the box).
- Ramp 120 s for 200k users. Latency from short runs is dominated by the ramp; compare µs/req.
- Laptop numbers are only good for A/B, with the power state unchanged during a series.
