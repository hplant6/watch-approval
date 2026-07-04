# Watch Approval — Remote Approve/Deny for Claude Code

Approve or deny Claude Code tool calls from your Apple Watch when you're
away from your desktop.

```
┌──────────────┐     POST /api/request     ┌──────────────┐     APNs Push     ┌─────────────┐
│  Claude Code │ ──────────────────────────▶│ Relay Server │ ─────────────────▶│ Apple Watch │
│  (desktop)   │                            │  (Python)    │                   │             │
│              │◀──── GET /api/request/:id ─│              │◀── POST respond ─│             │
└──────────────┘     (poll for decision)    └──────────────┘                   └─────────────┘
```

## Project Structure

```
watch-approval/
├── server/                  # Python relay server (FastAPI)
│   └── main.py
├── hook/                    # Claude Code hook script
│   └── watch-approve.py
├── watch/                   # Apple Watch app (Swift/SwiftUI)
│   ├── project.yml          # XcodeGen spec
│   └── WatchApproval/
│       ├── WatchApprovalApp.swift
│       ├── ContentView.swift
│       ├── ServerClient.swift
│       ├── Info.plist
│       └── WatchApproval.entitlements
├── claude-code-hooks.json   # Drop-in Claude Code hook config
└── README.md
```

## Quick Start

### 1. Start the Relay Server

```bash
cd server
uv run python main.py
# Server runs on http://0.0.0.0:8420
```

Verify:
```bash
curl http://localhost:8420/health
# {"status":"ok","pending_requests":0}
```

### 2. Install the Claude Code Hook

Merge `claude-code-hooks.json` into your `~/.claude/settings.json`:

```bash
# Option A: Copy the hook config directly
cat claude-code-hooks.json >> ~/.claude/settings.json

# Option B: Add to project-level config
cp claude-code-hooks.json .claude/settings.json
```

Or manually add to `~/.claude/settings.json`:
```json
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
```

### 3. Build the Watch App

On your Mac (with Xcode 16+ and XcodeGen installed):

```bash
cd watch

# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open WatchApproval.xcodeproj
```

In Xcode:
1. Set your Development Team in Signing & Capabilities
2. Add the "Push Notifications" capability
3. Build and run on your Apple Watch

### 4. Configure APNs (for push notifications)

Once you have the watch app running:

1. Get your device token from the server logs (the watch sends it on launch)
2. Create an APNs key in your Apple Developer account
3. Set environment variables and restart the server:

```bash
export WATCH_APPROVAL_APNS_KEY=/path/to/AuthKey_XXXXXX.p8
export WATCH_APPROVAL_APNS_KEY_ID=XXXXXX
export WATCH_APPROVAL_APNS_TEAM_ID=XXXXXX
export WATCH_APPROVAL_APNS_TOPIC=com.example.WatchApproval.watchkitapp

cd server && uv run python main.py
```

### 5. (Optional) Secure with a shared secret

```bash
export WATCH_APPROVAL_SECRET="your-random-secret-here"
export WATCH_SECRET="your-random-secret-here"  # for the hook script
```

## How It Works

1. Claude Code is about to run a tool (Bash, Edit, Write, etc.)
2. The `PreToolUse` hook fires and runs `watch-approve.py`
3. The script POSTs the tool details to the relay server
4. The server sends an APNs push notification to your Apple Watch
5. Your watch shows "Claude Code Approval: Run: npm test" with Approve/Deny buttons
6. You tap Approve or Deny on your watch
7. The watch app POSTs your decision back to the server
8. The hook script picks up the response and tells Claude Code to allow or block

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `WATCH_SERVER_URL` | `http://localhost:8420` | Relay server base URL |
| `WATCH_SECRET` | (none) | Shared secret for auth |
| `WATCH_POLL_SECS` | `2` | Polling interval for the hook |
| `WATCH_TIMEOUT` | `290` | Max wait time (seconds) |
| `WATCH_APPROVAL_APNS_KEY` | — | Path to APNs .p8 key |
| `WATCH_APPROVAL_APNS_KEY_ID` | — | APNs key ID |
| `WATCH_APPROVAL_APNS_TEAM_ID` | — | Apple Team ID |
| `WATCH_APPROVAL_APNS_TOPIC` | — | Watch app bundle ID |

## Testing Without a Watch

Test the server and hook without an actual watch:

```bash
# Start server
cd server && uv run python main.py &

# Submit a request (simulating Claude Code)
curl -s -X POST http://localhost:8420/api/request \
  -H 'Content-Type: application/json' \
  -d '{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
# → {"request_id":"abc123","status":"pending"}

# Approve it (simulating the watch)
curl -s -X POST http://localhost:8420/api/respond/abc123 \
  -H 'Content-Type: application/json' \
  -d '{"decision":"approve"}'

# Test the hook script
echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | \
  python3 hook/watch-approve.py
# → exits 0 (approved, no output = tool runs)
```

## API Reference

### POST /api/request
Claude Code submits a tool approval request.

```json
{"tool_name": "Bash", "tool_input": {"command": "npm test"}}
→ {"request_id": "abc123", "status": "pending"}
```

### GET /api/request/:id
Claude Code hook polls for the decision.

```json
→ {"request_id": "abc123", "status": "approved", "decision": "approved"}
```

### POST /api/respond/:id
Apple Watch sends its decision.

```json
{"decision": "approve"}
→ {"status": "ok", "request_id": "abc123", "decision": "approved"}
```

### POST /api/register
Apple Watch registers for push notifications.

```json
{"device_token": "abc123..."}
→ {"status": "registered", "device_count": 1}
```

## Running on a VPS

To use this when you're outside your home network:

1. Deploy the relay server to a cheap VPS ($5/mo)
2. Set `WATCH_SERVER_URL` to your VPS address
3. Use a strong `WATCH_APPROVAL_SECRET`
4. The watch app already uses the same `WATCH_SERVER_URL`

The hook script will talk to the VPS, which pushes to your watch over the
internet via APNs. No port forwarding needed on your home network.

## Security Notes

- Always set `WATCH_APPROVAL_SECRET` when exposing the server to a network
- The hook script runs with your user's permissions — anyone who can run
  commands on your desktop can approve tool calls
- APNs push notifications are end-to-end encrypted by Apple
- Consider only requiring approval for specific tool types by setting the
  `matcher` in your Claude Code hook config (e.g., `"Bash"` only)
