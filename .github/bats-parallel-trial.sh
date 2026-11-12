#!/bin/sh
# Trial for running the bats suite with --jobs. Runs the suite once serial and
# three times in each parallel mode on the same runner, printing greppable
# TRIAL lines. Always exits 0: the numbers are the product, a red run is data.
set -u

jobs=$(getconf _NPROCESSORS_ONLN)
dir=$(mktemp -d)
lock=$(command -v flock || command -v shlock || echo none)
printf 'TRIAL-ENV\tcores=%s\tbats=%s\tparallel=%s\tlock=%s\n' \
  "$jobs" "$(bats --version)" "$(parallel --version 2>&1 | head -n 1)" "$lock"

# trial <mode> <n> <bats flags...>
trial() {
  mode=$1 n=$2
  shift 2
  log=$dir/$mode-$n.log
  t0=$(date +%s)
  bats "$@" tests >"$log" 2>&1
  rc=$?
  t1=$(date +%s)
  printf 'TRIAL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$n" "$jobs" \
    "$((t1 - t0))" "$rc" "$(grep -c '^ok ' "$log")" \
    "$(grep -c '^not ok ' "$log")" "$(head -n 1 "$log")"
  grep '^not ok ' "$log" | while IFS= read -r line; do
    printf 'TRIAL-FAIL\t%s\t%s\t%s\n' "$mode" "$n" "$line"
  done
  if [ "$rc" -ne 0 ]; then cat "$log"; fi
}

trial serial 1 --timing
for n in 1 2 3; do
  trial across "$n" --jobs "$jobs" --no-parallelize-within-files
done
for n in 1 2 3; do
  trial both "$n" --jobs "$jobs"
done

echo '--- serial --timing log'
cat "$dir/serial-1.log"
exit 0
