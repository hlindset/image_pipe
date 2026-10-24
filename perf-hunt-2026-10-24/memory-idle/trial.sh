#!/bin/sh
# usage: trial.sh NAME PORT ROUNDS [CONFIG]   (env such as MALLOC_CONF / ELIXIR_ERL_OPTIONS passes through)
# Starts a release node, measures idle, warms it with ROUNDS of mkurls at concurrency 4,
# waits for decay, measures again (BEAM + jemalloc), leaves node running.
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
NAME=$1; PORT=$2; ROUNDS=${3:-1}; CONFIG=${4:-$S/min.toml}
IPS_SERVER__PORT=$PORT $S/ctl.sh start "$NAME" "$CONFIG"
sleep 10
echo "== $NAME startup idle"
$S/ctl.sh script "$NAME" $S/quick.exs
$S/jestats.sh "$NAME" | tr '\n' ' '; echo
$S/mkurls.sh "$PORT" > $S/urls_$NAME.txt
$S/load.sh $S/urls_$NAME.txt 4 "$ROUNDS"
sleep 45
echo "== $NAME post-warmup idle (45 s)"
$S/ctl.sh script "$NAME" $S/quick.exs
$S/jestats.sh "$NAME" | tr '\n' ' '; echo
