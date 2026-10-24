#!/bin/sh
# usage: ctl.sh start|stop|rpc|measure <name> <config> [extra env...]
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
REL=${REL:-/home/user/image_pipe/.claude/worktrees/agent-a8e9dfef18ecf8804/image_pipe_server/_build/prod/rel/image_pipe_server}
cmd=$1
name=$2
export RELEASE_DISTRIBUTION=sname
export RELEASE_NODE=$name@localhost
export RELEASE_TMP=$S/tmp_$name
mkdir -p "$RELEASE_TMP"
case "$cmd" in
  start)
    export IPS_CONFIG=$3
    "$REL/bin/image_pipe_server" daemon
    ;;
  stop) "$REL/bin/image_pipe_server" stop ;;
  rpc) "$REL/bin/image_pipe_server" rpc "$3" ;;
  measure) "$REL/bin/image_pipe_server" rpc "$(cat $S/measure.exs)" ;;
  script) "$REL/bin/image_pipe_server" rpc "$(cat $3)" ;;
  pid) "$REL/bin/image_pipe_server" rpc 'IO.puts(:os.getpid())' ;;
esac
