# 1Password's dev operations

Where the docs are, how they version and ship, and where to look when
`onepassword-doctor`'s `skill:` line says these notes have drifted. Verified
2026-08-24 against the versions in `../VERSIONS`.

## Contents

- [The developer portal](#the-developer-portal)
- [Machine-readable docs](#machine-readable-docs) ← start here when refreshing
- [`op` CLI: versioning, cadence, channels](#op-cli-versioning-cadence-channels)
- [Desktop app: versioning, cadence, channels](#desktop-app-versioning-cadence-channels)
- [SDKs](#sdks)
- [Where changelogs actually live](#where-changelogs-actually-live)
- [How breaking changes get announced](#how-breaking-changes-get-announced)
- [Refreshing this skill](#refreshing-this-skill)

## The developer portal

**`https://www.1password.dev/` is canonical.** This is the opposite of what
most older links and much folk memory assume: `developer.1password.com` now
301-redirects *to* it and drops the `/docs/` segment.

    developer.1password.com/docs/<path>  ->  www.1password.dev/<path>

Old links still resolve, so nothing is broken — but write the new host.

Sections, all under `https://www.1password.dev/`:

| Area | Path |
|---|---|
| Get started / quickstarts | `/get-started` |
| CLI | `/cli`, reference at `/cli/reference` |
| Shell plugins (~80 per-tool pages) | `/cli/shell-plugins` |
| SDKs (Go / JS / Python) | `/sdks` |
| Service accounts | `/service-accounts` |
| Connect (self-hosted) | `/connect` |
| Service accounts vs Connect | `/secrets-automation` |
| SSH & Git | `/ssh`, `/ssh/agent`, `/ssh/git-commit-signing` |
| Events API | `/events-api` |
| Environments (newer) | `/environments` |
| CI/CD, Kubernetes, Terraform, Pulumi | `/ci-cd`, `/k8s/*`, `/terraform`, `/pulumi` |
| Developers Slack | `/joinslack` |

## Machine-readable docs

This is the part that makes refreshing the skill cheap, and it is easy to
miss. The portal publishes itself in forms built for exactly this:

| Resource | URL |
|---|---|
| Curated index (llms.txt standard, ~102 lines) | `https://www.1password.dev/llms.txt` |
| Whole corpus in one file (~2.34 MB) | `https://www.1password.dev/llms-full.txt` |
| **Any page as Markdown** — append `.md` | `https://www.1password.dev/cli/get-started.md` |
| Docs-search MCP server, **no auth** | `https://www.1password.dev/mcp` |
| Sitemap (349 URLs) | `https://www.1password.dev/sitemap.xml` |
| The page explaining all of the above | `https://www.1password.dev/ai-readable-docs` |

Their own published one-liner for wiring up the MCP server:

```bash
claude mcp add --transport http 1password-dev https://www.1password.dev/mcp
```

Prefer `<url>.md` over fetching the rendered page: the portal is
JS-hydrated and the HTML is not the friendliest thing to read.

## `op` CLI: versioning, cadence, channels

- **Semver-shaped `MAJOR.MINOR.PATCH`.** Not CalVer. Major is effectively
  frozen — 2.0.0 landed 2022-03-10 and there is no v3.
- Betas are `X.Y.Z-beta.NN` with a two-digit counter (`2.39.0-beta.02`).
- **Cadence is irregular and unscheduled.** Recent stables ran 2.31.1
  (2025-05), 2.32.0 (2025-08), then a six-month gap to 2.32.1 (2026-02), then
  several in quick succession up to 2.39.0 (2026-08-14). Do not infer a
  release rhythm; check the history page.
- **Some minors never reach stable at all** — 2.36.x and 2.37.x exist only as
  betas. A version number missing from the stable list is not necessarily a
  yanked release.
- Channels: **stable and beta only. There is no CLI nightly** (nightly is a
  desktop-app thing). Betas come from the product-history page with "show
  betas" selected, or on Linux by pointing the apt/yum repo at `beta`.
- Beta builds are documented at `https://www.1password.dev/cli/reference#beta-builds`.
- Updating: `brew upgrade --cask 1password-cli` on this machine (it is a
  **cask**, not a formula — which is also why `bin_trace` can read the version
  out of `.../Caskroom/1password-cli/<version>/op` without executing it).
  `op update` also works, and works while signed out.

## Desktop app: versioning, cadence, channels

- **`8.MINOR.PATCH`** (Mac is on 8.12.x). Betas append a build counter:
  `8.12.34-29`.
- Cadence: stable roughly every 2–4 weeks; beta about every 2 weeks; nightly
  about daily.
- **Three channels: Production / Beta / Nightly.** On Mac and Windows they are
  switched in Settings → Advanced → Release channel. iOS betas go through
  TestFlight (no nightly); Android through Google Play; Linux by swapping the
  repo channel to `beta` or `edge`.
- Joining betas: `https://support.1password.com/betas/`

## SDKs

Go, JavaScript/TypeScript, and Python, documented at
`https://www.1password.dev/sdks` (capability matrix at `/sdks/functionality`).

**They are all 0.x and explicitly not GA**, and the stability policy is worth
knowing before depending on one:

- Breaking changes are **allowed between minors** (0.1.x → 0.2.0).
- Patch releases (0.1.X → 0.1.Y) will not break.
- Three months of support and security patches for version 0.
- So: pin them.

Relative to the CLI they still **cannot** do user/group provisioning, Events
(use the Events API directly), Watchtower, Travel Mode, passkeys, or Connect
authentication — Connect keeps its own separate legacy SDKs.

## Where changelogs actually live

Three hosts, split by audience. This split is the thing to remember, because
the docs site is the one place that mostly does *not* have changelogs.

**1. `releases.1password.com`** — customer-facing release notes, one page per
product and channel, with **RSS at `<page>/index.xml`**:

| Feed | URL |
|---|---|
| CLI stable | `https://releases.1password.com/developers/cli/index.xml` |
| CLI beta | `https://releases.1password.com/developers/cli-beta/index.xml` |
| SDKs | `https://releases.1password.com/developers/sdks/` |
| Mac app stable | `https://releases.1password.com/mac/stable/` |
| Mac app beta | `https://releases.1password.com/mac/beta/` |

Caveat: these pages are JS-hydrated and the RSS `<link>` is not in a `<head>`,
so **feed autodiscovery fails**. Construct the `/index.xml` URL by hand; it
works and returns `text/xml`.

**2. `app-updates.agilebits.com/product_history/CLI2`** — the raw,
server-rendered, complete version history with per-arch download links and
New / Improvements / Fixed / Security subsections. **This is the right target
for "what changed in `op` since version X"** — it is the only one that lists
every stable and beta back to 2.0.0 on one page. Per-version permalinks are
`https://app-updates.agilebits.com/relnotes/CLI2/en/2/<build>` (2.39.0 is
build `2390001`).

**3. `www.1password.dev`** — documentation. Carries only two changelog-ish
things: the Events API changelog (`/events-api/changelog`) and the CLI 1→2
migration guide (`/cli/upgrade`). Everything else links out to
`releases.1password.com`.

Plus `support.1password.com` for end-user matters (betas, channels) and
`1password.community` for the forums.

## How breaking changes get announced

Honestly: **there is no published deprecation policy for the `op` CLI**, and
no breaking-change feed for the desktop app either. This was searched for
specifically and is not a gap in the search.

What exists:

- Within `op` 2.x, changes — breaking ones included — are announced **only in
  the changelog entries** on the product-history page.
- The one formal migration document is the CLI 1 → 2 guide at
  `https://www.1password.dev/cli/upgrade`, which carries the CLI 1 deprecation
  date (2024-10-01) and an old-command → new-command mapping table.
- The **Events API is the exception**: it has a properly versioned changelog
  with migration-impact notes at `/events-api/changelog`, and its v2 endpoints
  are explicitly flagged as breaking relative to v1.
- The SDKs state their policy in prose at `/sdks#about-the-current-version`
  (breaking between minors, safe between patches).

Practical consequence for this skill: **the version stamp is the mechanism,
because upstream provides no announcement to subscribe to.** Nothing will tell
you these notes went stale; comparing versions is the substitute.

## Refreshing this skill

When `onepassword-doctor` reports drift:

1. Read the diff between the stamped `op` version and the installed one at
   `https://app-updates.agilebits.com/product_history/CLI2`.
2. Skim the app's notes at `https://releases.1password.com/mac/stable/` for
   anything touching the SSH agent, the CLI integration, or commit signing —
   those are the three surfaces this skill makes claims about.
3. Re-verify the claims that moved, against the **installed binaries**, not
   from memory. `op <cmd> --help` is authoritative for the CLI surface;
   `../SKILL.md` describes how to probe `op-ssh-sign` without making a commit.
4. Pull any changed doc page as Markdown (`<url>.md`) rather than HTML.
5. Bump `../VERSIONS` **in the same change** as the re-verification.
