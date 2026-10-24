#!/bin/bash
# Full load scenario against one server config.
# Usage: ALLOC=jemalloc scenario.sh NAME [extra env for the server...]
# Output: $L/out_NAME/{samples.csv,phases.log}
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
W=/home/user/image_pipe/.claude/worktrees/agent-a6052be7146ed379e
name=$1
O=$L/out_$name
rm -rf $O; mkdir -p $O
cd $W
bash $L/run.sh "$@" &
srv=$!
until curl -fsS http://127.0.0.1:18181/health/ready >/dev/null 2>&1; do sleep 1; done
elixir --sname "smp$name@localhost" --cookie memhunt --hidden $L/sampler.exs $O/samples.csv ${INTERVAL:-1000} > $O/sampler.log 2>&1 &
smp=$!
sleep 3
mark() { echo "$(date +%s.%N | cut -c1-14) $*" >> $O/phases.log; }
bpid() { pgrep -f 'beam.smp.*memload@localhost' | head -1; }
hwm() { grep -E 'VmHWM' /proc/$(bpid)/status | awk '{print $2/1024}'; }
cpu() { awk '{print ($14+$15)/100}' /proc/$(bpid)/stat; }
phase() { export SEED=$((SEED_BASE + ${n_phase:-0})); n_phase=$(( ${n_phase:-0} + 1 )); echo 5 > /proc/$(bpid)/clear_refs; c0=$(cpu); mark "start $*"; elixir $L/drive.exs "$@" >> $O/phases.log 2>&1; echo "    HWM $* $(hwm) MiB cpu_s $(echo "$(cpu) - $c0" | bc)" >> $O/phases.log; mark "end $*"; }
idle() { mark "idle $1"; sleep $1; }
gcnow() { mark "gc fds=$(ls /proc/$(bpid)/fd | wc -l) rss=$(grep VmRSS /proc/$(bpid)/status | awk '{print $2/1024}')"; elixir --sname "gc$name$RANDOM@localhost" --cookie memhunt --hidden $L/gc.exs >> $O/phases.log 2>&1; }
idle 10
IFS=';' read -ra steps <<< "${PLAN:-mix 4 60;idle 30;gc;big 8 60;idle 30;gc;autoq 4 45;idle 30;distinct 4 60;hits 16 30;origin 8 40;idle 60;gc;idle 10}"
for step in "${steps[@]}"; do
  IFS=' ' read -r a1 a2 a3 <<< "$step"; set -- $a1 $a2 $a3
  case $1 in
    idle) idle $2 ;;
    gc) gcnow ;;
    *) phase $1 $2 $3 ;;
  esac
done
kill $smp
pkill -f 'memload@localhost' 
wait $srv 2>/dev/null
echo done
