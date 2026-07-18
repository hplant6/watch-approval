# Phase 0 — Apple foundation & first on-device build

Goal of this phase: prove the full pipe works —
**`curl` a fake request → relay → APNs → notification on your iPhone (mirrored to your
wrist) → tap Approve → relay logs the decision.** No Cathode changes yet.

Everything below runs on your **Mac** except where noted. You need a **paid Apple
Developer account**, **Xcode 16+**, and **XcodeGen** (`brew install xcodegen`).

---

## 1. Apple Developer portal — App ID + APNs key

Do this once at <https://developer.apple.com/account>.

### 1a. Register the App ID
1. **Certificates, Identifiers & Profiles → Identifiers → +**
2. Type: **App IDs → App**.
3. Description: `Cathode Approvals`. Bundle ID: **Explicit** → `com.cathode.approvals`
   (must match `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`).
4. Under **Capabilities**, check **Push Notifications**. Register.

### 1b. Create the APNs Auth Key (.p8)
1. **Keys → +**
2. Name: `Cathode Approvals APNs`. Check **Apple Push Notifications service (APNs)**. Continue → Register.
3. **Download the `.p8` file now** — you only get one download. Note the **Key ID** (10 chars).
4. Grab your **Team ID** (top-right of the portal, 10 chars).

Keep the `.p8` somewhere local and **out of git** (the repo's `.gitignore` should
already exclude it — see the note at the bottom). One key works for every app under
your team, sandbox and production.

---

## 2. Build & run the iPhone app

On the Mac, from `watch-approval/app`:

```bash
xcodegen generate          # reads project.yml → CathodeApprovals.xcodeproj
open CathodeApprovals.xcodeproj
```

In Xcode:
1. Select the **CathodeApprovals** target → **Signing & Capabilities**.
2. Set your **Team** (this fills the empty `DEVELOPMENT_TEAM`). "Automatically manage
   signing" is fine.
3. Confirm **Push Notifications** appears as a capability (it comes from the entitlements
   file; add it with **+ Capability** if it's missing).
4. Plug in your iPhone, select it as the run destination, and **Run** (⌘R).
5. On the phone, **allow notifications** when prompted.

### Capture the device token
Watch the Xcode console — on launch the app prints:

```
[Approvals] Device token: <64 hex chars>
```

It also POSTs this token to the relay's `/api/register` automatically (once the relay is
running and the app's **Server** URL points at it). You can also see/copy the token on the
app's main screen under **APNs Device Token**.

---

## 3. Configure & run the relay

On the machine where the relay runs (your Cathode desktop; WSL is fine):

```bash
cd watch-approval/server
uv sync                       # picks up the new aioapns dependency

export WATCH_APPROVAL_APNS_KEY=/absolute/path/AuthKey_XXXXXXXXXX.p8
export WATCH_APPROVAL_APNS_KEY_ID=XXXXXXXXXX
export WATCH_APPROVAL_APNS_TEAM_ID=XXXXXXXXXX
export WATCH_APPROVAL_APNS_TOPIC=com.cathode.approvals
# Dev build → APNs sandbox. This is the default; shown here so it's explicit.
export WATCH_APPROVAL_APNS_SANDBOX=1

uv run python main.py         # listens on 0.0.0.0:8420
```

In the **app**, set **Server** to the relay machine's LAN address, e.g.
`http://192.168.1.50:8420` (find it with `ipconfig`/`ip addr`). Tap **Test Connection** —
it should go green. Tap **Re-register for Notifications** so the token reaches the relay
(check the server log for `Device registered: …`).

> **LAN note (Phase 0):** the phone and the relay machine must be on the same network for
> now. Reaching it from anywhere comes in Phase 2 (Tailscale).

---

## 4. End-to-end test

From any machine that can reach the relay:

```bash
curl -s -X POST http://<relay-ip>:8420/api/request \
  -H 'Content-Type: application/json' \
  -d '{"tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}'
# → {"request_id":"abcd1234","status":"pending"}
```

You should get a notification on your iPhone that reads **"Claude Code Approval — Run: rm
-rf build/"** with **✓ Approve / ✗ Deny** — and it should mirror to your Apple Watch when
the phone is locked. Tap **Approve** on either device, then confirm the relay saw it:

```bash
curl -s http://<relay-ip>:8420/api/request/abcd1234
# → {"request_id":"abcd1234","status":"approved","decision":"approved"}
```

If that round-trips, **Phase 0 is done** and we can wire it into Cathode (Phase 1).

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No notification arrives | Build is dev-signed → needs **APNs sandbox**. Ensure `WATCH_APPROVAL_APNS_SANDBOX=1` (default). A production/TestFlight build needs `=0` **and** `aps-environment: production`. |
| `BadDeviceToken` in server log | Sandbox/production mismatch (as above), or the token is from a different build/bundle id. |
| `TopicDisallowed` / `403` | `WATCH_APPROVAL_APNS_TOPIC` must equal the bundle id `com.cathode.approvals`. |
| Push works, but Approve does nothing | The phone can't reach the relay to POST back — check the **Server** URL and that you're on the same LAN. |
| Notification shows on phone but never on watch | Apple only mirrors alerts to the watch when the phone is **locked / not in use**. Lock the phone and re-send. |
| `aioapns not installed` in log | Run `uv sync` in `server/` (the dep was added to `pyproject.toml`). |

## Keep the key out of git
The APNs `.p8` and any exported secrets must never be committed. Confirm `.gitignore`
excludes `*.p8` (and your key's path) before your first commit of this app.
