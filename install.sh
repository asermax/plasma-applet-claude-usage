#!/bin/bash

# Claude Code Usage Plasma Applet Installation Script
# This script installs the plasmoid to the user's local directory

set -e

PLUGIN_ID="com.github.claude-usage"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PATH="$HOME/.local/share/plasma/plasmoids/$PLUGIN_ID"

echo "=========================================="
echo " Claude Code Usage Plasmoid Installer"
echo "=========================================="
echo ""

# Remove existing installation
if [ -d "$INSTALL_PATH" ]; then
    echo "Removing existing installation..."
    rm -rf "$INSTALL_PATH"
fi

# Create directory
echo "Creating directories..."
mkdir -p "$INSTALL_PATH"

# Copy files
echo "Copying files..."
cp -r "$SCRIPT_DIR/contents" "$INSTALL_PATH/"
cp "$SCRIPT_DIR/metadata.json" "$INSTALL_PATH/"

echo ""
echo "✓ Installed to: $INSTALL_PATH"
echo ""

# Reload Plasma (optional)
read -p "Reload Plasma now? [y/N] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Reloading Plasma..."
    kquitapp6 plasmashell && kstart plasmashell &
fi

echo "=========================================="
echo " Installation Complete!"
echo "=========================================="
echo ""
echo "To add the widget:"
echo "  1. Right-click on your panel"
echo "  2. Select 'Add Widgets'"
echo "  3. Search for 'Claude Code Usage'"
echo "  4. Drag it to your panel"
echo ""
echo "Then configure the services you want to track:"
echo "  1. Right-click widget → Configure"
echo "  2. Enable Claude and/or Antigravity (both read their CLIs, no token needed)"
echo "  3. Paste your GLM or Codex token for those two"
echo ""
