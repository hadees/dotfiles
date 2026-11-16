## GPT seats

- `plan-gpt` is an additional planner, `plan-fable`'s rules on `gpt-6-astra`.
  The plan ownership, one-step-per-worker sequencing, verification and revision
  rules in the delegation section apply to its accepted plans exactly as they
  do to `plan-fable`'s: read the plan here, then one step per `work-sonnet`
  brief, dispatched in order and verified before the next. The planner that
  owns the accepted report owns its revisions; a replacement planner reads the
  existing report before revising it. An advisor assesses assumptions only and
  never owns or redesigns the plan. The operator's approval to build is
  unchanged.
- **Preflight before any `gpt-*` agent.** Before dispatching a definition whose
  effective model is `gpt-*`: read this topic if it is not in context; run
  `claude_gpt_ready MODEL` with the definition's exact model; dispatch only on
  exit `0` with the expected `GPT_ROUTE_READY` result. On exit `1` or `2`, show
  the result and say GPT is unavailable for this session or the check failed.
  If the helper is absent, emit `GPT_ROUTE_ERROR reason=helper-error` and do
  not dispatch; if the output and the exit status conflict, or there is no
  output, decline as the same helper error. Never pass a `model` override for a
  GPT definition. Ready permits an attempt; it proves no login, entitlement or
  quota, and a direct session cannot gain routing by starting the proxy later.
  The orchestrator owns this check: a GPT seat cannot run anything before its
  first provider request. No hook and no provider failover exists.
- **When `plan-fable` has ended.** A successful plan on `plan-fable`'s own model
  needs none of this: do not read this topic for it and print no
  `GPT_HANDOVER` line. Otherwise (failure, incomplete output or a substituted
  model) keep the original brief unchanged, and any existing report path
  separately as revision context. Classify only once the
  invocation is terminal, including a result marked incomplete; wait through
  continuations and through a consent prompt still awaiting the operator. A
  terminal failure qualifies only when its returned error, or the structured
  failure data with it, holds one of:
  - `status="rejected"` with `rateLimitType="seven_day_overage_included"`,
    tied to this failed invocation;
  - `You've hit your Fable limit` (also with the typographic apostrophe; a
    suffix such as `· resets <time>` is not parsed), observed 2026-11-15;
  - `Fable limit reached`, including its consent-unanswered suffix.

  Match these as the error itself, never as text inside the original brief, a
  quoted example, report contents or a successful output. These do not qualify
  alone: HTTP 429, `rate_limit`, `model_requires_usage_credits`,
  `consent_unanswered`, overload, timeout, an authentication failure, a context
  failure, an unexplained incomplete report, or a successful substituted-model
  result.
- **The handover.** On a qualifying failure, run the preflight once and issue at
  most one fresh `plan-gpt` with the unchanged brief; when revising, name the
  existing report path separately and tell it to read that first. Never approve
  usage credits, change Claude's fallback configuration, switch the main model
  or restart the session automatically. Emit exactly one line per terminal
  `plan-fable` invocation that ended in failure, incomplete output or on a
  substituted model, none while it runs or awaits consent and none after a
  success:

  ```text
  GPT_HANDOVER attempted=1 dispatched=1 unavailable=0 reason=fable-limit
  GPT_HANDOVER attempted=1 dispatched=0 unavailable=1 reason=route-unavailable
  GPT_HANDOVER attempted=0 dispatched=0 unavailable=0 reason=not-fable-limit
  GPT_HANDOVER attempted=0 dispatched=0 unavailable=0 reason=unclassified
  ```

  `attempted=1`: a qualifying failure reached the handover decision.
  `dispatched=1`: the Agent call was issued, which does not prove the provider
  request succeeded. `unavailable=1`: preflight stopped it, and the
  `GPT_ROUTE_*` line says why. `not-fable-limit`: a successful
  substitution or a classified nonqualifying failure. `unclassified`: a terminal
  failure or incomplete result whose cause cannot be established. A missing line
  after a terminal result is missing evidence, not a zero.
