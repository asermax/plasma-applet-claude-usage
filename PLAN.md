# Plan: Add Codex (OpenAI) Usage to Plasma Widget

## Context

The existing KDE Plasma 6 applet displays Claude and GLM usage stats as progress rings (compact view) and progress bars (full popup). The user wants to add **Codex (OpenAI)** usage tracking, showing an **"O"** ring in the system tray and usage details in the popup.

Codex usage data comes from the same API that powers the Codex web dashboard (`chatgpt.com/codex/cloud/settings/analytics#usage`), but we can avoid browser authentication entirely by using the OAuth token that the Codex CLI stores locally.

## Approach

**Use the local Codex OAuth credentials** (`~/.codex/auth.json`) — same approach used by [CodexBar](https://github.com/steipete/CodexBar). This avoids browser cookie extraction and works headlessly.

### Data source

1. Read `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
2. Extract `tokens.access_token` (Bearer token) and optionally `tokens.account_id`
3. Call `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <token>`
4. Parse response with `rate_limit.primary_window` (5h session) and `rate_limit.secondary_window` (weekly)

### API response shape

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window": {
      "used_percent": 42,
      "reset_at": 1779750000,       // unix timestamp
      "limit_window_seconds": 18000  // 5 hours
    },
    "secondary_window": {
      "used_percent": 25,
      "reset_at": 1780000000,
      "limit_window_seconds": 604800 // 7 days
    }
  },
  "credits": {
    "has_credits": true,
    "unlimited": false,
    "balance": 123.45
  }
}
```

### Key differences from Claude/GLM

- **No org/account selection needed** — the token is already scoped
- **Auth is automatic** if `~/.codex/auth.json` exists (no manual config if user has Codex CLI installed)
- The `reset_at` field is a Unix timestamp (seconds), simpler than ISO dates
- `used_percent` goes 0-100 directly; no extra calculation needed

## Files to modify

| File | Changes |
|------|---------|
| `contents/config/main.xml` | Add `codexToken` config entry (optional, for manual token override) |
| `contents/ui/configGeneral.qml` | Add Codex auth section in settings UI |
| `contents/ui/main.qml` | Add Codex data fetching, parsing, compact ring ("O"), full popup section |
| `metadata.json` | Update description to mention Codex |

## Reuse

- **`curlRequest()`** — existing function in `main.qml` handles HTTP with retry and timeout. We'll add Bearer token support (already exists via `opts.bearerToken`).
- **`formatTimeRemaining()`**, **`getUsageColor()`**, **`formatTimeSince()`** — all reusable as-is.
- **Ring rendering pattern** — copy the Claude/GLM `Shape` + `ShapePath` + `PathAngleArc` pattern for the "O" ring.
- **Progress bar pattern** — copy the `RowLayout` + `Rectangle` progress bar pattern for session/weekly bars.
- **Config pattern** — copy the `sessionKey` / `glmToken` config entry pattern for the Codex token override.

## Steps

- [ ] 1. **Add config entry** — Add `codexToken` (String, optional) to `contents/config/main.xml`
- [ ] 2. **Add settings UI** — Add Codex section to `contents/ui/configGeneral.qml` with token field + instructions for finding `~/.codex/auth.json`
- [ ] 3. **Add Codex auth loading** — Add `cfg_codexToken` property and `hasCodexConfig` (true if token is set OR `~/.codex/auth.json` exists). Add auto-load from `auth.json` via `Plasma5Support.DataSource` executable calling `cat`.
- [ ] 4. **Add Codex data fetching** — Implement `fetchCodexUsage()` calling `https://chatgpt.com/backend-api/wham/usage` with Bearer token, parse response into `codexUsageData` (primary_window → session, secondary_window → weekly, credits)
- [ ] 5. **Add "O" compact ring** — Add third `Item` in `compactRepresentation`'s `RowLayout` for Codex, with "O" label, following the Claude/GLM ring pattern
- [ ] 6. **Add Codex full popup section** — Add `ColumnLayout` section (like Claude/GLM) showing session bar, weekly bar, and optionally credits balance
- [ ] 7. **Update tooltip** — Add Codex usage lines to `toolTipSubText`
- [ ] 8. **Update `hasAnyConfig`** — Include Codex in the check
- [ ] 9. **Wire up init and refresh** — Add Codex to `Component.onCompleted`, `refreshAll()`, and timer

## Verification

1. Install the widget: `kpackagetool6 -t Plasma/Applet -i .` (or `plasmapkg2`)
2. Ensure `~/.codex/auth.json` exists (run `codex` CLI if needed)
3. Add widget to panel → should show "O" ring alongside "C" and "G" rings
4. Click to expand → should see Codex section with session (5h) and weekly (7d) progress bars
5. Hover over compact ring → tooltip should show Codex usage percentages
6. Verify colors change correctly based on warning/critical thresholds
7. Test with manual token override in settings (set `codexToken` config)
8. Test error states: no token, invalid token, network errors
