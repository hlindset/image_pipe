#!/bin/sh
# Starts a bare BEAM (same erts as the release, jemalloc preloaded) with -sname bare, for a malloc baseline.
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
REL=/home/user/image_pipe/.claude/worktrees/agent-a8e9dfef18ecf8804/image_pipe_server/_build/prod/rel/image_pipe_server
ERTS=$(ls -d $REL/erts-*)
LD_PRELOAD=/usr/local/lib/libjemalloc.so.2 MALLOC_CONF=background_thread:true \
  mise exec erlang@29.1.1 -- erl -sname bare -noshell -detached -boot start_clean ${1:-}
