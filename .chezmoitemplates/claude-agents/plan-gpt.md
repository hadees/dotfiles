---
name: plan-gpt
description: Use it when the operator asks for it by name, or when plan-fable has just ended with a confirmed Fable allowance failure and the same brief is handed over once. Do NOT use it as a first choice for a plan plan-fable can take, for any other failure (a generic 429, overload, timeout, authentication or context failure), while plan-fable is still running or consent awaits the operator, or when the GPT route check says unavailable.
tools: Read, Grep, Glob, Bash, WebFetch, WebSearch, Skill, mcp__fetcher__*
model: gpt-6-astra
effort: high
experimental:
  cacheTtl: 1h
---

{{ template "claude-agent-bodies/planner.md" (dict "seatName" "plan-gpt") -}}
