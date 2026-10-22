#!/bin/bash
# usage: keytest.sh <name> <inject-kind> <undo-kind|-> <shield args...>
# shield (9 s cap) -> inject chord at t+2.5 s (in background: cmdtab holds) -> screenshot 1.0 s later -> undo chord
cd "$(dirname "$0")/.."; E="$PWD/evidence"; BIN="$PWD/build/GoPraySpike.app/Contents/MacOS/GoPraySpike"
n=$1; kind=$2; undo=$3; shift 3
("$BIN" shield --seconds 9 --poll --log "$E/$n.log" "$@" >/dev/null 2>&1 &)
sleep 2.5
echo "INJECTED $kind" >> "$E/$n.log"
"$BIN" inject "$kind" >> "$E/$n.log" 2>&1 &
IP=$!
sleep 1.0; screencapture -x -D 1 "$E/$n-shot.png"; echo "shot taken" >> "$E/$n.log"
wait $IP
if [ "$undo" != "-" ]; then "$BIN" inject "$undo" >> "$E/$n.log" 2>&1; echo "INJECTED(undo) $undo" >> "$E/$n.log"; fi
sleep 5
