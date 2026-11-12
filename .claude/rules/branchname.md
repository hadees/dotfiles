---
paths:
  - "**/bin/executable_branchname"
  - "**/tests/branchname.bats"
  - "**/dot_zsh_prompt"
  - "**/tests/prompt.bats"
---

# branchname

**`bin/branchname` is the one reader of what a renderer shows where a branch
name goes**, the way `tabname` is for tab names. A `claude-peer` slot is a
worktree made with `git worktree add --detach`, so git alone shows only a sha
there; the helper turns a recorded base into a marked name instead.

**The rule every renderer follows (frozen).**

1. On a branch: the branch, behind the renderer's branch glyph. As before.
2. Detached, with a usable base record and no rebase or bisect in progress:
   the base, marked. A renderer that can draw U+F417 (`nf-oct-git_commit`)
   prints the glyph, a space, then the label (field 2): `<U+F417> (main)`.
   Any other prints the label alone, `(main)`. Glyph *and* parentheses is
   the operator's choice (2026-11-12), so the glyph form still reads as
   detached to an eye that does not know the icon. Neither prints the
   branch glyph. Ahead/behind arrows count
   against the recorded ref (field 3).
3. Detached otherwise (no record, bisect, rebase, a tag): the short sha, no
   arrows. As before.

**The fields.** `branchname [--state] [dir]` prints the label; with
`--state`, `<state><TAB><label><TAB><ref><TAB><name>`. States `branch`,
`base`, `detached`. No field is ever empty (an empty field would shift the
rest left under `read`); a detached HEAD's ref is `-`. Not a repository or no
commit: nothing, exit 1, never 0 with empty output.

**The record.** `<absolute git dir>/claude-peer.base`: line 1 the display name
(`main`), line 2 the full ref (`refs/remotes/origin/main`). `claude-peer`
writes it when it makes a slot; nothing else does. It counts only when line 1
is non-empty, line 2 starts `refs/heads/` or `refs/remotes/` and resolves to a
commit, and the git dir holds no `rebase-merge`, `rebase-apply` or
`BISECT_LOG` (mid-rebase the record would name the wrong branch). Being a
linked worktree is not part of the rule; the record is.

**The format key shapes the name only.** `branchname.detached-format`,
default `{base}`, placeholders `{base}` and `{worktree}` (toplevel basename);
empty means the default. The parentheses and the glyph are not configurable,
so no setting can make a slot print the same line as Lead. Control characters
are stripped; a name that strips to nothing falls back to the base.

**No glyph in the helper.** It prints plain ASCII under the default format: a
private-use glyph is a tofu box in a hook message or a terminal without a
patched font. Each renderer already knows whether it can draw glyphs
(`has-glyphs` for the prompt, the status line's `nerd` argument) and draws
its own glyph in front of the label. Field 4, the unmarked name, stays in
the contract for a renderer that wraps the name its own way; neither
renderer here uses it.

**The label is for people.** Scripts and hooks use the state word and the
ref, or ask git; the allow-list test in `tests/branchname.bats` names the only
files that may mention the helper. `git worktree list`, `worktabs status` and
`workset` keep printing the truth (`(detached HEAD)`, `HEAD`).

**Cost.** One git call on a branch (it runs in a once-a-second status line),
about four when detached. Read-only, no network, fine under
`GIT_OPTIONAL_LOCKS=0`.

**The prompt (`dot_zsh_prompt`).** `prompt_git` asks git first
(`symbolic-ref`); only when that fails, and `~/bin/branchname` is
executable, it runs `branchname --state` once; anything but `base` (or no
helper, no output) falls back to the short sha, then `(unknown)`. The base
prints as `${nf_detached}` then the label, with no `${nf_branch}`, `%`
doubled. Arrows try `@{upstream}` first, then field 3 when it starts `refs/`.
`nf_detached` is gated on its own `has-glyphs f417` call inside the `nf_on`
block (over ssh, iTerm2 identity vouches for it), never added to the core
`e0a0 f09b f08c0` gate: a font without U+F417 would lose every glyph and the
cached answer for the other three. Without it the base prints `(main)`.

**The status line's key.** `dot_gitconfig` sets
`statusline.detached-command = ~/bin/branchname`, above the final
`[include]` so an overlay can override it. Nothing in this repo reads it;
the status line (its own repository) does, and draws the same two forms
from its `nerd` argument.

**Tests.** `tests/prompt.bats` covers both paths and the mixed font. Glyph
tests need a UTF-8 locale (zsh 5.9 stops at a `\U` escape under `C`) and
skip without one; on Darwin a test fails if none exists, so they cannot all
skip there. Glyph bytes are octal escapes, never `\u` or a pasted literal.
