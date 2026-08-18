#!/usr/bin/env bash
# Drive this chezmoi source without touching the real $HOME: render it into
# a sandbox home for a machine class, then poke the result — an interactive
# zsh (the "app": prompt, aliases, functions, wrappers, doctors) under tmux,
# or one-shot commands. `live` is the real thing on this machine.
#
#   driver.sh sandbox [class]     render into $SANDBOX (default mac); prints the path
#   driver.sh shell <cmd...>      run <cmd> in an interactive zsh inside the sandbox
#   driver.sh tui                 start the sandbox zsh in tmux session $TMUX_SESSION
#   driver.sh send <keys...>      tmux send-keys to it (Enter appended)
#   driver.sh pane                capture the pane (the "screenshot")
#   driver.sh stop                kill the tmux session
#   driver.sh live                what the REAL machine would change (chezmoi diff for the
#                                 public source and every overlay config) + `doctor` here;
#                                 applying is the `dotfiles` shell function, not this script
#   driver.sh test [bats args]    bats tests
#   driver.sh clean               remove the sandbox
#
# Env: SANDBOX (default /tmp/dotfiles-sandbox), TMUX_SESSION (default dotfiles),
#      OVERLAYS="src1 src2" — extra chezmoi sources applied on top in the sandbox
#      (an overlay's own driver passes itself here).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SANDBOX="${SANDBOX:-/tmp/dotfiles-sandbox}"
TMUX_SESSION="${TMUX_SESSION:-dotfiles}"

# Every chezmoi/zsh invocation in the sandbox gets this environment: HOME
# and the XDG dirs pinned inside it so nothing reads or writes the real
# ones (chezmoi's own config/state live under XDG_CONFIG_HOME).
sb_env() {
	env -i PATH="$PATH" TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" \
		HOME="$SANDBOX" USER="${USER:-sandbox}" SHELL="$(command -v zsh)" \
		XDG_CONFIG_HOME="$SANDBOX/.config" XDG_DATA_HOME="$SANDBOX/.local/share" \
		XDG_STATE_HOME="$SANDBOX/.local/state" XDG_CACHE_HOME="$SANDBOX/.cache" \
		GIT_CONFIG_NOSYSTEM=1 "$@"
}

cmd_sandbox() {
	local class="${1:-mac}"
	rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
	# --exclude scripts: the package-install scripts must never run here.
	sb_env chezmoi init --source "$REPO" --promptString machineClass="$class" --apply --exclude scripts
	local src
	for src in ${OVERLAYS:-}; do
		sb_env chezmoi --config "$SANDBOX/.config/chezmoi/overlay-$(basename "$src").toml" \
			init --source "$src" --promptString machineClass="$class" --apply --exclude scripts
	done
	echo "$SANDBOX  (class=$class${OVERLAYS:+, overlays: $OVERLAYS})"
}

cmd_shell() {
	[ -f "$SANDBOX/.zshrc" ] || { echo "no sandbox at $SANDBOX — run: driver.sh sandbox" >&2; exit 1; }
	# -i so .zshrc (and everything it sources) loads; cd into the sandbox so
	# a stray git repo above /tmp cannot leak identity into the doctors.
	(cd "$SANDBOX" && sb_env zsh -i -c "$*")
}

cmd_tui() {
	[ -f "$SANDBOX/.zshrc" ] || { echo "no sandbox at $SANDBOX — run: driver.sh sandbox" >&2; exit 1; }
	tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
	tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 30 -c "$SANDBOX" \
		"$(printf 'env -i PATH=%q TERM=xterm-256color LANG=en_US.UTF-8 HOME=%q USER=%q SHELL=%q XDG_CONFIG_HOME=%q GIT_CONFIG_NOSYSTEM=1 zsh -i' \
			"$PATH" "$SANDBOX" "${USER:-sandbox}" "$(command -v zsh)" "$SANDBOX/.config")"
	# Ready when the two-line prompt has drawn: "<user> at <host> in <dir>" then "$ ".
	timeout 15 bash -c "until tmux capture-pane -t '$TMUX_SESSION' -p | grep -Eq '^\\$ ?$'; do sleep 0.2; done" \
		|| { echo "prompt never appeared:" >&2; tmux capture-pane -t "$TMUX_SESSION" -p >&2; exit 1; }
	echo "tmux session '$TMUX_SESSION' running zsh in $SANDBOX"
}

cmd_send() { tmux send-keys -t "$TMUX_SESSION" "$*" Enter; sleep 0.5; }
cmd_pane() { tmux capture-pane -t "$TMUX_SESSION" -p; }
cmd_stop() { tmux kill-session -t "$TMUX_SESSION" 2>/dev/null && echo stopped || echo "no session"; }

cmd_live() {
	# Read-only view of the real machine: pending changes per source, and the
	# doctors for the cwd. Applying is `dotfiles` (public, then every overlay
	# whose clone exists) — deliberately not run from here.
	local cfg
	echo "== public: chezmoi diff"; chezmoi diff || true
	for cfg in ~/.config/chezmoi/*.toml; do
		[ "$(basename "$cfg")" = chezmoi.toml ] && continue
		echo "== overlay $(basename "$cfg" .toml): chezmoi diff"
		chezmoi --config "$cfg" diff 2>&1 | grep -v "config file template has changed" || true
	done
	echo "== doctor"; zsh -ic 'doctor' 2>/dev/null
}

cmd_test() { cd "$REPO" && bats tests "$@"; }
cmd_clean() { rm -rf "$SANDBOX"; tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true; echo cleaned; }

case "${1:-}" in
	sandbox|shell|tui|send|pane|stop|live|test|clean) c=$1; shift; "cmd_$c" "$@";;
	*) sed -n '2,20p' "$0"; exit 2;;
esac
