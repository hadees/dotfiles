#!/usr/bin/env bats

# The shared Claude Code agent definitions under .chezmoitemplates/claude-agents
# and the one-line stubs that deploy them into each profile. No external linter
# covers the current frontmatter fields, and `claude plugin validate` passes a
# deliberately broken agent file (checked 2026-09-17), so the checks live here.
# Frontmatter is flat `key: value` lines (one nested map, `experimental`), so it
# is parsed with awk rather than a YAML library — PyYAML is not on every CI
# image. Documented rules and this repo's own conventions are marked as such.

TEMPLATES="$BATS_TEST_DIRNAME/../.chezmoitemplates/claude-agents"
# Every directory in THIS source that deploys the shared set. Discovered, not
# listed: a hardcoded pair is what hid an overlay-owned profile having no
# agents at all until 2026-09-18 — that profile's directory is not in this
# source, so it is invisible here whatever we write, which is why the neutral
# `dot_claude-shared/agents` copy exists for an overlay to symlink at. A new
# profile directory added to this repo is picked up with no edit to this line.
STUB_DIRS=()
while IFS= read -r d; do STUB_DIRS+=("$d"); done < <(
  find "$BATS_TEST_DIRNAME/.." -maxdepth 2 -type d -name agents -not -path '*/.git/*' | sort
)

# Documented frontmatter fields (code.claude.com/docs/en/sub-agents), plus the
# nested key of the `experimental` map. Anything else is a typo the loader
# would reject at session start — too late to be useful.
DOCUMENTED_KEYS='name description tools disallowedTools model effort permissionMode maxTurns skills mcpServers hooks memory background omitClaudeMd isolation color initialPrompt experimental cacheTtl'

# Frontmatter body of a template: the lines between the first two `---`.
frontmatter() {
  awk 'NR==1 && $0!="---" {exit 1} NR>1 && $0=="---" {exit} NR>1 {print}' "$1"
}

# Value of a top-level or nested key, trimmed.
fmval() {
  frontmatter "$1" | awk -v k="$2" '{ sub(/^[[:space:]]+/, "") } index($0, k ":")==1 { sub("^" k ":[[:space:]]*", ""); print; exit }'
}

# Everything after the frontmatter, with line wraps flattened so a phrase
# that breaks across lines still matches.
body() {
  awk 'NR>1 && $0=="---" {found=1; next} found {print}' "$1" | tr '\n' ' ' | tr -s ' '
}

# Section headings survive the flattening as "## Name" inside the one line;
# check for them with a leading space rather than a line anchor.
has_heading() {
  grep -q -- " ## $2" <<< "$1"
}

