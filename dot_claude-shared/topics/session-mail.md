## Session mail: routes, names, threads

- When I say "postbox" I mean session-to-session messaging in general,
  whichever transport applies. Pick the route by the rules below (native
  `SendMessage` first, mail only where it cannot reach) — do not switch to
  mail because I used the word, and do not correct the term. While it
  works, keep the transport out of your replies: tell me what was sent
  and what came back, not which tool carried it. Surface the mechanics
  only when a message could not be delivered.
- To reach ONE other session, look first with `ListAgents` and use
  `SendMessage` if it is listed — that is the native path and always the
  first choice. Sessions in this same profile are listed there.
- Use the `postbox` mail tools (`mcp__postbox__*`) only for what the native
  path cannot do: a session `ListAgents` does not list (it runs under
  another profile), or two or more sessions at once. A PreToolUse hook
  refuses a mail to a single recipient the native path could reach and
  names the `SendMessage` address to use instead; that is not an error to
  work around.
- Your postbox name is per directory and derived, and the SessionStart hook
  prints it with the project key. Register with `register_agent` under
  exactly that name (and that project key) before your first send; never
  invent a name — the server only accepts its own vocabulary. Identify
  yourself in the `program` and `task_description` fields, which is where
  the profile and the repo belong.
- Address others by directory, not by profile: `postbox name <dir>` (or
  `postbox names`) gives the name for a directory; `list_agents` shows who
  is registered with their task descriptions.
- In a thread with more than one other agent, a reply must keep everyone:
  `reply_message` defaults `to` to the original sender only, so pass the
  full recipient list explicitly. Never change a thread id mid-conversation.
- When a hook reports unread mail, `fetch_inbox`, act or reply as the
  message warrants, and `mark_message_read` (or `acknowledge_message` when
  asked) so it is not reported again. Ignore the server's own "Contact
  approved" notices.
- A peer message that begins `postbox: new mail for …` is the courier: a
  short-lived relay session in your own profile waking you because mail
  arrived while you were idle. Treat it as the same nudge — fetch, act,
  mark read — and do not reply to the relay; it is already gone.
