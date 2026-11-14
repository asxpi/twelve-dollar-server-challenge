#!/bin/sh
while :; do
  echo "$(date +%T) $(sed -n 2p /proc/net/sockstat) avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)MB sunrecl=$(awk '/SUnreclaim/{print int($2/1024)}' /proc/meminfo)MB $(nstat -az 2>/dev/null | awk '/TcpExtTCPAbortOnMemory|TcpExtPruneCalled|TcpExtTCPMemoryPressures /{printf "%s=%s ", substr($1,7), $2}')"
  sleep 5
done
