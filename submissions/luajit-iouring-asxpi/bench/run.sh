#!/usr/bin/env bash
# usage: run.sh <label> [ENV=VAL ...]   (VUS, SCALE, DUR via env)
set -u
S=$(dirname "$(readlink -f "$0")"); R=/home/asxpi/Code/projects/asxpio/twelve-dollar-server-challenge
SUB=${SUB:-$R/submissions/luajit-iouring-asxpi}
LJ=/nix/store/k5n0h079afl26rppwz1ca98d2rwdjcwf-luajit-2.1.1785763465/bin/luajit; K6=/nix/store/lflccyrbv7hzjqppjr2a0njr2xam93d4-k6-2.3.0/bin/k6
label=$1; shift
rm -f $S/db/feed.db*; mkdir -p $S/db; cp $R/seed/feed.db $S/db/feed.db
env "$@" TD_STATS=1 SQLITE_PATH=$S/db/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=3111 \
  taskset -c 3 $LJ $SUB/src/main.lua 2> $S/$label.srv.log &
pid=$!
for i in $(seq 50); do curl -fs http://127.0.0.1:3111/health >/dev/null && break; sleep 0.2; done
taskset -c 4-15 $K6 run -q --no-usage-report -e VUS=${VUS:-24000} -e SCALE=${SCALE:-10} \
  -e RAMP_UP=${RAMP:-15s} -e DURATION=${DUR:-40s} $S/load.js > $S/$label.k6.log 2>&1
kill $pid; wait $pid 2>/dev/null
# steady window: stats lines with the full connection count
python3 $S/sum.py $label $S/$label.srv.log
grep -E 'http_req_duration|http_req_failed|http_reqs' $S/$label.k6.log | sed 's/^ */  /'
