#!/bin/sh
# Validates a commit subject against the personal git conventions:
#
#   <type-emoji> <type>[(<scope>)][!]: [<flavor-emoji> [<flavor-emoji>] ]<subject>
#
# - the leading emoji must be the canonical anchor FOR that type
# - an optional Conventional-Commits scope is accepted: a bare
#   letters/digits/._- token in parentheses after the type
# - up to two optional flavor emojis must come from the flavor tables and
#   must not be reserved type anchors; a third flavor is rejected
# - the subject text must be non-empty
# - emoji comparison ignores U+FE0F variation selectors (pickers insert
#   them inconsistently; ⚡️ and ⚡ are the same anchor)
#
# usage: check-subject.sh COMMIT_MSG_FILE     (doubles as a git commit-msg
#        check-subject.sh -                    hook: cp into .git/hooks/commit-msg)
#        check-subject.sh --list-anchors|--list-flavors
#
# The emoji tables are embedded (a git hook can't rely on the skill's
# references/ being nearby); tests/check-subject.bats diffs them against
# references/flavors.md so the copies cannot drift. Exit 0 = valid.
set -u

# One "emoji type" pair per line — the 11 Conventional Commits type anchors.
anchors='✨ feat
🐛 fix
♻️ refactor
📝 docs
✅ test
🧰 chore
⚡ perf
🎨 style
👷 ci
📦 build
⏪ revert'

# One emoji per line — the flavor table from references/flavors.md,
# same order.
flavors='🔥
🚑️
💄
🎉
🔒️
🔐
🔖
🚨
🚧
💚
⬇️
⬆️
📌
📈
➕
➖
🔧
🔨
🌐
✏️
🔀
👽️
🚚
📄
💥
🍱
♿️
💡
💬
🗃️
🔊
🔇
👥
🚸
🏗️
📱
🤡
🥚
🙈
📸
⚗️
🔍️
🏷️
🌱
🚩
🥅
💫
🗑️
🛂
🩹
🧐
⚰️
🧪
👔
🩺
🧱
🧑‍💻
💸
🧵
🦺
✈️
🦖
🔭
🪣
⏰
🤝
🔑
🪝
🐳
🧠
📖
🤖
🧮
🖼️
📊'

case "${1:-}" in
--list-anchors) printf '%s\n' "$anchors"; exit 0 ;;
--list-flavors) printf '%s\n' "$flavors"; exit 0 ;;
esac

file="${1:?usage: check-subject.sh COMMIT_MSG_FILE|-}"
if [ "$file" = "-" ]; then
  subject=$(head -n 1)
else
  subject=$(head -n 1 "$file")
fi

fail() {
  echo "check-subject: $1" >&2
  echo "  subject: $subject" >&2
  exit 1
}

[ -n "$subject" ] || fail "empty subject"

# Git-generated messages are exempt (merges, autosquash fixups).
case "$subject" in
"Merge "* | "fixup!"* | "squash!"*) exit 0 ;;
esac

case "$subject" in
*" "*) ;;
*) fail "expected '<emoji> <type>: <subject>'" ;;
esac

anchor=${subject%% *}
rest=${subject#* }

case "$rest" in
*": "*) ;;
*) fail "missing '<type>: ' after the anchor emoji (expected '<emoji> <type>: <subject>')" ;;
esac

type_part=${rest%%:*}
after=${rest#*: }

case "$type_part" in
*!) type_kw=${type_part%!} ;;
*) type_kw=$type_part ;;
esac

# Optional Conventional-Commits scope: <type>(<scope>) — strip and validate.
case "$type_kw" in
*\(*\))
  scope=${type_kw#*\(}; scope=${scope%\)}
  type_kw=${type_kw%%\(*}
  printf '%s' "$scope" | grep -qxE '[A-Za-z0-9][A-Za-z0-9._-]*' \
    || fail "bad scope '($scope)' — a scope is one letters/digits/._- token"
  ;;
esac

# Emoji comparison ignores U+FE0F (variation selector-16): emoji pickers
# insert it inconsistently, so ⚡️ and ⚡ must compare equal. The selector is
# stripped from both the input tokens and the embedded tables; sed treats
# the character as a literal string, so no other emoji's bytes are touched.
VS16=$(printf '\357\270\217')
strip_vs() { printf '%s\n' "$1" | sed "s/$VS16//g"; }
anchor_n=$(strip_vs "$anchor")
anchors_n=$(strip_vs "$anchors")

printf '%s\n' "$anchors_n" | grep -qxF -e "$anchor_n $type_kw" || {
  if printf '%s\n' "$anchors" | grep -q " $type_kw\$"; then
    want=$(printf '%s\n' "$anchors" | grep " $type_kw\$" | cut -d' ' -f1)
    fail "type '$type_kw' takes the anchor $want, not '$anchor'"
  fi
  fail "unknown anchor/type pair '$anchor $type_kw' — see the type-anchor table in SKILL.md"
}

[ -n "$after" ] || fail "empty subject text after '$type_kw:'"

# A flavor emoji is the first token after the colon when it matches the
# flavor tables exactly. Reserved anchors are rejected; anything else is
# treated as the start of the subject text.
# Up to TWO flavor emojis may follow the colon (when two, the first is the
# marker — ⚗️ — and the second the subject area; see SKILL.md).
# A token is a flavor when it matches the tables exactly; anything else is
# the start of the subject text. Reserved anchors are rejected in either
# flavor position; a third flavor is rejected outright.
anchor_set=$(printf '%s\n' "$anchors_n" | cut -d' ' -f1)
flavors_n=$(strip_vs "$flavors")
tok=${after%% *}
tok_n=$(strip_vs "$tok")
if printf '%s\n' "$anchor_set" | grep -qxF -e "$tok_n"; then
  fail "'$tok' is a type anchor, not a flavor — if it fits, the commit is doing two things; split it"
fi
if printf '%s\n' "$flavors_n" | grep -qxF -e "$tok_n"; then
  [ "$tok" != "$after" ] || fail "flavor '$tok' with no subject text after it"
  rest2=${after#* }
  tok2=${rest2%% *}
  tok2_n=$(strip_vs "$tok2")
  if printf '%s\n' "$anchor_set" | grep -qxF -e "$tok2_n"; then
    fail "'$tok2' is a type anchor, not a flavor — if it fits, the commit is doing two things; split it"
  fi
  if printf '%s\n' "$flavors_n" | grep -qxF -e "$tok2_n"; then
    [ "$tok2" != "$rest2" ] || fail "flavor '$tok2' with no subject text after it"
    rest3=${rest2#* }
    tok3=${rest3%% *}
    tok3_n=$(strip_vs "$tok3")
    if printf '%s\n' "$flavors_n" | grep -qxF -e "$tok3_n"; then
      fail "at most two flavor emojis — '$tok3' is a third; put it in the body"
    fi
  fi
fi

exit 0
