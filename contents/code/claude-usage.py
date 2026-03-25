#!/usr/bin/env python3
"""
Claude Code Usage Backend for KDE Plasma Applet.

Fetches Claude.ai usage statistics using browser session cookies
and outputs JSON for QML consumption.

Usage:
    python3 claude-usage.py [--manual-key SESSION_KEY] [--browser chrome|firefox|auto]

Output JSON format:
    {
        "success": true,
        "session": {"used": 45.5, "resets_at": "2025-03-25T10:30:00Z", "resets_in": "2h 30m"},
        "weekly": {"used": 23.2, "resets_at": "2025-03-28T15:00:00Z", "resets_in": "3 days"},
        "extra_usage": {"used": 12.34, "limit": 50.0, "currency": "USD", "enabled": true},
        "error": null
    }
"""

import argparse
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fetch Claude.ai usage statistics")
    parser.add_argument(
        "--manual-key",
        type=str,
        default=None,
        help="Manual sessionKey cookie value (overrides browser extraction)",
    )
    parser.add_argument(
        "--browser",
        type=str,
        choices=["chrome", "firefox", "auto"],
        default="auto",
        help="Browser to extract cookies from (default: auto)",
    )
    return parser.parse_args()


# ============================================================
# Browser Cookie Extraction
# ============================================================


def get_chrome_cookies_path() -> Optional[Path]:
    """Get the path to Chrome's Cookies database on Linux."""
    chrome_path = Path.home() / ".config" / "google-chrome" / "Default" / "Cookies"
    if chrome_path.exists():
        return chrome_path

    # Try Chrome Beta
    beta_path = Path.home() / ".config" / "google-chrome-beta" / "Default" / "Cookies"
    if beta_path.exists():
        return beta_path

    # Try Chromium
    chromium_path = Path.home() / ".config" / "chromium" / "Default" / "Cookies"
    if chromium_path.exists():
        return chromium_path

    return None


def get_firefox_cookies_path() -> Optional[Path]:
    """Get the path to Firefox's cookies.sqlite database on Linux."""
    firefox_path = Path.home() / ".mozilla" / "firefox"
    if not firefox_path.exists():
        return None

    # Find the active profile (the one with most recent access)
    profiles_ini = firefox_path / "profiles.ini"
    if not profiles_ini.exists():
        return None

    # Look for profiles with cookies.sqlite
    for profile_dir in firefox_path.iterdir():
        if profile_dir.is_dir():
            cookies_path = profile_dir / "cookies.sqlite"
            if cookies_path.exists():
                return cookies_path

    return None


def extract_sessionkey_from_chrome(cookies_path: Path) -> Optional[str]:
    """Extract sessionKey cookie from Chrome's SQLite database."""
    try:
        # Chrome locks the database, so we need to copy it first
        import shutil
        import tempfile

        with tempfile.NamedTemporaryFile(delete=False, suffix=".db") as tmp:
            tmp_path = Path(tmp.name)

        try:
            shutil.copy2(cookies_path, tmp_path)
        except Exception:
            return None

        try:
            conn = sqlite3.connect(str(tmp_path))
            cursor = conn.cursor()
            cursor.execute(
                "SELECT encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%' AND name = 'sessionKey'"
            )
            row = cursor.fetchone()
            conn.close()
        finally:
            tmp_path.unlink(missing_ok=True)

        if row and row[0]:
            # On Linux, Chrome cookies are NOT encrypted (they're stored in plaintext)
            encrypted_value = row[0]
            if isinstance(encrypted_value, bytes):
                # Try to decode as UTF-8 (plaintext on Linux)
                try:
                    return encrypted_value.decode("utf-8")
                except UnicodeDecodeError:
                    pass

        return None
    except Exception:
        return None


def extract_sessionkey_from_firefox(cookies_path: Path) -> Optional[str]:
    """Extract sessionKey cookie from Firefox's SQLite database."""
    try:
        conn = sqlite3.connect(f"file:{cookies_path}?immutable=1", uri=True)
        cursor = conn.cursor()
        cursor.execute(
            "SELECT value FROM moz_cookies WHERE host LIKE '%claude.ai%' AND name = 'sessionKey'"
        )
        row = cursor.fetchone()
        conn.close()

        if row and row[0]:
            return row[0]

        return None
    except Exception:
        return None


def get_session_key(manual_key: Optional[str], browser: str) -> tuple[Optional[str], str]:
    """
    Get the sessionKey cookie value.

    Returns:
        Tuple of (session_key, source_description)
    """
    if manual_key:
        return manual_key, "manual"

    if browser in ("chrome", "auto"):
        chrome_path = get_chrome_cookies_path()
        if chrome_path:
            key = extract_sessionkey_from_chrome(chrome_path)
            if key:
                return key, "chrome"

    if browser in ("firefox", "auto"):
        firefox_path = get_firefox_cookies_path()
        if firefox_path:
            key = extract_sessionkey_from_firefox(firefox_path)
            if key:
                return key, "firefox"

    return None, ""


# ============================================================
# Claude.ai API Calls
# ============================================================


def make_request(url: str, session_key: str) -> tuple[int, Optional[dict]]:
    """Make an authenticated request to Claude.ai API."""
    headers = {
        "Cookie": f"sessionKey={session_key}",
        "Accept": "application/json",
        "User-Agent": "claude-code-usage-plasmoid/1.0",
    }

    request = urllib.request.Request(url, headers=headers, method="GET")

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
            return response.status, data
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


