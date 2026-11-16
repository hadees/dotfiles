---
name: plan-fable
description: Use it when a big idea — a new tool, skill, feature or integration — has been fleshed out in chat and the operator hands it off: says to plan it, drops out of the idea, or moves on to something else; or whenever the operator asks for it by name. Do NOT use it the moment an idea is first floated (shape it in chat first), for a small ask (a lookup, a one-line fix: just do it), for a shape already decided, or for a question answered by reading the code.
tools: Read, Grep, Glob, Bash, WebFetch, WebSearch, Skill, mcp__fetcher__*
model: claude-fable-5-2
effort: high
experimental:
  cacheTtl: 1h
---

{{ template "claude-agent-bodies/planner.md" (dict "seatName" "plan-fable") -}}
