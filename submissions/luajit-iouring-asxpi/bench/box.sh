#!/usr/bin/env bash
# usage: [EXTRA="TD_X=1 ..."] box.sh <label> <submission-folder-on-the-box> <users-per-lg> <ramp> <hold>
# Runs one load test against the box from the load generators and prints one result line.
# Output files go to results/<label>.*
set -u
S=$(dirname "$(readlink -f "$0")")
# hosts.env (not in git) sets TARGET_IP, LG_IPS="ip1 ip2 ..." and optionally LG_ARGS (extra mload
# arguments, such as -src); see hosts.env.example. HOSTS=<file> selects another hosts file.
LG_ARGS=
. "${HOSTS:-$S/hosts.env}"
T=root@$TARGET_IP
LGS=($LG_IPS)
B=$S; S=$S/results; mkdir -p "$S"
label=$1; sub=$2; U=$3; RAMP=$4; HOLD=$5
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
snap='cat /sys/fs/cgroup/system.slice/tds.service/cpu.stat | head -3 | tr "\n" " "; head -1 /proc/stat; cat /sys/fs/cgroup/system.slice/tds.service/memory.peak'
$SSH $T 'systemctl stop tds; for i in $(seq 90); do set -- $(sed -n 2p /proc/net/sockstat); [ "$3" -lt 200 ] && [ "$5" -lt 50 ] && [ "${11}" -lt 500 ] && break; sleep 4; done; sed -n 2p /proc/net/sockstat' > $S/$label.pre.log 2>&1
for lg in "${LGS[@]}"; do $SSH root@$lg 'pkill -x mload; rm -f /root/cmp.json; for i in $(seq 60); do set -- $(sed -n 2p /proc/net/sockstat); [ "$3" -lt 200 ] && [ "$5" -lt 50 ] && break; sleep 4; done' ; done
$SSH $T "[ -f /etc/tds.env.orig ] || cp /etc/tds.env /etc/tds.env.orig; sed -i -e 's/^SUB=.*/SUB=$sub/' -e '/^TD_/d' /etc/tds.env; for kv in ${EXTRA:-}; do echo \$kv >> /etc/tds.env; done; systemctl restart tds; for i in \$(seq 60); do curl -fs http://127.0.0.1/health >/dev/null && break; sleep 0.5; done; curl -s http://127.0.0.1/health; echo" > $S/$label.box.log 2>&1
grep -q '"status":"ok"' $S/$label.box.log || { echo "$label: server did not come up"; cat $S/$label.box.log; exit 1; }
s0=$($SSH $T "$snap")
START=$(( $(date +%s%3N) + 8000 ))
i=0; for lg in "${LGS[@]}"; do
  $SSH root@$lg "cd /root && (ulimit -n 1000000 2>/dev/null || ulimit -n 200000) && ./mload/mload $LG_ARGS -target $TARGET_IP -ports 80 -users $U -offset $((i*U)) -ramp $RAMP -hold $HOLD -start $START -tokens tokens.json -out cmp.json > cmp.log 2>&1" &
  i=$((i+1))
done
wait
s1=$($SSH $T "$snap")
for lg in "${LGS[@]}"; do $SSH root@$lg 'test -s /root/cmp.json' || { echo "$label: no result from $lg"; exit 1; }; done
i=0; for lg in "${LGS[@]}"; do scp -q -o BatchMode=yes root@$lg:/root/cmp.json $S/$label.lg$i.json; scp -q -o BatchMode=yes $S/$label.lg$i.json root@${LGS[0]}:/root/m$i.json; i=$((i+1)); done
$SSH root@${LGS[0]} "cd /root && ./mload/mload -merge -out mtotal.json $(seq -f m%g.json 0 $((${#LGS[@]}-1)) | tr '\n' ' ') >/dev/null 2>&1; cat mtotal.json" > $S/$label.total.json
python3 - "$label" "$sub" "$s0" "$s1" $S/$label.total.json <<'PY'
import sys,json,re
label,sub,s0,s1,f=sys.argv[1:6]
def parse(s):
    d=dict(re.findall(r'(usage_usec|user_usec|system_usec) (\d+)',s)); cpu=re.search(r'cpu  ([\d ]+)',s).group(1).split(); peak=int(s.split()[-1])
    return {k:int(v) for k,v in d.items()}, [int(x) for x in cpu], peak
a,ca,_=parse(s0); b,cb,peak=parse(s1); t=json.load(open(f))
r=t['reqs']; d=[y-x for x,y in zip(ca,cb)]; tot=sum(d[:8]); idle=d[3]+d[4]
print(f"{label:10s} {sub:28s} users={t['users']} reqs={r} req/s={t['req_per_s']:.0f} p95={t['p95_ms']:.0f}ms p99={t['p99_ms']:.0f}ms max={t['max_ms']:.0f}ms err={t['err_pct']:.3f}% pass={t['pass']} | app us/req={ (b['usage_usec']-a['usage_usec'])/r:.2f} (user {(b['user_usec']-a['user_usec'])/r:.2f} sys {(b['system_usec']-a['system_usec'])/r:.2f}) box busy={100*(tot-idle)/tot:.0f}% softirq={100*d[6]/tot:.0f}% steal={100*d[7]/tot:.1f}% peakRAM={peak/1048576:.0f}MB")
PY
