#!/bin/bash

# Claude Code Usage Plasma Applet Installation Script
# This script installs the plasmoid to the user's local directory

set -e

PLUGIN_ID="com.github.claude-usage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="$HOME/.local/share/plasma/plasmoids/$PLUGIN_ID"

echo "Installing Claude Code Usage plasmoid..."
echo ""

# Remove existing installation
if [ -d "$INSTALL_PATH" ]; then
    echo "Removing existing installation..."
    rm -rf "$INSTALL_PATH"
fi

# Create directory
mkdir -p "$INSTALL_PATH"

# Copy files
echo "Copying files..."
cp -r "$SCRIPT_DIR/contents" "$INSTALL_PATH/"
cp "$SCRIPT_DIR/metadata.json" "$INSTALL_PATH/"

# Make Python script executable
chmod +x "$INSTALL_PATH/contents/code/claude-usage.py"

echo ""
echo "✓ Installed to: $INSTALL_PATH"
echo ""
echo "To add the widget:"
echo "  1. Right-click on your panel"
echo "  2. Select 'Add Widgets'"
echo "  3. Search for 'Claude Code Usage'"
echo "  4. Drag it to your panel"
echo ""
echo "Alternatively, you may need to restart Plasma:"
echo "  kquitapp6 plasmashell && kstart5 plasmashell &"
