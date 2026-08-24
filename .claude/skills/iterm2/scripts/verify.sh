#!/usr/bin/env bash
# Re-check every fact in manifest.txt against the iTerm2 installed on this
# machine, and say plainly which ones no longer hold.
#
# A skill that describes an application is a claim about one version of it.
# The app updates itself through Sparkle without asking, so the claim decays
# quietly and the only symptom is confident, wrong advice. This script turns
# that into an exit code: the parts of the skill that can be mechanically
# checked are checked, and the parts that cannot are at least anchored to a
# version number you can see drifting.
#
# Nothing here executes iTerm2. Every answer comes from the bundle on disk:
# the Info.plist, the AppleScript dictionary, the strings in the executable,
# and the utilities directory.
#
# Usage:
#   verify.sh [--manifest FILE] [--app /path/to/iTerm.app] [--quiet]
#   ITERM2_APP=/path/to/iTerm.app verify.sh
#
# Exit: 0 everything still holds  1 at least one fact failed  2 cannot check

set -uo pipefail

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
manifest="$here/manifest.txt"
app=${ITERM2_APP:-}
quiet=0

while [ $# -gt 0 ]; do
  case $1 in
    --manifest) manifest=${2:-}; shift 2 ;;
    --app)      app=${2:-};      shift 2 ;;
    --quiet|-q) quiet=1;         shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'verify.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }
die() { printf 'verify.sh: %s\n' "$*" >&2; exit 2; }

[ -r "$manifest" ] || die "no manifest at $manifest"

if [ -z "$app" ]; then
  for candidate in /Applications/iTerm.app "$HOME/Applications/iTerm.app"; do
    [ -d "$candidate" ] && { app=$candidate; break; }
  done
fi
[ -n "$app" ] && [ -d "$app" ] || die "no iTerm.app found (pass --app or set ITERM2_APP)"

sdef=$app/Contents/Resources/iTerm2.sdef
exe=$app/Contents/MacOS/iTerm2
utils=$app/Contents/Resources/utilities
plist=$app/Contents/Info.plist

# strings(1) over a 100 MB executable is the one slow step, so do it once.
# A missing strings(1) is not fatal: skip that class of check and say so.
strdump=""
if [ -r "$exe" ] && command -v strings >/dev/null 2>&1; then
  # Not `mktemp -t iterm2-verify`: that is BSD syntax. GNU coreutils reads the
  # argument as a template and demands XXX in it, so the BSD form dies on every
  # Linux runner — and this script is meant to be checkable anywhere a bundle
  # can be copied. The explicit template works on both.
  strdump=$(mktemp "${TMPDIR:-/tmp}/iterm2-verify.XXXXXX") || die "cannot create a temp file"
  trap 'rm -f "$strdump"' EXIT
  strings -a "$exe" > "$strdump" 2>/dev/null || : > "$strdump"
fi

# Read a key out of Info.plist without launching the app. PlistBuddy handles
# the binary plists real bundles ship and is on every macOS; defaults(1) is
# the next best; the XML scrape last, so this script still works where
# neither exists (a Linux CI runner checking a copied bundle, say).
plist_get() {
  local v=""
  if [ -x /usr/libexec/PlistBuddy ]; then
    v=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null)
  fi
  if [ -z "$v" ] && command -v defaults >/dev/null 2>&1; then
    v=$(defaults read "${plist%.plist}" "$1" 2>/dev/null)
  fi
  if [ -z "$v" ]; then
    v=$(sed -n "/<key>$1<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$plist" 2>/dev/null)
  fi
  printf '%s' "$v"
}

stamp=""
installed=$(plist_get CFBundleShortVersionString)
declare -a failures=()
declare -A total=() ok=() skipped=()

record() {  # record <class> <ok|fail|skip> [detail]
  total[$1]=$(( ${total[$1]:-0} + 1 ))
  case $2 in
    ok)   ok[$1]=$(( ${ok[$1]:-0} + 1 )) ;;
    skip) skipped[$1]=$(( ${skipped[$1]:-0} + 1 )) ;;
    *)    failures+=("$1: $3") ;;
  esac
}