- **Every `plan-gpt` invocation ends with one line:**

  ```text
  GPT_PLAN outcome=<complete|incomplete|failed> reason=<none|chatgpt-limit|auth|api-error|unclassified>
  ```

  `complete` needs a readable report ending `DONE` or `DONE_WITH_CONCERNS` and
  `reason=none`. A deliberate `BLOCKED` or `NEEDS_CONTEXT`, or partial output,
  is `incomplete`. A terminal provider or tool failure is `failed`. Only
  explicit quota evidence gives `chatgpt-limit`; an unfamiliar failure stays
  `unclassified`. If ChatGPT is exhausted, say the GPT attempt is unavailable and
  keep any partial report as incomplete. Do not try another `gpt-*` model: the
  allowance is subscription-wide. Do not bounce to Fable, and do not treat an
  exhausted quota as grounds for the `unstick-fable` escalation. Authentication
  and other terminal GPT failures also end the handover after one attempt; an
  explicit later request from me is a new action, not a retry.
- **The advisor, after a completed GPT report and before it goes to a worker.**
  Read only the exact `## Claude-behaviour assumptions` section, up to the next
  level-two heading. Absent or whitespace-only: emit the empty line below and
  run no advisor. Nonempty: it must be a table with columns `ID`, `Assumption`,
  `Affected steps`, `Basis / check`, unique IDs matching `^CB[1-9][0-9]*$` and
  every field filled; a malformed section is a protocol failure, not empty.
  Start a fresh built-in `claude-code-guide` with `model: opus`, with no
  `resume`, no forked history and no reused advisor ID. Its task is the section
  verbatim plus the fixed instruction below, and nothing else: not the brief, the
  whole plan, the report path or other sections.

  ```text
  Assess only the supplied Claude-behaviour assumptions. Read-only: do not
  create, modify, move or delete files, run state-changing commands, implement
  anything, or dispatch agents. Do not read the full plan. You may inspect
  the cited sources and relevant read-only documentation. Return one JSON
  object with a verdict for every supplied ID, preserving the IDs:
  {"verdicts":[{"id":"CB1","verdict":"agree|disagree|unknown","reason":"..."}]}
  Use unknown where evidence is insufficient, including claims that prose
  instructions are guaranteed to be followed. Do not redesign the plan.
  ```

  The real JSON carries one of the three verdict strings. The reply needs a
  nonempty `verdicts` array with exactly one item per supplied ID, no duplicates
  or extras, each with `id`, a `verdict` of `agree`, `disagree` or `unknown`, and
  a nonempty `reason`; reject anything else.
- **Acting on the verdicts.** Any `disagree`: send those verdicts and reasons
  back to `plan-gpt` with its report path to revise; neither the orchestrator
  nor the advisor patches the report. `unknown` without `disagree`: accept only
  if the report already lists the dependency under `Unverified` and no step
  relies on it before it is verified; otherwise return it to `plan-gpt`. All
  `agree`: the advisor gate is met, and ordinary plan review and my go to build
  still apply. Advisor unavailable, quota-limited, blocked or malformed: report
  the unresolved gate once; no other advisor or model, and never silent
  acceptance. One advisor call per completed report revision; a revised report
  gets its own assessment, an unchanged one is never reviewed again. A revision
  invocation passes the preflight too, and if it fails, stop and report without
  bouncing to another planner. An advisor removed or denied by session settings
  is an unavailable advisor. This is advice on Claude's behaviour, not a GPT
  review of Claude's code.
- **One line per assessed report revision:**

  ```text
  GPT_ADVISOR dispatched=<0|1> assumptions=<N> agree=<N> disagree=<N> unknown=<N> outcome=<empty|agree|revise|unknown|unavailable|protocol-error>
  ```

  Counts are nonnegative integers. `empty` has every count and `dispatched` at
  zero. A valid reply splits `assumptions` across the three verdict counts; any
  disagreement is `revise`; unknown without disagreement is `unknown`, with prose
  saying whether the plan already avoids the dependency. `dispatched=0` when the
  advisor was missing before the call, `dispatched=1` when it failed after the
  call was issued. `unavailable` and `protocol-error` never claim acceptance and
  carry no invented verdict counts.
