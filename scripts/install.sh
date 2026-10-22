#!/bin/sh
# Builds Pult, puts it in /Applications and runs its daemon as a login agent.
#
# The daemon runs under launchd rather than from a terminal on purpose: macOS
# grants the right to send keystrokes to whichever process it holds
# responsible, which for anything started from a terminal is the terminal — or
# the editor behind it. As a login agent the daemon answers for itself.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${TARGET:-/Applications/Pult.app}"
AGENT="$HOME/Library/LaunchAgents/dev.pult.daemon.plist"
LABEL="dev.pult.daemon"

"$ROOT/scripts/build-app.sh"

echo "==> stopping anything already running"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
osascript -e 'tell application "Pult" to quit' 2>/dev/null || true
sleep 1

echo "==> installing to $TARGET"
rm -rf "$TARGET"
cp -R "$ROOT/dist/Pult.app" "$TARGET"

# The staged copy has done its job; leaving it behind means two Pults in
# Spotlight and two in Launchpad.
rm -rf "$ROOT/dist/Pult.app"

echo "==> login agent"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>

	<key>ProgramArguments</key>
	<array>
		<string>$TARGET/Contents/MacOS/pultd</string>
	</array>

	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>

	<!-- launchd starts jobs with a bare PATH; \`run\` actions expect a shell's one. -->
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>

	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/pult.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/pult.log</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENT" >/dev/null

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "agent loaded; log: $HOME/Library/Logs/pult.log"

cat <<'NOTE'

If keys bound to a keystroke do nothing, macOS has not trusted the daemon yet:
tick pultd under System Settings > Privacy & Security > Device Control and
Data Access, then

    launchctl kickstart -k gui/$(id -u)/dev.pult.daemon

The binary is signed with a local certificate, so that grant survives every
later rebuild.
NOTE
