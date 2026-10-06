#!/usr/bin/env bats

# tabstatus in dot_functions fills in the session id `it2 set-status` demands.
# it2 is stubbed to record its argv; no test touches a real iTerm2.

setup() {
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$BATS_TEST_TMPDIR" > "$STUB/it2"
  chmod +x "$STUB/it2"
  PATH="$STUB:$PATH"
  DOTFUNCTIONS="$BATS_TEST_DIRNAME/../dot_functions"
}

@test "tabstatus: passes the session uuid, status, detail and extra flags" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus 'reviewing PR' 'on CI' --dot-color '#66cccc'"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|reviewing PR|--detail|on CI|--dot-color|#66cccc" ]
}

@test "tabstatus: no arguments clears status and detail" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status||--detail|" ]
}

@test "tabstatus: idle sends cc-status's idle colours and a zero background count" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus idle"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|idle|--detail||--dot-color|#00d75f|--text-color|#888888|--background-tasks|0" ]
}

@test "tabstatus: working sends the orange pair and no count" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus working"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|working|--detail||--dot-color|#ff9500|--text-color|#ff9500" ]
}

@test "tabstatus: a colour flag suppresses both default colours but idle still zeroes the count" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus idle '' --dot-color '#123456'"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|idle|--detail||--dot-color|#123456|--background-tasks|0" ]
}

@test "tabstatus: an explicit background count is kept" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus idle '' --background-tasks 2"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|idle|--detail||--background-tasks|2|--dot-color|#00d75f|--text-color|#888888" ]
}

@test "tabstatus: free-text status words get no colours" {
  run zsh -c "ITERM_SESSION_ID=w0t1p0:ABC-123; source '$DOTFUNCTIONS'; tabstatus 'reviewing PR'"
  [ "$status" -eq 0 ]
  [ "$(paste -sd'|' "$BATS_TEST_TMPDIR/argv")" = "set-status|--session|ABC-123|--status|reviewing PR|--detail|" ]
}

@test "tabstatus: outside iTerm2 is an error and never calls it2" {
  run zsh -c "unset ITERM_SESSION_ID; source '$DOTFUNCTIONS'; tabstatus working"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside an iTerm2 session"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/argv" ]
}
