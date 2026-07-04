#!/usr/bin/env python3
"""
Claude Code PreToolUse Hook — Watch Approval

Reads the tool call from stdin, submits it to the Watch Approval relay server,
polls for the user's response from their Apple Watch, and returns the decision.

Usage in ~/.claude/settings.json:

{
  "hooks": {
    "PreToolUse": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "/path/to/watch-approval/hook/watch-approve.py",
        "timeout": 360000
      }]
    }]
  }
}

Environment variables:
  WATCH_SERVER_URL  — Base URL of the relay server (default: http://localhost:8420)
  WATCH_SECRET      — Shared secret for auth (default: none)
  WATCH_POLL_SECS   — Polling interval in seconds (default: 2)
  WATCH_TIMEOUT     — Total wait time in seconds (default: 290, just under hook's 300s default)
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

SERVER = os.environ.get("WATCH_SERVER_URL", "http://localhost:8420")
SECRET = os.environ.get("WATCH_SECRET", "")
POLL_INTERVAL = float(os.environ.get("WATCH_POLL_SECS", "2"))
MAX_WAIT = float(os.environ.get("WATCH_TIMEOUT", "290"))


def _request(method: str, path: str, body: dict | None = None) -> dict:
    """Make an HTTP request to the relay server."""
    url = f"{SERVER}{path}"
    data = json.dumps(body).encode() if body else None
    headers = {"Content-Type": "application/json"}
    if SECRET:
        headers["Authorization"] = f"Bearer {SECRET}"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode(errors="replace")
        print(f"Server error ({e.code}): {body_text}", file=sys.stderr)
        return {"error": str(e)}
    except urllib.error.URLError as e:
        print(f"Connection error: {e.reason}", file=sys.stderr)
        return {"error": str(e.reason)}


def _summarize(tool_name: str, tool_input: dict) -> str:
    """One-line summary for display."""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")[:100]
        return f"Bash: {cmd}"
    elif tool_name in ("Edit", "Write"):
        return f"{tool_name}: {tool_input.get('file_path', '?')}"
    elif tool_name == "WebSearch":
        return f"Search: {tool_input.get('query', '?')[:100]}"
    else:
        raw = str(tool_input)[:100]
        return f"{tool_name}: {raw}"


def main():
    # Read tool input from stdin (Claude Code passes JSON)
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        # Not JSON? Exit 0 to let the tool run normally
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})

    # Skip if nothing to check
    if not tool_name:
        sys.exit(0)

    summary = _summarize(tool_name, tool_input)

    # 1. Submit the request to the relay server
    print(f"[watch-approve] Submitting: {summary}", file=sys.stderr)
    result = _request("POST", "/api/request", {
        "tool_name": tool_name,
        "tool_input": tool_input,
    })

    if "error" in result:
        # Server unreachable — don't block the user's work
        print(f"[watch-approve] Server unreachable, allowing by default", file=sys.stderr)
        sys.exit(0)

    request_id = result.get("request_id")
    if not request_id:
        print(f"[watch-approve] No request_id in response, allowing", file=sys.stderr)
        sys.exit(0)

    print(f"[watch-approve] Waiting for watch response (request {request_id})...", file=sys.stderr)

    # 2. Poll for the response
    deadline = time.time() + MAX_WAIT
    while time.time() < deadline:
        poll_result = _request("GET", f"/api/request/{request_id}")
        status = poll_result.get("status", "pending")

        if status == "approved":
            print(f"[watch-approve] APPROVED by watch", file=sys.stderr)
            sys.exit(0)  # Exit 0 = allow the tool to run

        if status == "denied":
            reason = f"Denied by user on Apple Watch: {summary}"
            print(f"[watch-approve] DENIED by watch", file=sys.stderr)
            # Return a PreToolUse deny decision
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }))
            sys.exit(0)

        if status == "timeout":
            print(f"[watch-approve] Request timed out, denying", file=sys.stderr)
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": f"Approval request timed out after {MAX_WAIT}s: {summary}",
                }
            }))
            sys.exit(0)

        # Still pending — wait and retry
        time.sleep(POLL_INTERVAL)

    # Absolute timeout (shouldn't normally reach here since server handles timeout)
    print(f"[watch-approve] Client-side timeout, denying", file=sys.stderr)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"No response from watch within {MAX_WAIT}s: {summary}",
        }
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
