#!/usr/bin/env python3
"""
Claude Code Usage Backend for KDE Plasma Applet.

This script provides Claude.ai usage statistics via a local HTTP server
or one-shot JSON output.

Usage:
    python3 claude-usage.py --server     # Run as HTTP server (port 17432)
    python3 claude-usage.py --once       # Run once and output JSON

The HTTP server provides these endpoints:
    GET /usage           - Get current usage data
    POST /config         - Update configuration (manual_key, browser)
    POST /refresh        - Force refresh
"""

import argparse
import json
import os
import signal
import sqlite3
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Optional


# ============================================================
# Configuration
# ============================================================

DEFAULT_PORT = 17432
SERVER_HOST = "127.0.0.1"

# Global config (mutable)
_config = {
    "manual_key": None,
    "browser": "auto",
    "cache": None,
    "cache_time": None,
    "cache_ttl": 60,  # seconds
}


# ============================================================
# Browser Cookie Extraction
# ============================================================


def get_chrome_cookies_path() -> Optional[Path]:
    """Get the path to Chrome's Cookies database on Linux."""
    paths = [
        Path.home() / ".config" / "google-chrome" / "Default" / "Cookies",
        Path.home() / ".config" / "google-chrome-beta" / "Default" / "Cookies",
        Path.home() / ".config" / "chromium" / "Default" / "Cookies",
    ]
    for path in paths:
        if path.exists():
            return path
    return None


def get_firefox_cookies_path() -> Optional[Path]:
    """Get the path to Firefox's cookies.sqlite database on Linux."""
    firefox_path = Path.home() / ".mozilla" / "firefox"
    if not firefox_path.exists():
        return None

    for profile_dir in firefox_path.iterdir():
        if profile_dir.is_dir():
            cookies_path = profile_dir / "cookies.sqlite"
            if cookies_path.exists():
                return cookies_path

    return None


def extract_sessionkey_from_chrome(cookies_path: Path) -> Optional[str]:
    """Extract sessionKey cookie from Chrome's SQLite database."""
    try:
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
            encrypted_value = row[0]
            if isinstance(encrypted_value, bytes):
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


def get_session_key(manual_key: Optional[str] = None, browser: str = "auto") -> Optional[str]:
    """Get the sessionKey cookie value."""
    if manual_key:
        return manual_key

    if browser in ("chrome", "auto"):
        chrome_path = get_chrome_cookies_path()
        if chrome_path:
            key = extract_sessionkey_from_chrome(chrome_path)
            if key:
                return key

    if browser in ("firefox", "auto"):
        firefox_path = get_firefox_cookies_path()
        if firefox_path:
            key = extract_sessionkey_from_firefox(firefox_path)
            if key:
                return key

    return None


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
    """Get the first organization ID with chat capability."""
    url = "https://claude.ai/api/organizations"
    status, data = make_request(url, session_key)

    if status != 200 or not data or not isinstance(data, list):
        return None, None

    for org in data:
        capabilities = org.get("capabilities", [])
        if "chat" in capabilities:
            return org.get("uuid"), org.get("name")

    if data:
        return data[0].get("uuid"), data[0].get("name")

    return None, None


def get_usage_data(session_key: str, org_id: str) -> Optional[dict]:
    """Get usage data for an organization."""
    url = f"https://claude.ai/api/organizations/{org_id}/usage"
    status, data = make_request(url, session_key)
    return data if status == 200 else None


def get_extra_usage(session_key: str, org_id: str) -> Optional[dict]:
    """Get extra usage (overage) data for an organization."""
    url = f"https://claude.ai/api/organizations/{org_id}/overage_spend_limit"
    status, data = make_request(url, session_key)
    return data if status == 200 else None


# ============================================================
# Time Formatting Helpers
# ============================================================


