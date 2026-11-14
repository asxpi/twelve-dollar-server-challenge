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
