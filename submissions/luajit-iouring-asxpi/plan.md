# Plan: things to try

Updated 2026-11-14. What happened so far is in `HISTORY.md`; this file is the to-do list.

## Where it stands

Test rig: the 1 vCPU Xeon 8260 box, loaded by one generator in the same datacenter (16 vCPU,
six source addresses) running `bench/mload`.

Same load, same protocol (265k users, 60 s ramp, 5-minute hold):

| | Lua v6 | Rust (`rust-iouring-kensac`, #1) |
|---|---:|---:|
| Requests/s | 25,313 | 25,119 |
| p95 / p99 | 1.22 s / 3.51 s | 2.68 s / 6.31 s |
| Failed requests | 0 | 0 |
| µs/req (user / sys) | 25.09 (7.03 / 18.06) | 25.13 (7.27 / 17.86) |
| Peak RAM | 1,678 MB | 1,160 MB |

- Lua and Rust now cost the same per request, and Lua's user time is slightly below Rust's.
- Neither passes the organiser's thresholds (p95 < 500 ms, p99 < 1 s) on this rig at 265k or
  280k. Rust is scored at 310k on his. So this rig ranks servers against each other; it does not
  predict a leaderboard score.
- `mload` sends about 0.105 requests per user per second; the leaderboard's k6 numbers work out
  to about 0.095. 280k users here is about the request rate of 310k there.

Two branches:

- `luajit-iouring-asxpi`: the plain version.
- `luajit-iouring-asxpi-usercursors`: the same plus one users cursor per feed post (about 4–6%
  less CPU on the laptop; a rule 5 question, see `HISTORY.md` section 14).

## Done

- [x] Batching window 4 ms / 4096 by default.
- [x] `json.escape` through a byte scan in the shim (the generated-Lua version made the JIT
      unstable; `HISTORY.md` section 13).
- [x] JSON reader: no loops that are entered and left at once; nothing gets blacklisted.
- [x] `json.uint` without division; one `td_rowid` call per feed row.
- [x] SQLite built with the remaining `OMIT_*` flags.
- [x] Six rings made at startup; empty rings cost no system call; idle sleep with spare rings.
- [x] SHA-256 with eight rounds per loop iteration (2.0 µs per token instead of 5.1).
- [x] Checkpoints that keep up under load: normal priority while a round runs, longer holds
      after a failed one, writes held past 65,536 WAL frames.
- [x] Users cursor per feed post (on its own branch).
- [x] Rig: generator in the box's datacenter; `mload` with `-src` and a source port per user;
      harness drain step; one run at a time.

## Next runs (one at a time)

- [ ] Rust at 250k (running).
- [ ] v6 with users cursors at 265k: does the laptop's 4–6% show on the box?
- [ ] v6 at 250k and 280k, to have Lua and Rust at three loads each.
- [ ] Repeat one pair (Lua and Rust at 265k): Rust's two runs differed a lot (p95 943 ms at
      280k, 2.68 s at 265k), so single runs cannot rank loads 5% apart.
- [ ] Try `mload` with `-think-scale` set so that requests per user match k6 (about 0.095/s).

## To fix or understand

- [ ] **Memory.** Lua peaks 500 MB above Rust (1,678 MB of 1,967). Find what it is: output
      buffer pool (up to 4,096 × 8 KB), six rings' buffers, per-connection stash buffers, the
      WAL in page cache. An out-of-memory kill is an automatic loss.
- [ ] **Checkpoint strain at 265k.** 80 holds ended unfinished, the longest hold was 4.8 s, one
      commit took 3.4 s, the log peaked at 61,650 frames. Options: start rounds earlier
      (`TD_CKPT_FRAMES` below 4,096), `sync_file_range` so the final `fsync` is short, a custom
      VFS that writes a commit's WAL frames in one write.
- [ ] **Backlog state.** It still appears for seconds at a time: 13 passes a second, each
      answering exactly `ANSWER_CAP` (2,048) requests from the ready queue and deferring
      everything new. Try a larger cap, a pool for the deferred-request buffers, and LIFO for the
      ready queue while a backlog exists.
- [ ] **Why this box is harsher than the organiser's.** Candidates: `mload` does not slow down
      when the server does (k6 does); slower disk (`fsync` timing, about a minute to measure);
      38% of the box's CPU goes to network interrupt work.
- [ ] After a mass disconnect ~98k sockets stay in CLOSE-WAIT (Rust leaves them too). Likely
      the kernel's multishot-receive missed-EOF race. Not score-relevant.

## Smaller ideas, not started

- [ ] Compare 2 ms and 8 ms batching windows by µs/req.
- [ ] Huge pages for the SQLite page cache; a custom page cache (`SQLITE_CONFIG_PCACHE2`).
- [ ] Registered ring fd for `io_uring_enter`.
- [ ] `perf` on the box for Lua and Rust at the same load, to compare kernel time by symbol.
- [ ] JIT parameters (`maxtrace`, `hotloop`): only with a stability series.

## Before the PR

- [ ] Choose the branch (plain, or users cursors if the organiser accepts it).
- [ ] README: language and versions, direct (no Nginx), the optimisations and why, and credit
      to `rust-iouring-kensac`, which this server's design and part of `shim.c` follow.
- [ ] Keep `bench/`, `plan.md`, `education.md` and `HISTORY.md` out of the PR branch (the
      challenge wants source only in the submission folder).

## Rules for changes

- A change to hot Lua code is run at least six times with `luajit -jv`; the abort and blacklist
  counts are part of the result. A microbenchmark is not enough (section 13).
- Code generated at load time must not add data-dependent branches inside a caller's loop.
- One box run at a time, explained before the next.

## Don't (rule flags on the leaderboard)

- Coalescing reads across requests, or reusing one request's result for another (rule 5).
- Reads that see uncommitted writes.
- Patching SQLite, an own engine for its file format, or writing `BtCursor` fields.
- PGO profiles committed to the repo.
- Anything needing root or a sysctl on the box (the service runs as `deploy`).

## Measuring

- Box: `tds.service` runs `submissions/$SUB` from `/etc/tds.env` (original saved as
  `/etc/tds.env.orig`). Versions live in `/home/deploy/tds/submissions/`.
- `bench/box.sh <label> <folder-on-box> <users> <ramp> <hold>` does one run: drains both
  machines, restarts the service on a fresh database, runs `mload`, and prints µs/req from the
  service's cgroup. Hosts are in `bench/hosts.env` (not in git). `EXTRA="TD_STATS=1"` turns the
  server's per-second stats on.
- Organiser's protocol: 60 s ramp, 5-minute hold. Compare servers by requests per second.
- Laptop: `bench/run.sh` (k6, small loads) for A/B and stability series only; the power state
  must not change during a series.
- `test/test.sh` needs `openssl` on PATH.
- The shell is zsh: it does not split `$var` into words. Run multi-step harness commands
  through `bash -c`.
