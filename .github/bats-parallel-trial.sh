#!/bin/sh
# Trial for running the bats suite with --jobs: the WSL retry. One serial run,
# then three with --jobs across files, each under a watchdog. A run that passes
# its limit prints the process table and its log so far, is killed, and counts
# as a hang. Always exits 0: the TRIAL lines are the product, a red run is data.
# Linux tools on purpose (setsid, pkill, procps ps): only test-wsl runs this.
set -u

jobs=$(getconf _NPROCESSORS_ONLN)
dir=$(mktemp -d)
lock=$(command -v flock || command -v shlock || echo none)
if ( : </dev/tty ) 2>/dev/null; then ctty=yes; else ctty=no; fi
printf 'TRIAL-ENV\tcores=%s\tbats=%s\tparallel=%s\tlock=%s\tctty=%s\n' \
  "$jobs" "$(bats --version)" "$(parallel --version 2>&1 | head -n 1)" "$lock" "$ctty"

hung=0

# trial <mode> <n> <limit seconds> <bats flags...>
# A mode ending in -notty runs bats in a session of its own, with no terminal.
trial() {
  mode=$1 n=$2 limit=$3
  shift 3
  log=$dir/$mode-$n.log
  t0=$(date +%s)
  case $mode in
    *-notty)
      { setsid -w bats "$@" tests </dev/null >"$log" 2>&1; echo $? >"$log.rc"; } & ;;
    *)
      # the step's own stdin, not the /dev/null a background job is given
      { { bats "$@" tests <&3 3<&- >"$log" 2>&1; echo $? >"$log.rc"; } & } 3<&0 ;;
  esac
  waited=0
  rc=hang
  while [ "$waited" -lt "$limit" ]; do
    if [ -e "$log.rc" ]; then rc=$(cat "$log.rc"); break; fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "$rc" = hang ] && [ -e "$log.rc" ]; then rc=$(cat "$log.rc"); fi
  if [ "$rc" = hang ]; then
    hung=1
    printf 'TRIAL-HANG\t%s\t%s\t%s\n' "$mode" "$n" "$waited"
    echo "--- $mode $n: processes at the hang"
    ps -e -ww -o pid,ppid,pgid,tpgid,tty,stat,etimes,args
    echo "--- $mode $n: log so far"
    cat "$log"
    pkill -TERM -f 'libexec/bats-core/|parallel --keep-order'
    sleep 5
    pkill -KILL -f 'libexec/bats-core/|parallel --keep-order'
    sleep 2
  fi
  t1=$(date +%s)
  printf 'TRIAL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$n" "$jobs" \
    "$((t1 - t0))" "$rc" "$(grep -c '^ok ' "$log")" \
    "$(grep -c '^not ok ' "$log")" "$(head -n 1 "$log")"
  grep '^not ok ' "$log" | while IFS= read -r line; do
    printf 'TRIAL-FAIL\t%s\t%s\t%s\n' "$mode" "$n" "$line"
  done
  if [ "$rc" != 0 ] && [ "$rc" != hang ]; then cat "$log"; fi
}

# Round 3: the confirmation. Three runs with no controlling terminal, the
# shape WSL would use if it joins (serial was measured at 1066 s in round 2).
for n in 1 2 3; do
  trial across-notty "$n" 900 --jobs "$jobs" --no-parallelize-within-files
done
exit 0
