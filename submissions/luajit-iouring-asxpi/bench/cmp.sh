#!/usr/bin/env bash
# usage: cmp.sh <label> lua|rust   — total process CPU (user+sys, all threads) / k6 requests
set -u
S=$(dirname "$(readlink -f "$0")"); R=/home/asxpi/Code/projects/asxpio/twelve-dollar-server-challenge
LJ=/nix/store/k5n0h079afl26rppwz1ca98d2rwdjcwf-luajit-2.1.1785763465/bin/luajit; K6=/nix/store/lflccyrbv7hzjqppjr2a0njr2xam93d4-k6-2.3.0/bin/k6
label=$1; which=$2
rm -f $S/db/feed.db*; cp $R/seed/feed.db $S/db/feed.db
export SQLITE_PATH=$S/db/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=3111
if [ $which = lua ]; then taskset -c 3 $LJ $R/submissions/luajit-iouring-asxpi/src/main.lua 2>$S/$label.srv.log &
else taskset -c 3 $S/../rust/target/release/feed-server 2>$S/$label.srv.log & fi
pid=$!
for i in $(seq 50); do curl -fs http://127.0.0.1:3111/health >/dev/null && break; sleep 0.2; done
c0=$(awk '{print $14, $15}' /proc/$pid/stat)
taskset -c 4-15 $K6 run -q --no-usage-report -e VUS=$VUS -e SCALE=$SCALE -e RAMP_UP=$RAMP -e DURATION=$DUR $S/load.js > $S/$label.k6.log 2>&1
c1=$(awk '{print $14, $15}' /proc/$pid/stat); rss=$(awk '/VmHWM/{print $2}' /proc/$pid/status)
kill $pid; wait $pid 2>/dev/null
reqs=$(grep -E 'http_reqs\.' $S/$label.k6.log | awk '{print $2}'); fail=$(grep -E 'http_req_failed\.' $S/$label.k6.log | awk '{print $2}')
echo "$c0 $c1 $reqs" | awk -v L=$label -v W=$which -v F=$fail -v M=$rss '{u=($3-$1)*1e4; s=($4-$2)*1e4; printf "%-8s %-4s reqs=%d user=%.2f sys=%.2f total=%.2f us/req  failed=%s peakRSS=%dMB\n", L, W, $5, u/$5, s/$5, (u+s)/$5, F, M/1024}'
