#!/bin/sh
# Builds akp03-deck, installs it, and runs it as a login agent.
#
# The binary is installed outside the build directory on purpose: macOS ties
# the Accessibility permission to the binary, so a rebuild must not replace the
# file the agent is running.
set -eu

PREFIX="${PREFIX:-$HOME/.local/bin}"
CONFIG="$HOME/.config/akp03-deck/config.toml"
AGENT="$HOME/Library/LaunchAgents/dev.akp03-deck.plist"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"
cargo build --release

mkdir -p "$PREFIX" "$(dirname "$CONFIG")" "$HOME/Library/LaunchAgents"
cp target/release/akp03-deck "$PREFIX/akp03-deck"
echo "installed $PREFIX/akp03-deck"

# Signing has to happen before the agent starts, or macOS sees a different
# program than the one it was told to trust.
"$ROOT/scripts/sign.sh" "$PREFIX/akp03-deck"

if [ ! -f "$CONFIG" ]; then
	cp config.example.toml "$CONFIG"
	echo "installed $CONFIG"
else
	echo "kept $CONFIG"
fi

# The plist carries absolute paths, so rewrite them for whoever is installing.
sed -e "s|/Users/devic021/.local/bin|$PREFIX|g" \
    -e "s|/Users/devic021/Library/Logs|$HOME/Library/Logs|g" \
    launchd/dev.akp03-deck.plist > "$AGENT"
plutil -lint "$AGENT" >/dev/null

launchctl bootout "gui/$(id -u)/dev.akp03-deck" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "agent loaded; log: $HOME/Library/Logs/akp03-deck.log"

cat <<'NOTE'

If keys bound to `shortcut` do nothing, macOS has not trusted the binary yet:
tick akp03-deck under System Settings > Privacy & Security > Accessibility,
then restart the agent with

    launchctl kickstart -k gui/$(id -u)/dev.akp03-deck

This install signs the binary with a local certificate, so later rebuilds keep
that permission instead of silently losing it.
NOTE
