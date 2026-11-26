# Append the run's total to bats' own test number on every result line (ok / not ok),
# "ok 1137 name" becoming "ok 1137/2541 name", so a CI log shows where the run is.
# bats numbers results in output order, also under --jobs, so the number is the
# progress. A # skip / # TODO suffix is untouched. Total comes from the TAP plan line
# (1..N); every other line passes through unchanged, and until a plan line is seen
# (or with none) result lines do too.
# Used by every CI step that runs bats:  bats ... 2>&1 | awk -f .github/bats-progress.awk
/^1\.\.[0-9]+$/ && total == "" { total = substr($0, 4) }
/^(not )?ok [0-9]+( |$)/ && total != "" { sub(/^(not )?ok [0-9]+/, "&/" total) }
{ print; fflush() }
