// Finicky (https://github.com/johnste/finicky) is the default "browser": it
// receives every link opened outside a browser and decides which browser —
// and which Chrome profile — gets it, so a link never lands in whichever
// profile's window happened to be active last.
//
// This file is the identity-free composer, deployed by the public dotfiles.
// The actual rules live in fragments that the private overlays own (they
// name accounts, domains, and profiles):
//
//   ~/.config/finicky/personal.ts   personal overlay   (also sets the default)
//   ~/.config/finicky/work.ts       work overlay
//
// The public repo deploys empty stubs for both (`create_` files: written only
// when missing) so this always bundles; an overlay overwrites its own. Both
// import helpers from ~/.config/finicky/lib.ts (public). Finicky bundles
// this file with esbuild, which is why it is .ts (a .js config is copied
// elsewhere before bundling and loses relative imports) and why a fragment
// change needs `touch ~/.finicky.ts` to bust Finicky's bundle cache — the
// dotfiles() function does that after applying overlays.
//
// Rules are tried in order; the first match wins. Work rules go first so a
// work-org URL beats a broader personal rule. Anything unmatched opens in the
// default browser/profile named by the personal fragment.

import * as personal from "./.config/finicky/personal.ts";
import * as work from "./.config/finicky/work.ts";

export default {
  defaultBrowser: personal.defaultBrowser ?? "Google Chrome",
  rewrite: [...(work.rewrite ?? []), ...(personal.rewrite ?? [])],
  handlers: [...(work.default ?? []), ...(personal.default ?? [])],
  options: {
    // Log every routed URL to the Finicky window — invaluable for "why did
    // that open there?"; nothing leaves the machine.
    logRequests: true,
    checkForUpdates: true,
  },
};
