#!/bin/sh
# usage: trial2.sh NAME PORT URLFILE ROUNDS  -> like trial.sh but with a given URL list
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
NAME=$1; PORT=$2; URLS=$3; ROUNDS=${4:-1}
IPS_SERVER__PORT=$PORT $S/ctl.sh start "$NAME" "$S/min.toml"
sleep 10
echo "== $NAME startup idle"; $S/rss.sh "$NAME"; $S/jestats.sh "$NAME" | tr '\n' ' '; echo
$S/load.sh "$URLS" 4 "$ROUNDS"
sleep 45
echo "== $NAME post-warmup idle (45 s)"; $S/rss.sh "$NAME"; $S/jestats.sh "$NAME" | tr '\n' ' '; echo
