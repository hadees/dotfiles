---
paths:
  - "**/dot_functions"
  - "**/tests/wrangler-profiles.bats"
---

# Wrangler (Cloudflare) auth profiles

Wrangler (≥ 4.106) keeps one OAuth login per **auth profile**: named ones
created with `wrangler auth create <name>`, plus the unnamed `default` that
`wrangler login` manages. Wrangler resolves the profile for a command as
`CLOUDFLARE_API_TOKEN` (overrides everything) → `--profile <name>` → the
nearest ancestor directory bound with `wrangler auth activate <name> <dir>`
→ `default`. `auth`, `login`, `logout`, and `whoami` reject `--profile`.

The `wrangler()` function in `.functions` picks the profile the way
`claude()` picks its config dir — cwd origin → account (credential pins) →
`wrangler.profile.<account>` in machine-local git config, set by the
overlays — with one extra layer first: a **per-repo pin**
`wrangler.<owner>/<repo>.profile` (origin slug, lowercase) outranks the
account mapping, for a repo that deploys to a Cloudflare account other than
its GitHub owner's usual one (a side project with its own Cloudflare login,
hosted under the personal account). It then **keeps the repo root bound to
that profile** via
wrangler's own `auth activate`, re-binding only when the binding is missing
or points elsewhere. Driving the binding (instead of injecting a flag) is
what makes `whoami`, `npx wrangler`, and package.json scripts agree with the
wrapper. Consequences:

- A mapped profile that was never created makes the wrapper refuse to run
  the command (it never logs you in and never falls back to another
  account); create it once with `wrangler auth create <name>`.
- Mapping an account to `default` means wrangler's default login and manages
  no binding — prefer a named profile for every account, including the main
  one, so each repo gets an explicit binding and nothing depends on which
  login `wrangler login` last stored. `auth`/`login`/`logout` pass straight
  through, and a set `CLOUDFLARE_API_TOKEN` disables profile management
  entirely.
- Unpinned repos and non-repo directories are left to wrangler's own
  resolution.
- **Which wrangler runs** is resolved the way `npx wrangler` resolves it:
  the nearest `node_modules/.bin/wrangler` at or above the cwd (a project
  that vendors wrangler as a devDependency gets the version it pinned, on
  the node it was installed under), else whatever `wrangler` is on PATH —
  an asdf/nodenv shim, `npm -g`, etc. asdf answers "which wrangler", the
  wrapper answers "as whom"; profiles and bindings live in wrangler's
  per-user config dir, so every install sees the same logins. No wrangler
  anywhere is a clear error, not a fallback.
- Override for one run with `WRANGLER_PROFILE=<mapped name or existing
  profile> wrangler …` or `wrangler-as <name> [args...]` (strict: unknown
  names error out listing the mapped ones); both pass `--profile=`, so they
  cannot be combined with the commands that reject it.
