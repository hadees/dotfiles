#!/usr/bin/env bats

# Behavioral tests for the Finicky link-routing config: the public composer
# (dot_finicky.ts) plus helper library (dot_config/finicky/lib.ts) are laid
# out in a sandbox HOME exactly as deployed, with FIXTURE fragments standing
# in for the overlays' personal.ts / work.ts, then loaded by Node (>= 22.6
# runs .ts directly by stripping types — the lib deliberately uses type
# annotations only, no TS-only runtime syntax) and driven with URLs through
# a tiny reimplementation of Finicky's handler walk. This proves the config
# resolves and bundles, and that the helpers route as documented; the
# structural deploy checks live in tests/chezmoi.bats. All names here are
# fixtures — no real account, org, domain, or profile names (see CLAUDE.md).

setup() {
  command -v node >/dev/null || skip "node not installed"
  # Resolve the real binary BEFORE HOME moves into the sandbox: version-manager
  # shims (asdf, nvm) look up their tool version under $HOME and fail silently
  # (exit 126) once it points somewhere empty.
  NODE="$(node -e 'console.log(process.execPath)' 2>/dev/null)" || skip "node not runnable"
  "$NODE" --experimental-strip-types -e '' 2>/dev/null || skip "node too old to run .ts (need >= 22.6)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/finicky"
  SRC="$BATS_TEST_DIRNAME/.."
  cp "$SRC/dot_finicky.ts" "$HOME/.finicky.ts"
  cp "$SRC/dot_config/finicky/lib.ts" "$HOME/.config/finicky/lib.ts"

  # Fixture fragments, in the shape the overlays deploy.
  cat > "$HOME/.config/finicky/work.ts" <<'EOF'
import { any, chrome, githubOwners, hosts, openedBy } from "./lib.ts";
export const rewrite = [];
export default [
  { match: any(hosts("work.example"), githubOwners("Octo-Work-Org")), browser: chrome("Work Profile") },
  { match: openedBy("com.example.workchat"), browser: chrome("Work Profile") },
];
EOF
  cat > "$HOME/.config/finicky/personal.ts" <<'EOF'
import { chrome, githubOwners, hosts } from "./lib.ts";
export const defaultBrowser = chrome("Personal Profile");
export const rewrite = [];
export default [
  { match: hosts("sideproject.example"), browser: chrome("Side Project Profile") },
  // Deliberately overlaps with work's owner rule: work must win by order.
  { match: githubOwners("octo-work-org", "octo-personal"), browser: chrome("Personal Profile") },
];
EOF

  # Harness: load the composed config and answer "which profile?" per URL,
  # walking handlers first-match-wins the way Finicky does (string globs and
  # regexes are not exercised here — the fragments use helper functions).
  cat > "$BATS_TEST_TMPDIR/route.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
const config = (await import(pathToFileURL(process.env.HOME + "/.finicky.ts").href)).default;
const isMatch = (m, url, opts) =>
  Array.isArray(m) ? m.some((x) => isMatch(x, url, opts))
  : typeof m === "function" ? !!m(url, opts)
  : m instanceof RegExp ? m.test(url.href)
  : m === url.href;
const profileOf = (b) => (typeof b === "string" ? b : `${b.name}:${b.profile}`);
for (const arg of process.argv.slice(2)) {
  const [href, bundleId] = arg.split("|");
  const url = new URL(href);
  const opts = { opener: bundleId ? { name: "x", bundleId, path: "/x" } : null };
  const hit = config.handlers.find((h) => isMatch(h.match, url, opts));
  console.log(`${href} -> ${profileOf(hit ? hit.browser : config.defaultBrowser)}`);
}
EOF
}

route() {
  run "$NODE" --experimental-strip-types --no-warnings "$BATS_TEST_TMPDIR/route.mjs" "$@"
}

@test "finicky: the composed config loads with cross-file imports and exposes handlers/default" {
  route "https://nothing.example/"
  [ "$status" -eq 0 ]
  [ "$output" = "https://nothing.example/ -> Google Chrome:Personal Profile" ]
}

@test "finicky: hosts() matches the domain and subdomains, not lookalikes" {
  route "https://work.example/x" "https://app.work.example/y?z=1" "https://evil-work.example/" "https://work.example.evil/"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://work.example/x -> Google Chrome:Work Profile" ]
  [ "${lines[1]}" = "https://app.work.example/y?z=1 -> Google Chrome:Work Profile" ]
  [ "${lines[2]}" = "https://evil-work.example/ -> Google Chrome:Personal Profile" ]
  [ "${lines[3]}" = "https://work.example.evil/ -> Google Chrome:Personal Profile" ]
}

@test "finicky: githubOwners() matches the owner segment case-insensitively and only on github.com" {
  route "https://github.com/octo-work-org" "https://github.com/OCTO-WORK-ORG/repo/pull/1" "https://github.com/octo-personal/repo" "https://github.com/someone-else/octo-work-org" "https://gitlab.com/octo-work-org/repo"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://github.com/octo-work-org -> Google Chrome:Work Profile" ]
  [ "${lines[1]}" = "https://github.com/OCTO-WORK-ORG/repo/pull/1 -> Google Chrome:Work Profile" ]
  [ "${lines[2]}" = "https://github.com/octo-personal/repo -> Google Chrome:Personal Profile" ]
  [ "${lines[3]}" = "https://github.com/someone-else/octo-work-org -> Google Chrome:Personal Profile" ]
  [ "${lines[4]}" = "https://gitlab.com/octo-work-org/repo -> Google Chrome:Personal Profile" ]
}

@test "finicky: work rules are tried before personal rules" {
  # Both fragments claim github.com/octo-work-org; the composer orders work first.
  route "https://github.com/octo-work-org/repo"
  [ "$output" = "https://github.com/octo-work-org/repo -> Google Chrome:Work Profile" ]
}

@test "finicky: per-company personal rule wins over the personal default" {
  route "https://admin.sideproject.example/dash"
  [ "$output" = "https://admin.sideproject.example/dash -> Google Chrome:Side Project Profile" ]
}

@test "finicky: openedBy() routes on the opener app's bundle id, ignoring the URL" {
  route "https://nothing.example/|com.example.workchat" "https://nothing.example/|com.example.other" "https://nothing.example/"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "https://nothing.example/ -> Google Chrome:Work Profile" ]
  [ "${lines[1]}" = "https://nothing.example/ -> Google Chrome:Personal Profile" ]
  [ "${lines[2]}" = "https://nothing.example/ -> Google Chrome:Personal Profile" ]
}

@test "finicky: the public create_ stubs compose to an empty, plain-Chrome config" {
  # A machine with no overlay applied yet must still get a valid config.
  cp "$BATS_TEST_DIRNAME/../dot_config/finicky/create_personal.ts" "$HOME/.config/finicky/personal.ts"
  cp "$BATS_TEST_DIRNAME/../dot_config/finicky/create_work.ts" "$HOME/.config/finicky/work.ts"
  route "https://github.com/octo-work-org"
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/octo-work-org -> Google Chrome" ]
}