templates() {
  ls "$TEMPLATES"/*.md
}

@test "every template has a frontmatter block with name and description" {
  for t in $(templates); do
    frontmatter "$t" > /dev/null || { echo "$t: no leading ---"; false; }
    [ -n "$(fmval "$t" name)" ] || { echo "$t: no name"; false; }
    [ -n "$(fmval "$t" description)" ] || { echo "$t: no description"; false; }
  done
}

@test "name matches the filename (convention: the filename is how the seat is referred to)" {
  for t in $(templates); do
    stem="$(basename "$t" .md)"
    [ "$(fmval "$t" name)" = "$stem" ] || { echo "$t: name '$(fmval "$t" name)' != '$stem'"; false; }
  done
}

@test "name is lowercase letters and hyphens only (documented: no leading -, no :)" {
  for t in $(templates); do
    n="$(fmval "$t" name)"
    [[ "$n" =~ ^[a-z][a-z-]*$ ]] || { echo "$t: bad name '$n'"; false; }
  done
}

@test "only documented frontmatter keys are used" {
  for t in $(templates); do
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      grep -qw -- "$key" <<< "$DOCUMENTED_KEYS" || { echo "$t: unknown key '$key'"; false; }
    done < <(frontmatter "$t" | sed -E 's/^[[:space:]]+//' | awk -F: '/^[A-Za-z]/ {print $1}')
  done
}

@test "model is a documented alias or full id" {
  for t in $(templates); do
    m="$(fmval "$t" model)"
    case "$m" in
      haiku|sonnet|opus|fable|inherit|claude-*) ;;
      *) echo "$t: model '$m'"; false ;;
    esac
  done
}

@test "effort is a documented level, and absent on haiku (which has none)" {
  for t in $(templates); do
    e="$(fmval "$t" effort)"
    m="$(fmval "$t" model)"
    if [ "$m" = haiku ]; then
      [ -z "$e" ] || { echo "$t: effort on haiku is undocumented behaviour"; false; }
    else
      case "$e" in
        low|medium|high|xhigh|max) ;;
        *) echo "$t: effort '$e'"; false ;;
      esac
    fi
  done
}

@test "every seat pins the one-hour cache TTL (subagents default to five minutes)" {
  for t in $(templates); do
    [ "$(fmval "$t" cacheTtl)" = 1h ] || { echo "$t: cacheTtl '$(fmval "$t" cacheTtl)'"; false; }
    frontmatter "$t" | grep -q '^experimental:' || { echo "$t: cacheTtl must sit under experimental"; false; }
  done
}

@test "maxTurns, when set, is a positive integer" {
  for t in $(templates); do
    n="$(fmval "$t" maxTurns)"
    [ -z "$n" ] && continue
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "$t: maxTurns '$n'"; false; }
  done
}

@test "tools is an allowlist that never grants Agent (no seat dispatches subagents)" {
  for t in $(templates); do
    tools="$(fmval "$t" tools)"
    [ -n "$tools" ] || { echo "$t: no tools allowlist"; false; }
    ! grep -qw Agent <<< "$tools" || { echo "$t: tools grants Agent"; false; }
    [ -z "$(fmval "$t" disallowedTools)" ] || { echo "$t: use the allowlist, not disallowedTools"; false; }
  done
}

@test "a read-only seat has no Edit or Write in its allowlist" {
  for t in $(templates); do
    has_heading "$(body "$t")" "Read-only, strictly" || continue
    tools="$(fmval "$t" tools)"
    ! grep -qEw 'Edit|Write|NotebookEdit' <<< "$tools" || { echo "$t: read-only seat can write"; false; }
  done
}

@test "description is trigger conditions: when, when not, no output summary, no economics" {
  for t in $(templates); do
    d="$(fmval "$t" description)"
    [ "${#d}" -le 600 ] || { echo "$t: description ${#d} chars"; false; }
    grep -q 'Do NOT' <<< "$d" || { echo "$t: no 'Do NOT' clause"; false; }
    ! grep -qiE 'token|expensive|cheap|price|cost|\$[0-9]' <<< "$d" || { echo "$t: economics in description"; false; }
    # Superpowers' tested failure: a description that summarises the workflow
    # gets followed instead of the body. These verbs are how that creeps in.
    ! grep -qiE '(^| )(returns|reports|writes|verifies|reproduces|runs the)' <<< "$d" || { echo "$t: description summarises the workflow"; false; }
  done
}

@test "every seat ends with the report contract" {
  for t in $(templates); do
    b="$(body "$t")"
    has_heading "$b" "Report" || { echo "$t: no Report section"; false; }
    grep -q 'DONE_WITH_CONCERNS' <<< "$b" || { echo "$t: no status line"; false; }
    grep -q 'under 15 lines' <<< "$b" || { echo "$t: no reply cap"; false; }
    grep -q 'You do not dispatch subagents' <<< "$b" || { echo "$t: no nested-dispatch rule"; false; }
  done
}

@test "each template has a stub in every stub dir, and every stub points at a template" {
  for t in $(templates); do
    stem="$(basename "$t" .md)"
    for d in "${STUB_DIRS[@]}"; do
      s="$d/$stem.md.tmpl"
      [ -f "$s" ] || { echo "missing stub $s"; false; }
      [ "$(cat "$s")" = "{{ template \"claude-agents/$stem.md\" . }}" ] || { echo "$s: unexpected content"; false; }
    done
  done
  # Only a stub that calls a shared template is checked against the shared
  # set. The five are the cross-profile seats, not an allowlist: a profile
  # dir may carry agents of its own, and those are not this test's business.
  for d in "${STUB_DIRS[@]}"; do
    for s in "$d"/*.md.tmpl; do
      ref="$(grep -o 'template "claude-agents/[^"]*"' "$s" | sed 's|.*claude-agents/||; s|"$||')"
      [ -n "$ref" ] || continue
      [ -f "$TEMPLATES/$ref" ] || { echo "$s calls claude-agents/$ref, which does not exist"; false; }
    done
  done
}

@test "stubs render through chezmoi to the template's own frontmatter" {
  command -v chezmoi > /dev/null 2>&1 || skip "chezmoi not installed"
  cd "$BATS_TEST_DIRNAME/.."
  TMPHOME="$(mktemp -d)"
  chez() {
    HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" XDG_DATA_HOME="$TMPHOME/.local/share" \
    XDG_STATE_HOME="$TMPHOME/.local/state" XDG_CACHE_HOME="$TMPHOME/.cache" chezmoi "$@"
  }
  chez init --source "$PWD" --promptString machineClass=linux
  for t in $(templates); do
    stem="$(basename "$t" .md)"
    rendered="$(chez execute-template --source "$PWD" < "dot_claude/agents/$stem.md.tmpl")"
    [ "$(printf '%s\n' "$rendered" | awk 'index($0,"name:")==1 {sub("^name:[ \t]*",""); print; exit}')" = "$stem" ] \
      || { echo "$stem: stub did not render the template"; false; }
  done
  rm -rf "$TMPHOME"
}

@test "the neutral shared copy exists, because an overlay-owned profile can only symlink at it" {
  # A profile directory owned by a private overlay cannot render these
  # templates: chezmoi resolves .chezmoitemplates within one source dir. So the
  # overlay symlinks its agents dir at ~/.claude-shared/agents, which THIS repo
  # deploys. Deleting this directory would leave that link dangling and the
  # profile silently back on the built-in seats — the failure found on
  # 2026-09-18 — so the cross-repo contract is pinned here.
  local shared="$BATS_TEST_DIRNAME/../dot_claude-shared/agents"
  [ -d "$shared" ]
  for t in "$TEMPLATES"/*.md; do
    [ -f "$shared/$(basename "$t" .md).md.tmpl" ]
  done
}
