# Claude Code Usage Plasma Applet

A KDE Plasma 6 system tray widget that displays Claude Code usage statistics.

## Features

- Displays session (5-hour) and weekly (7-day) usage percentages
- Color-coded status (green/yellow/red based on thresholds)
- Shows extra usage (monthly) when enabled on your account
- Configurable refresh interval
- Manual session key configuration (simple copy-paste from browser)

## Requirements

- KDE Plasma 6.0 or higher
- A claude.ai account with active subscription

## Installation

### Quick Install

```bash
./install.sh
```

Then right-click on your panel → Add Widgets → search for "Claude Code Usage".

### Manual Install

```bash
mkdir -p ~/.local/share/plasma/plasmoids/com.github.claude-usage
cp -r contents metadata.json ~/.local/share/plasma/plasmoids/com.github.claude-usage/
```

## Configuration

Right-click the widget and select "Configure" to access settings:

1. **Session Key** (required): Your claude.ai session cookie
   - Go to [claude.ai](https://claude.ai) and login
   - Open browser DevTools (F12)
   - Go to Application → Cookies → `claude.ai`
   - Find `sessionKey` and copy its value
   - Paste it in the configuration

2. **Refresh interval**: How often to update (default: 5 minutes)

3. **Warning threshold**: Percentage for yellow color (default: 75%)

4. **Critical threshold**: Percentage for red color (default: 90%)

5. **Show weekly in tray**: Display weekly usage in tray instead of session

## How It Works

The widget makes direct HTTPS requests to the Claude.ai web API using your session cookie:

1. Fetches organization info from `https://claude.ai/api/organizations`
2. Gets usage data from `https://claude.ai/api/organizations/{org_id}/usage`
3. Optionally fetches extra usage from thehttps://claude.ai/api/organizations/{org_id}/overage_spend_limit`

All processing happens locally in QML/JavaScript - no external services or backends needed.

## Troubleshooting

### "Configure your session key"

Click the widget and follow the instructions to get your session key from the browser.

### "Session expired - update cookie in config"

The session key has expired. Go back to claude.ai, get a new session key, and update the configuration.

### "Failed to fetch organizations: 401/403"

Your session key is invalid or expired. Get a fresh one from the browser.

### Widget shows "?"

The widget hasn't fetched data yet or no session key is configured.

## Development

### File Structure

```
plasma-applet-claude-usage/
├── metadata.json              # Plasma 6 plugin metadata
├── contents/
│   ├── ui/
│   │   └── main.qml           # Main applet UI (all logic here)
│   └── config/
│       ├── config.qml          # Config model
│       ├── configGeneral.qml   # Configuration UI
│       └── main.xml            # KConfig schema
├── install.sh
└── README.md
```

## License

MIT License
