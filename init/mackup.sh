#!/usr/bin/env bash
# Run once after bootstrap.sh on a new machine to restore app settings.
# Requires ~/.config/Mackup/ to already contain backed-up configs
# (synced via the file_system engine configured in ~/.mackup.cfg).

set -euo pipefail

if ! command -v mackup > /dev/null 2>&1; then
  echo "mackup not found — run: brew bundle" >&2
  exit 1
fi

mackup restore
echo "App settings restored. Run 'mackup backup' on this machine to keep them current."