while IFS= read -r line || [ -n "$line" ]; do
  case $line in ''|'#'*) continue ;; esac
  verb=${line%% *}
  rest=${line#* }
  case $verb in
    version)
      stamp=$rest
      ;;
    sdef)
      if [ ! -r "$sdef" ]; then
        record sdef fail "no dictionary at $sdef"
      elif grep -qF -- "$rest" "$sdef"; then
        record sdef ok
      else
        record sdef fail "$rest"
      fi
      ;;
    binstr)
      if [ -z "$strdump" ]; then
        record binstr skip
      elif grep -qxF -- "$rest" "$strdump"; then
        record binstr ok
      else
        record binstr fail "$rest"
      fi
      ;;
    tipcount)
      # The one check that can notice a feature being ADDED. Everything else
      # here asks whether a name still exists; iTerm2's own tip list grows
      # when the app grows, so its length is a cheap tripwire for "there is
      # something new here you have not read about".
      got=$(grep -c '"title":' "$utils/it2tip" 2>/dev/null || echo 0)
      if [ "$got" = "$rest" ]; then
        record tipcount ok
      else
        record tipcount fail "it2tip lists $got features, recorded as $rest - read the new ones with: $utils/it2tip"
      fi
      ;;
    util)
      if [ -e "$utils/$rest" ]; then
        record util ok
      else
        record util fail "$rest"
      fi
      ;;
    info)
      key=${rest%% *}; want=${rest#* }
      got=$(plist_get "$key")
      if [ "$got" = "$want" ]; then
        record info ok
      else
        record info fail "$key is '${got:-<unset>}', recorded as '$want'"
      fi
      ;;
    bundle)
      # Advisory: a plugin the user simply has not installed is not a fact
      # that stopped being true about iTerm2.
      # Beside the app, and nowhere else: a plugin found in /Applications
      # belongs to whatever iTerm2 lives there, not necessarily to $app.
      found="$(dirname -- "$app")/$rest"
      if [ -d "$found" ]; then
        say "bundle:  $rest present"
      else
        say "bundle:  $rest not installed (advisory)"
      fi
      ;;
    *)
      failures+=("manifest: unknown verb '$verb'")
      ;;
  esac
done < "$manifest"

say "app:     $app"
say "version: ${installed:-<unreadable>}"

version_bad=0
if [ -z "$stamp" ]; then
  failures+=("manifest: no version stamp")
elif [ -z "$installed" ]; then
  say "stamp:   $stamp — installed version unreadable, cannot compare"
elif [ "$installed" = "$stamp" ]; then
  say "stamp:   $stamp — matches"
else
  version_bad=1
  say "stamp:   $stamp — INSTALLED IS $installed"
fi

for class in sdef binstr util info tipcount; do
  n=${total[$class]:-0}
  [ "$n" -eq 0 ] && continue
  s=${skipped[$class]:-0}
  # "tipcount" is one character too wide for the label column every other
  # line in this repo's reports uses; the manifest verb keeps its real name.
  label=$class; [ "$class" = tipcount ] && label=tips
  say "$(printf '%-9s' "$label:")${ok[$class]:-0}/$n verified$( [ "$s" -gt 0 ] && printf ' (%s skipped: no strings(1))' "$s" )"
done

if [ "${#failures[@]}" -gt 0 ]; then
  printf '\nNo longer true of the installed iTerm2:\n'
  printf '  %s\n' "${failures[@]}"
fi

if [ "$version_bad" -eq 1 ]; then
  cat <<EOF

The skill was written against iTerm2 $stamp; this machine runs $installed.
Even where every check above passed, most of them only ask whether a name
still exists. Only the tip count notices something being ADDED, and only
when the feature is one the app tours. Read what changed:

https://iterm2.com/downloads.html

(expand the per-version notes; the GitHub repo publishes no releases and has
no changelog file). Then update references/ and re-stamp manifest.txt and
the iterm2-doctor stamp in dot_functions together.
EOF
fi

if [ "${#failures[@]}" -gt 0 ] || [ "$version_bad" -eq 1 ]; then
  exit 1
fi
say ""
say "OK - every recorded fact still holds for iTerm2 ${installed:-?}"