def get_organizations(session_key: str) -> tuple[Optional[str], Optional[str]]:
    """
    Get the first organization ID with chat capability.

    Returns:
        Tuple of (org_id, org_name) or (None, None) on error
    """
    url = "https://claude.ai/api/organizations"
    status, data = make_request(url, session_key)

    if status != 200 or not data:
        return None, None

    if not isinstance(data, list):
        return None, None

    # Find first org with chat capability
    for org in data:
        capabilities = org.get("capabilities", [])
        if "chat" in capabilities:
            return org.get("uuid"), org.get("name")

    # Fallback to first org if no chat capability found
    if data:
        return data[0].get("uuid"), data[0].get("name")

    return None, None


def get_usage_data(session_key: str, org_id: str) -> Optional[dict]:
    """Get usage data for an organization."""
    url = f"https://claude.ai/api/organizations/{org_id}/usage"
    status, data = make_request(url, session_key)

    if status != 200 or not data:
        return None

    return data


def get_extra_usage(session_key: str, org_id: str) -> Optional[dict]:
    """Get extra usage (overage) data for an organization."""
    url = f"https://claude.ai/api/organizations/{org_id}/overage_spend_limit"
    status, data = make_request(url, session_key)

    if status != 200 or not data:
        return None

    return data


# ============================================================
# Time Formatting Helpers
# ============================================================


def parse_iso8601(date_str: Optional[str]) -> Optional[datetime]:
    """Parse ISO 8601 date string."""
    if not date_str:
        return None

    # Try with fractional seconds
    for fmt in ["%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"]:
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue

    return None


def format_time_remaining(resets_at: Optional[datetime]) -> str:
    """Format time remaining until reset."""
    if not resets_at:
        return ""

    now = datetime.now(timezone.utc)
    delta = resets_at - now

    if delta.total_seconds() <= 0:
        return "Resets soon"

    total_seconds = int(delta.total_seconds())
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    days = hours // 24

    if days > 0:
        remaining_hours = hours % 24
        if remaining_hours > 0:
            return f"Resets in {days}d {remaining_hours}h"
        return f"Resets in {days} days"

    if hours > 0:
        return f"Resets in {hours}h {minutes}m"

    return f"Resets in {minutes}m"


def format_reset_date(resets_at: Optional[datetime]) -> str:
    """Format reset date for display."""
    if not resets_at:
        return ""

    now = datetime.now(timezone.utc)
    delta = resets_at - now

    if delta.total_seconds() <= 0:
        return "Now"

    # Convert to local time for display
    local_resets = resets_at.astimezone()

    if delta.days == 0:
        return local_resets.strftime("%-I:%M %p")
    elif delta.days < 7:
        return local_resets.strftime("%b %-d, %-I:%M %p")
    else:
        return local_resets.strftime("%b %-d")


# ============================================================
# Main Output
# ============================================================


def format_output(
    usage_data: Optional[dict],
    extra_data: Optional[dict],
    error: Optional[str] = None,
) -> dict[str, Any]:
    """Format the output for QML consumption."""
    result: dict[str, Any] = {
        "success": error is None,
        "session": None,
        "weekly": None,
        "extra_usage": None,
        "error": error,
    }

    if usage_data:
        # Session (5-hour window)
        five_hour = usage_data.get("five_hour", {})
        session_util = five_hour.get("utilization")
        if session_util is not None:
            session_resets = parse_iso8601(five_hour.get("resets_at"))
            result["session"] = {
                "used": float(session_util),
                "resets_at": five_hour.get("resets_at"),
                "resets_in": format_time_remaining(session_resets),
                "resets_date": format_reset_date(session_resets),
            }

        # Weekly (7-day window)
        seven_day = usage_data.get("seven_day", {})
        weekly_util = seven_day.get("utilization")
        if weekly_util is not None:
            weekly_resets = parse_iso8601(seven_day.get("resets_at"))
            result["weekly"] = {
                "used": float(weekly_util),
                "resets_at": seven_day.get("resets_at"),
                "resets_in": format_time_remaining(weekly_resets),
                "resets_date": format_reset_date(weekly_resets),
            }

    if extra_data and extra_data.get("is_enabled"):
        used_credits = extra_data.get("used_credits", 0)
        monthly_limit = extra_data.get("monthly_credit_limit", 0)
        currency = extra_data.get("currency", "USD")

        # Credits are in cents, convert to dollars
        result["extra_usage"] = {
            "used": used_credits / 100.0,
            "limit": monthly_limit / 100.0,
            "currency": currency,
            "enabled": True,
        }

    return result


def main() -> None:
    args = parse_args()

    # Get session key
    session_key, source = get_session_key(args.manual_key, args.browser)

    if not session_key:
        output = format_output(None, None, "Login to claude.ai in your browser first")
        print(json.dumps(output))
        sys.exit(0)

    # Get organization
    org_id, org_name = get_organizations(session_key)

    if not org_id:
        output = format_output(None, None, "No Claude organization found")
        print(json.dumps(output))
        sys.exit(0)

    # Get usage data
    usage_data = get_usage_data(session_key, org_id)

    if not usage_data:
        output = format_output(None, None, "Failed to fetch usage data")
        print(json.dumps(output))
        sys.exit(0)

    # Get extra usage (optional, don't fail on error)
    extra_data = get_extra_usage(session_key, org_id)

    # Output result
    output = format_output(usage_data, extra_data)
    print(json.dumps(output))


if __name__ == "__main__":
    main()
