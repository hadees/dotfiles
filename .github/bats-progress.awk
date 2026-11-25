# Prefix every bats result line (ok / not ok) with [done/total] so a CI log shows
# where the run is. Total comes from the TAP plan line (1..N); every other line
# passes through unchanged, and with no plan line nothing is prefixed.
# Used by every CI step that runs bats:  bats ... 2>&1 | awk -f .github/bats-progress.awk
/^1\.\.[0-9]+$/ && total == "" { total = substr($0, 4) }
/^(not )?ok / && total != "" { done++; $0 = "[" done "/" total "] " $0 }
{ print; fflush() }
