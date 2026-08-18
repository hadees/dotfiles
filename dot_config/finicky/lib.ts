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

// Combine matchers: any(hosts("a.com"), githubOwners("x")).
export const any =
  (...matchers: Array<(url: any, options: any) => boolean>) =>
  (url: any, options: any) =>
    matchers.some((m) => m(url, options));

export type Rule = { match: unknown; browser: unknown };
