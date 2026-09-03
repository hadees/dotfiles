# Flavor gitmoji tables

The optional flavor emojis (one, or at most two) that follow the `<type>:`
keyword in a commit subject (see SKILL.md, "Flavor gitmojis"). Each entry
describes *what the change touches* or *extra context* — orthogonal to the
type anchor, which describes *the kind of change*. Consult this table when
picking a flavor; don't guess from memory.

`scripts/check-subject.sh` embeds this same table, because a git hook can't
rely on the skill's `references/` being nearby. `tests/check-subject.bats`
fails if the two copies drift.

## General flavors (75 entries)

Inspired by [gitmoji.dev](https://gitmoji.dev/), with adjustments: joke
entries dropped (`🍻` drunken-code, `💩` bad-code, `🚀` deploy — deploys
aren't commits), and entries marked *(added)* for modern categories gitmoji
missed (observability, caching, containers, ML, webhooks, scheduled jobs,
API contracts, auth-vs-authz separation).

| Emoji | Code | Description |
| ----- | ----- | ----------- |
| 🔥 | `:fire:` | Remove code or files. |
| 🚑️ | `:ambulance:` | Critical hotfix. |
| 💄 | `:lipstick:` | Add or update UI / style files (CSS, themes). |
| 🎉 | `:tada:` | Begin a project. |
| 🔒️ | `:lock:` | Fix security or privacy issues. |
| 🔐 | `:closed_lock_with_key:` | Add or update secrets. |
| 🔖 | `:bookmark:` | Release / version tags. |
| 🚨 | `:rotating_light:` | Fix compiler / linter warnings. |
| 🚧 | `:construction:` | Work in progress. |
| 💚 | `:green_heart:` | Fix CI build. |
| ⬇️ | `:arrow_down:` | Downgrade dependencies. |
| ⬆️ | `:arrow_up:` | Upgrade dependencies. |
| 📌 | `:pushpin:` | Pin dependencies to specific versions. |
| 📈 | `:chart_with_upwards_trend:` | Analytics / product tracking. |
| ➕ | `:heavy_plus_sign:` | Add a dependency. |
| ➖ | `:heavy_minus_sign:` | Remove a dependency. |
| 🔧 | `:wrench:` | Add or update configuration files. |
| 🔨 | `:hammer:` | Add or update development scripts. |
| 🌐 | `:globe_with_meridians:` | Internationalization / localization. |
| ✏️ | `:pencil2:` | Fix typos. |
| 🔀 | `:twisted_rightwards_arrows:` | Merge branches. |
| 👽️ | `:alien:` | Update code due to *external* API changes. |
| 🚚 | `:truck:` | Move or rename resources (files, paths, routes). |
| 📄 | `:page_facing_up:` | Add or update license. |
| 💥 | `:boom:` | Introduce breaking changes. |
| 🍱 | `:bento:` | Add or update assets. |
| ♿️ | `:wheelchair:` | Improve accessibility. |
| 💡 | `:bulb:` | Add or update comments in source code. |
| 💬 | `:speech_balloon:` | Add or update text and literals. |
| 🗃️ | `:card_file_box:` | Database-related changes. |
| 🔊 | `:loud_sound:` | Add or update logs. |
| 🔇 | `:mute:` | Remove logs. |
| 👥 | `:busts_in_silhouette:` | Add or update contributor(s). |
| 🚸 | `:children_crossing:` | Improve user experience / usability. |
| 🏗️ | `:building_construction:` | Make architectural changes. |
| 📱 | `:iphone:` | Work on responsive design. |
| 🤡 | `:clown_face:` | Mock things (testing). |
| 🥚 | `:egg:` | Add or update an easter egg. |
| 🙈 | `:see_no_evil:` | Add or update a `.gitignore` file. |
| 📸 | `:camera_flash:` | Add or update snapshots. |
| ⚗️ | `:alembic:` | Experiment run / study / A-B test — when two flavors are used, this one goes first and the subject area second. |
| 🔍️ | `:mag:` | Improve SEO. |
| 🏷️ | `:label:` | Add or update types. |
| 🌱 | `:seedling:` | Add or update seed / fixture files. |
| 🚩 | `:triangular_flag_on_post:` | Add, update, or remove feature flags. |
| 🥅 | `:goal_net:` | Catch errors. |
| 💫 | `:dizzy:` | Add or update animations and transitions. |
| 🗑️ | `:wastebasket:` | Deprecate code that needs to be cleaned up. |
| 🛂 | `:passport_control:` | Authorization / roles / permissions. |
| 🩹 | `:adhesive_bandage:` | Simple fix for a non-critical issue. |
| 🧐 | `:monocle_face:` | Data exploration / inspection. |
| ⚰️ | `:coffin:` | Remove dead code. |
| 🧪 | `:test_tube:` | Add a failing test. |
| 👔 | `:necktie:` | Add or update business logic. |
| 🩺 | `:stethoscope:` | Add or update healthcheck. |
| 🧱 | `:bricks:` | Infrastructure-related changes. |
| 🧑‍💻 | `:technologist:` | Improve developer experience. |
| 💸 | `:money_with_wings:` | Add sponsorships or money-related infrastructure. |
| 🧵 | `:thread:` | Multithreading or concurrency. |
| 🦺 | `:safety_vest:` | Input validation / data validation. |
| ✈️ | `:airplane:` | Improve offline support. |
| 🦖 | `:t-rex:` | Add backwards-compatibility shim. |
| 🔭 | `:telescope:` | Observability — tracing, spans, metrics, instrumentation. *(added)* |
| 🪣 | `:bucket:` | Caching, cache invalidation, cache layer changes. *(added)* |
| ⏰ | `:alarm_clock:` | Scheduled jobs / cron / timed tasks. *(added)* |
| 🤝 | `:handshake:` | Change to *our own* API contract (shape, semantics). *(added)* |
| 🔑 | `:key:` | Authentication / session management (vs. 🛂 authorization). *(added)* |
| 🪝 | `:hook:` | Webhooks, lifecycle hooks, event hooks. *(added)* |
| 🐳 | `:whale:` | Docker / containers / image builds. *(added)* |
| 🧠 | `:brain:` | ML / AI / model code or weights. *(added)* |
| 📖 | `:book:` | Playbook / orchestration script (Ansible, Salt, IaC playbooks). *(added)* |
| 🤖 | `:robot:` | Automation script / bot / scheduled automation. *(added)* |
| 🧮 | `:abacus:` | Numerical solver / convergence / iterative algorithm. *(added)* |
| 🖼️ | `:framed_picture:` | Figures, schematics, drawings — rendered diagram images and their sources. *(added)* |
| 📊 | `:bar_chart:` | Rendered result tables / run-report summaries (CI job summaries, results tables). *(added)* |

Example uses:

```
✨ feat: 🚩 put the new prompt behind a flag
✨ feat: 🔧 add a per-repo Claude profile pin
🐛 fix: 🚑️ undo the regression that broke every shell
🐛 fix: 🩹 straighten the prompt's git-status spacing
🐛 fix: 🙈 stop tracking the rendered plist
♻️ refactor: 🔥 drop the retired launcher pin
🧰 chore: ⬆️ bump the pinned bats version
🧰 chore: ➕ add shellcheck to the Brewfile
👷 ci: 💚 fix the flaky Rocky Linux job
📦 build: 🏷️ regenerate the type stubs
📝 docs: 💡 explain why op-ssh-sign ignores SSH_AUTH_SOCK
🎨 style: 🚨 shellcheck pass over bin/
```

## Reserved as type anchors

✨ 🐛 ♻️ 📝 ✅ ⚡ 🎨 👷 📦 ⏪ 🧰 are *deliberately omitted* from the flavor
tables — they're the type anchors (see SKILL.md). Their concepts ("introduce
a feature", "fix a bug", …) describe the *kind* of change, which the type
prefix already captures. Reaching for one usually means the concept you want
has its own flavor — 🎨 as "figure" is 🖼️, ⚡ as "electrical power" is 🔋,
✅ as "validation" is 🦺. If none fits and the reserved anchor genuinely
describes a second kind of change, the commit is doing two things — split it.
