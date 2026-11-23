# Claude Code Usage Plasma Applet

A KDE Plasma 6 system tray widget that displays Claude Code usage statistics.

## Features

- Displays session (5-hour) and weekly (7-day) usage percentages
- Tracks several services side by side: Claude, GLM (z.ai), Codex and Antigravity
- Color-coded status (green/yellow/red based on thresholds)
- Configurable refresh interval

## Requirements

- KDE Plasma 6.0 or higher
- A subscription for at least one of the services you want to track
- The matching CLI, logged in, for the services that need one (see Configuration)

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

1. **Enabled** (Claude, Antigravity): Both are read from their CLIs, so there is nothing to paste
   - Claude: the `claude` binary from `claude-code`, logged in
   - Antigravity: the `agy` binary from `antigravity-cli`, logged in
   - Each switch stays disabled when its CLI is not in `PATH`

2. **GLM Token**: Open platform token from z.ai, pasted from the browser

3. **Codex Token** (optional): Leave empty to reuse `~/.codex/auth.json`

4. **Refresh interval**: How often to update (default: 5 minutes)

5. **Warning threshold**: Percentage for yellow color (default: 75%)

6. **Critical threshold**: Percentage for red color (default: 90%)

Claude needs no token either. The widget runs
`claude -p "/usage" --output-format json` and parses the session and weekly lines from the report,
so it needs the [Claude Code](https://github.com/anthropics/claude-code) CLI (`claude-code`,
providing `claude`) installed and logged in on the same machine. The switch stays disabled when
`claude` is not in `PATH`.

That command runs locally and costs no API usage, so polling it does not eat into the limits the
widget reports. A poll takes about six seconds.

### Antigravity

Antigravity needs no token. The widget runs `agy -p "/quota" --output-format json` and reads the
Gemini model group's 5-hour and weekly windows, so it needs the
[Antigravity CLI](https://antigravity.google) (`antigravity-cli`, providing `agy`) installed and
logged in on the same machine. The switch stays disabled when `agy` is not in `PATH`.

Antigravity takes about four seconds per poll, since each refresh starts the CLI.

## How It Works

Each service is read from a CLI or an HTTPS endpoint:

- Claude: `claude -p "/usage" --output-format json`
- GLM: `https://api.z.ai/api/monitor/usage/quota/limit` with your token
- Codex: `https://chatgpt.com/backend-api/wham/usage` with your OAuth token
- Antigravity: `agy -p "/quota" --output-format json`

All processing happens locally in QML/JavaScript - no external services or backends needed.

## Troubleshooting

### "Claude Code CLI (claude) not found in PATH"

Install the `claude-code` package and run `claude` once to log in.

### "Claude Code CLI failed"

The CLI exited with an error, usually an expired login. Run `claude` in a terminal and check that
`/usage` prints a report there.

### "Antigravity CLI (agy) not found in PATH"

Install the `antigravity-cli` package. The widget only shells out to the CLI for Antigravity quota and
cannot read it any other way.

### Widget shows "?"
The widget hasn't fetched data yet or no service is configured.

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
