#!/usr/bin/env bash
# Dev install. Writes a LaunchAgent plist; does NOT touch agent configs —
# that happens via `station provider install <id>`, which shows a diff first.
set -euo pipefail
LABEL="dev.agentstation.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$(cd "$(dirname "$0")/.." && pwd)/daemon/.build/release/agentstationd"

[ -x "$BIN" ] || { echo "Build first: make daemon"; exit 1; }

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Loaded $LABEL. Logs: /tmp/$LABEL.err.log"
