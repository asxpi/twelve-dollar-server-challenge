#!/usr/bin/env bash
# usage: exp.sh <label> "<TD_X=.. TD_Y=..>" [folder-on-box] [users]
# One box run with the organiser's protocol and server stats on; prints the result line, a few
# 5-second samples from the generator and the checkpoint counters.
set -u
cd "$(dirname "$(readlink -f "$0")")"; . ./hosts.env
label=$1; extra=$2; sub=${3:-luajit-iouring-asxpi-pr}; users=${4:-265000}
EXTRA="TD_STATS=1 $extra" ./box.sh "$label" "$sub" "$users" 60s 300s
ssh -o BatchMode=yes root@$TARGET_IP "journalctl -u tds --no-pager --since -9min | grep conns= | cut -c8-16,45-" > box-logs/$label.server-stats.log
ssh -o BatchMode=yes root@${LG_IPS%% *} 'grep -E "t= *(60|80|100|140|180|220|260|300|340)s|RESULT" /root/cmp.log | cut -c1-125'
f=box-logs/$label.server-stats.log
mx() { grep -oE "$1=[0-9.]+" $f | cut -d= -f2 | sort -n | tail -1; }
sm() { grep -oE "$1=[0-9]+" $f | cut -d= -f2 | awk '{s+=$1} END{print s+0}'; }
echo "wal peak: $(mx wal)  checkpoints: $(sm ckpt)  holds: $(sm holds)  unfinished holds: $(sm hold_fail)  longest hold ms: $(mx hold_max)  longest commit ms: $(mx commit_max)  deferred requests: $(sm deferred)  seconds with deferrals: $(grep -c 'deferred=[1-9]' $f)"
ssh -o BatchMode=yes root@$TARGET_IP "systemctl stop tds; sed -i -e '/^TD_/d' /etc/tds.env; journalctl -u tds --no-pager --since -9min | grep -c 'oom-kill'"
