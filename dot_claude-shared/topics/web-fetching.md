## Web fetching

- If WebFetch fails on a resource you need (blocked page, JS-rendered
  content, an error response), retry it through the fetcher MCP tools
  (`mcp__fetcher__fetch_url` / `fetch_urls` — they drive a real browser)
  before giving up. Pass the same fallback instruction to any research
  subagent you brief. If a resource still won't load, say so explicitly in
  the result instead of silently omitting it.
