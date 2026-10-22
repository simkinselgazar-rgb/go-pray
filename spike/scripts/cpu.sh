#!/bin/bash
# usage: cpu.sh <name> <prayer> <mode: webcpu|shield> <seconds>
# Samples cumulative CPU time of our app + the WebKit helper processes it spawned (new pids vs. baseline) at 4 s and at the end.
cd "$(dirname "$0")/.."; E="$PWD/evidence"; BIN=/private/tmp/gopray-spike/GoPraySpike.app/Contents/MacOS/GoPraySpike
n=$1; p=$2; m=$3; secs=$4
snap() { ps -axo pid=,command= | grep -E "com.apple.WebKit.(WebContent|GPU|Networking)" | grep -v grep | awk '{print $1}' | sort; }
snap > /tmp/gp-base.txt
EXTRA=""; [ "$m" = shield ] && EXTRA="--activate"
("$BIN" $m --seconds $secs --web $p $EXTRA --log "$E/$n.log" >/dev/null 2>&1 &)
sleep 4
APP=$(pgrep -f "GoPraySpike.app.*$m --seconds" | head -1)
snap > /tmp/gp-now.txt; NEW=$(comm -13 /tmp/gp-base.txt /tmp/gp-now.txt | tr '\n' ' ')
cpu() { ps -o time= -p "$1" 2>/dev/null | awk -F'[:]' '{ if (NF==2) print $1*60+$2; else print $1*3600+$2*60+$3 }'; }
rss() { ps -o rss= -p "$1" 2>/dev/null | awk '{print $1/1024}'; }
declare -A c0; T0=$(date +%s.%N)
for q in $APP $NEW; do c0[$q]=$(cpu $q); done
sleep $(( secs - 6 ))
T1=$(date +%s.%N); dt=$(echo "$T1 - $T0" | bc)
{ echo "# $n prayer=$p mode=$m window=${secs}s measured over ${dt}s; app pid=$APP; new WebKit helper pids: $NEW"
for q in $APP $NEW; do c1=$(cpu $q); [ -z "$c1" ] && continue; cmd=$(ps -o command= -p $q | cut -c1-60); echo "pid $q  cpu%=$(echo "scale=1; ($c1 - ${c0[$q]})*100/$dt" | bc)  rss_MB=$(rss $q)  $cmd"; done; } | tee "$E/$n.txt"
sleep 4
