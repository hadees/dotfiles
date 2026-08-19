// Helpers for the Finicky rule fragments (~/.config/finicky/{personal,work}.ts).
// Deployed by the public dotfiles; identity-free. See ~/.finicky.ts.

// A Google Chrome profile by its display name (as shown in Chrome's profile
// menu — Finicky resolves it via Chrome's "Local State", falling back to the
// directory name like "Profile 2").
export const chrome = (profile: string) => ({ name: "Google Chrome", profile });

// Match a hostname exactly or any of its subdomains: hosts("example.com")
// matches example.com and *.example.com, nothing else.
export const hosts =
  (...names: string[]) =>
  ({ host }: { host: string }) =>
    names.some((n) => host === n || host.endsWith("." + n));

// Match everything under one or more GitHub owners (users or orgs):
// github.com/<owner> and github.com/<owner>/...
export const githubOwners =
  (...owners: string[]) =>
  ({ host, pathname }: { host: string; pathname: string }) => {
    if (host !== "github.com") return false;
    const first = pathname.split("/")[1]?.toLowerCase();
    return owners.some((o) => o.toLowerCase() === first);
  };

// Match links opened from an app, by bundle id (Slack: com.tinyspeck.slackmacgap,
// Teams: com.microsoft.teams2, Outlook: com.microsoft.Outlook, ...).
export const openedBy =
  (...bundleIds: string[]) =>
  (_url: unknown, { opener }: { opener: { bundleId: string } | null }) =>
    !!opener && bundleIds.includes(opener.bundleId);

// Match links our own tooling tagged for a profile with `open-as <alias>
// <url>` (~/bin): some URLs are identical no matter which account they will
// authenticate (Tailscale auth/check links, OAuth device-code pages, …), so
// no URL rule can route them — but the tool that printed the URL knows whose
// it is, and open-as appends an opaque token as a #fragment. A fragment is
// never sent to the server, and the token is random (lowercase [a-z0-9]
// plus the standard suffix "q2x", itself random-looking — see open-as for
// the generator), so the page's own scripts learn nothing — only the
// overlay fragment that pairs the token with its profile can decode it,
// host-independently by design:
//   { match: tagged("k3v9qwq2x"), browser: chrome("Some Profile") }
// The other half of the pair is machine-local git config
// (browser.tag.<alias> = <token>), supplied by the same overlay.
export const tagged =
  (token: string) =>
  ({ hash }: { hash?: string }) =>
    !!token && (hash ?? "") === "#" + token;

// Combine matchers: any(hosts("a.com"), githubOwners("x")).
export const any =
  (...matchers: Array<(url: any, options: any) => boolean>) =>
  (url: any, options: any) =>
    matchers.some((m) => m(url, options));

export type Rule = { match: unknown; browser: unknown };
