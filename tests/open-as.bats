#!/usr/bin/env bats

# open-as's reserved `iterm2` alias: open a URL in an iTerm2 browser tab in
# the caller's window, reusing that window's tab, and fall open to the normal
# path whenever anything is missing. The real script runs against a fake
# `iterm2` Python module (below) that records every call instead of talking
# to iTerm2, plus stub open/defaults. Nothing here reaches a real iTerm2 or
# browser; all ids are fixtures.

setup() {
  command -v python3 >/dev/null || skip "python3 not installed"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  unset BROWSER OPEN_AS_ALIAS
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cp "$BATS_TEST_DIRNAME/../bin/executable_open-as" "$BIN/open-as"
  chmod +x "$BIN/open-as"
  export PATH="$BIN:$PATH"
  export OPEN_LOG="$BATS_TEST_TMPDIR/open.log" ITERM_LOG="$BATS_TEST_TMPDIR/iterm.log"
  : > "$OPEN_LOG"; : > "$ITERM_LOG"
  cat > "$BIN/open" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$OPEN_LOG"
STUB
  cat > "$BIN/defaults" <<'STUB'
#!/bin/sh
echo "${FAKE_API_SERVER-1}"
STUB
  chmod +x "$BIN/open" "$BIN/defaults"

  # The fake module. FAKE_SESSIONS: "id:window:guid" triples, one per
  # existing session (guid "-" = a terminal session).
  mkdir -p "$BATS_TEST_TMPDIR/py/iterm2"
  cat > "$BATS_TEST_TMPDIR/py/iterm2/__init__.py" <<'PY'
import asyncio, os
def log(*a): open(os.environ["ITERM_LOG"], "a").write(" ".join(map(str, a)) + "\n")
class Profile:
    def __init__(self, guid): self.guid = guid
class Session:
    def __init__(self, sid, guid): self.session_id, self.guid = sid, guid
    async def async_get_profile(self): return Profile(self.guid)
    async def async_load_url(self, url):
        if os.environ.get("FAKE_LOAD_FAIL"): raise RuntimeError("load_url refused")
        log("load_url", self.session_id, url)
    async def async_activate(self, **kw): log("activate", self.session_id)
class Tab:
    def __init__(self, s): self.sessions, self.current_session = [s], s
class Window:
    def __init__(self, wid): self.window_id, self.tabs = wid, []
    async def async_create_tab(self, profile=None, profile_customizations=None):
        if profile and os.environ.get("FAKE_NO_PROFILE"): raise RuntimeError("no such profile")
        log("create_tab", self.window_id, profile or "custom:" + profile_customizations.cmd)
        t = Tab(Session("new", "?")); self.tabs.append(t); return t
    @staticmethod
    async def async_create(connection, profile=None): log("create_window", profile); return Window("fresh")
class LocalWriteOnlyProfile:
    def set_use_custom_command(self, v): self.cmd = v
class App:
    def __init__(self):
        self.windows = {}; self.sessions = {}
        for triple in filter(None, os.environ.get("FAKE_SESSIONS", "").split()):
            sid, wid, guid = triple.split(":")
            w = self.windows.setdefault(wid, Window(wid))
            s = Session(sid, guid); w.tabs.append(Tab(s)); self.sessions[sid] = (s, w)
        self.current_window = self.windows.get(os.environ.get("FAKE_CURRENT", ""))
    def get_session_by_id(self, sid): return self.sessions.get(sid, (None,))[0]
    def get_window_and_tab_for_session(self, s): return (self.sessions[s.session_id][1], None)
async def async_get_app(connection): return App()
def run_until_complete(main): asyncio.run(main(None))
PY
  cat > "$BIN/fakepy" <<STUB
#!/bin/sh
PYTHONPATH="$BATS_TEST_TMPDIR/py" exec python3 "\$@"
STUB
  chmod +x "$BIN/fakepy"
  export OPEN_AS_PYTHON="$BIN/fakepy"
  export OPEN_AS_ITERM_PROFILES="$BATS_TEST_TMPDIR/DynamicProfiles"
  export TERM_PROGRAM=iTerm.app ITERM_SESSION_ID=w0t0p0:caller
  GUID=9ED98362-3781-4A38-BEDC-A6C7D843BC86
}

@test "iterm2: first call writes the profile and opens a tab in the caller's window" {
  FAKE_SESSIONS="caller:w1:- other:w2:-" run open-as iterm2 http://localhost:8080/
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  grep -q "\"Guid\":\"$GUID\"" "$OPEN_AS_ITERM_PROFILES/open-as.json"
  grep -q '"Custom Command":"Browser"' "$OPEN_AS_ITERM_PROFILES/open-as.json"
  [ "$(cat "$ITERM_LOG")" = "create_tab w1 open-as
load_url new http://localhost:8080/" ]
  [ ! -s "$OPEN_LOG" ]
}

@test "iterm2: an existing open-as tab in the window is reused, not duplicated" {
  FAKE_SESSIONS="caller:w1:- tab:w1:$GUID elsewhere:w2:$GUID" OPEN_AS_ALIAS=iterm2 run open-as http://localhost:9/#frag
  [ "$status" -eq 0 ]
  [ "$(cat "$ITERM_LOG")" = "load_url tab http://localhost:9/#frag
activate tab" ]
}

@test "iterm2: unknown caller uses the current window; profile not loaded yet goes ad hoc" {
  FAKE_SESSIONS="x:w3:-" FAKE_CURRENT=w3 FAKE_NO_PROFILE=1 run open-as iterm2 http://localhost:1/
  [ "$status" -eq 0 ]
  [[ "$output" == *"logins in this tab may not persist"* ]]
  [ "$(cat "$ITERM_LOG")" = "create_tab w3 custom:Browser
load_url new http://localhost:1/" ]
}

@test "iterm2: each missing piece falls open to the normal path, tagged, and says why" {
  git config --file "$GIT_CONFIG_GLOBAL" browser.tag.iterm2 ab12cd34q2x
  TERM_PROGRAM=Apple_Terminal run open-as iterm2 http://localhost:1/
  [[ "$output" == *"(not inside an iTerm2 session)"* ]]
  FAKE_API_SERVER=0 run open-as iterm2 http://localhost:2/
  [[ "$output" == *"(Python API disabled"* ]]
  OPEN_AS_PYTHON= run open-as iterm2 http://localhost:3/
  [[ "$output" == *"(no Python runtime"* ]]
  FAKE_SESSIONS="caller:w1:-" FAKE_LOAD_FAIL=1 run open-as iterm2 http://localhost:4/
  [[ "$output" == *"load_url refused"* && "$output" == *"(script failed)"* ]]
  [ "$(cat "$OPEN_LOG")" = "http://localhost:1/#ab12cd34q2x
http://localhost:2/#ab12cd34q2x
http://localhost:3/#ab12cd34q2x
http://localhost:4/#ab12cd34q2x" ]
  # Only the last case got as far as the script; the others never ran it.
  [ "$(cat "$ITERM_LOG")" = "create_tab w1 open-as" ]
}
