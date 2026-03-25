# Claude Code Usage Plasma Applet

A KDE Plasma 6 system tray widget that displays Claude Code usage statistics.

## Features

- Displays session (5-hour) and weekly (7-day) usage percentages
- Color-coded status (green/yellow/red based on thresholds)
- Shows extra usage (monthly) when enabled on your account
- Automatic cookie extraction from Chrome or Firefox
- Configurable refresh interval
- Optional manual session key configuration

## Requirements

- KDE Plasma 6.0 or higher
- Python 3.x
- A web browser with an active claude.ai session (Chrome or Firefox)

## Installation

### Quick Install

```bash
./install.sh
```

### Manual Install

```bash
mkdir -p ~/.local/share/plasma/plasmoids/com.github.claude-usage
cp -r contents metadata.json ~/.local/share/plasma/plasmoids/com.github.claude-usage/
```

Then right-click on your panel → Add Widgets → search for "Claude Code Usage".

## Running the Backend Server

The widget requires a Python backend server to fetch usage data. Start it with:

```bash
# One-time start (foreground)
python3 ~/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --server

# Background start
python3 ~/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --server &

# Using systemd user service (recommended for auto-start)
# Create ~/.config/systemd/user/claude-usage.service:
```

```ini
[Unit]
Description=Claude Code Usage Backend
After=network.target

[Service]
Type=simple
ExecStart=%h/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --server
Restart=on-failure

[Install]
WantedBy=default.target
```

Then enable and start:
```bash
systemctl --user enable --now claude-usage
```

## One-shot Usage (for Testing)

To test the backend without the server:

```bash
python3 ~/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --once
```

This outputs JSON directly to stdout.

## Configuration

Right-click the widget and select "Configure" to access settings:

| Option | Description | Default |
|--------|-------------|---------|
| Refresh interval | How often to update usage data | 300 seconds |
| Show weekly in tray | Display weekly usage instead of session | No |
| Warning threshold | Percentage for yellow color | 75% |
| Critical threshold | Percentage for red color | 90% |
| Manual session key | Optional override for browser cookies | (empty) |
| Browser for cookies | Which browser to extract cookies from | Auto-detect |

## How It Works

1. The Python backend extracts the `sessionKey` cookie from your browser (Chrome or Firefox)
2. It calls the Claude.ai web API to get organization and usage data
3. A local HTTP server (port 17432) provides usage data to the QML widget
4. Usage statistics are displayed in the system tray and popup

## Troubleshooting

### "Server not running"

Start the backend server:
```bash
python3 ~/.local/share/plasma/plasmoids/com.github.claude-usage/contents/code/claude-usage.py --server &
```

### "Login to claude.ai in your browser first"

Make sure you're logged into claude.ai in Chrome or Firefox. The applet needs the session cookie to authenticate.

### "No Claude organization found"

Your account may not have a Claude organization. Make sure you have an active Claude subscription.

### Colors not changing

Check the warning and critical threshold settings in the configuration dialog.

## Development

### File Structure

```
plasma-applet-claude-usage/
├── metadata.json              # Plasma 6 plugin metadata
├── contents/
│   ├── ui/
│   │   └── main.qml           # Main applet UI
│   ├── config/
│   │   ├── config.qml         # Config model
│   │   ├── configGeneral.qml  # Configuration UI
│   │   └── main.xml           # KConfig schema
│   └── code/
│       └── claude-usage.py    # Python backend (HTTP server)
├── README.md
└── install.sh
```

## License

MIT License