def parse_iso8601(date_str: Optional[str]) -> Optional[datetime]:
    """Parse ISO 8601 date string."""
    if not date_str:
        return None

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

    local_resets = resets_at.astimezone()

    if delta.days == 0:
        return local_resets.strftime("%-I:%M %p")
    elif delta.days < 7:
        return local_resets.strftime("%b %-d, %-I:%M %p")
    else:
        return local_resets.strftime("%b %-d")


# ============================================================
# Output Formatting
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
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    if usage_data:
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

        result["extra_usage"] = {
            "used": used_credits / 100.0,
            "limit": monthly_limit / 100.0,
            "currency": currency,
            "enabled": True,
        }

    return result


def fetch_usage(manual_key: Optional[str] = None, browser: str = "auto") -> dict[str, Any]:
    """Fetch usage data and return formatted result."""
    session_key = get_session_key(manual_key, browser)

    if not session_key:
        return format_output(None, None, "Login to claude.ai in your browser first")

    org_id, org_name = get_organizations(session_key)

    if not org_id:
        return format_output(None, None, "No Claude organization found")

    usage_data = get_usage_data(session_key, org_id)

    if not usage_data:
        return format_output(None, None, "Failed to fetch usage data")

    extra_data = get_extra_usage(session_key, org_id)

    return format_output(usage_data, extra_data)


# ============================================================
# HTTP Server
# ============================================================


class UsageHTTPHandler(BaseHTTPRequestHandler):
    """HTTP request handler for usage data."""

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass

    def _send_json(self, data: dict, status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/usage" or self.path == "/":
            # Check cache
            if _config["cache"] and _config["cache_time"]:
                age = (datetime.now(timezone.utc) - _config["cache_time"]).total_seconds()
                if age < _config["cache_ttl"]:
                    self._send_json(_config["cache"])
                    return

            # Fetch fresh data
            result = fetch_usage(_config["manual_key"], _config["browser"])
            _config["cache"] = result
            _config["cache_time"] = datetime.now(timezone.utc)
            self._send_json(result)
        elif self.path == "/health":
            self._send_json({"status": "ok"})
        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        """Handle POST requests."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"

        if self.path == "/config":
            try:
                data = json.loads(body)
                if "manual_key" in data:
                    _config["manual_key"] = data["manual_key"] or None
                if "browser" in data:
                    _config["browser"] = data["browser"]
                # Invalidate cache on config change
                _config["cache"] = None
                self._send_json({"status": "ok"})
            except json.JSONDecodeError:
                self._send_json({"error": "Invalid JSON"}, 400)
        elif self.path == "/refresh":
            _config["cache"] = None
            result = fetch_usage(_config["manual_key"], _config["browser"])
            _config["cache"] = result
            _config["cache_time"] = datetime.now(timezone.utc)
            self._send_json(result)
        else:
            self._send_json({"error": "Not found"}, 404)


def run_server(port: int = DEFAULT_PORT):
    """Run the HTTP server."""
    server = HTTPServer((SERVER_HOST, port), UsageHTTPHandler)
    print(f"Claude Usage server running on http://{SERVER_HOST}:{port}")
    print("Press Ctrl+C to stop")

    # Handle SIGTERM gracefully
    def handle_sigterm(signum, frame):
        print("\nShutting down...")
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


def run_once(manual_key: Optional[str] = None, browser: str = "auto"):
    """Run once and output JSON."""
    result = fetch_usage(manual_key, browser)
    print(json.dumps(result))


# ============================================================
# Main
# ============================================================


def main():
    parser = argparse.ArgumentParser(description="Claude Code Usage Backend")
    parser.add_argument(
        "--server",
        action="store_true",
        help="Run as HTTP server",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run once and output JSON",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Port for HTTP server (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--manual-key",
        type=str,
        default=None,
        help="Manual sessionKey cookie value",
    )
    parser.add_argument(
        "--browser",
        type=str,
        choices=["chrome", "firefox", "auto"],
        default="auto",
        help="Browser to extract cookies from",
    )

    args = parser.parse_args()

    if args.server:
        run_server(args.port)
    else:
        run_once(args.manual_key, args.browser)


if __name__ == "__main__":
    main()
