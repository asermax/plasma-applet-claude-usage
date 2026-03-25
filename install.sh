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

# Make Python script executable
chmod +x "$INSTALL_PATH/contents/code/claude-usage.py"

echo ""
echo "✓ Installed to: $INSTALL_PATH"
echo ""

# Create systemd user service for auto-start
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/claude-usage.service"

echo "Creating systemd service..."
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Claude Code Usage Backend
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH/contents/code/claude-usage.py --server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo "✓ Service file created: $SERVICE_FILE"
echo ""

# Ask if user wants to enable the service
read -p "Enable and start the backend service now? [Y/n] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    systemctl --user daemon-reload
    systemctl --user enable --now claude-usage.service
    echo "✓ Service started"
else
    echo "To enable later, run:"
    echo "  systemctl --user enable --now claude-usage.service"
fi

echo ""
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
echo "Alternatively, restart Plasma:"
echo "  kquitapp6 plasmashell && kstart5 plasmashell &"
echo ""
