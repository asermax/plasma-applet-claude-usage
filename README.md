# Claude Code Usage Plasma Applet

A KDE Plasma 6 system tray widget that displays Claude Code usage statistics.

![Screenshot](screenshot.png)

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

## Configuration

Right-click the widget and select "Configure" to access settings:

| Option | Description | Default |
|--------|-------------|---------|
| Refresh interval | How often to update usage data | 300 seconds |
| Show weekly in tray | Display weekly usage instead of session | No |
| Warning threshold | Percentage for yellow color | 75% |
| Critical threshold | Percentage for red color | 90% |
| Browser for cookies | Which browser to extract cookies from | Auto-detect |
| Manual session key | Optional override for browser cookies | (empty) |

## How It Works

1. The applet extracts the `sessionKey` cookie from your browser (Chrome or Firefox)
2. It calls the Claude.ai API to get organization and usage data
3. Usage statistics are displayed in the system tray and popup

## Troubleshooting

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
│   │   └── configGeneral.qml  # Configuration UI
│   └── code/
│       └── claude-usage.py    # Python backend
├── README.md
└── install.sh
```

## License

MIT License
