# Handoff → Hermes: Apple setup for Cathode Approvals (Phase 0)

You (Hermes) are picking up the **Apple side** of the Watch/phone approval companion.
Everything code-side is already built and committed. Your job is to get the iPhone app
signed, installed on a real device, and receiving real APNs pushes — then prove the full
round-trip.

## Context (what already exists)
- Repo: `watch-approval/` (its own git repo, branch `master`; latest commit `250193b`).
- iOS app source: `app/CathodeApprovals/` — an XcodeGen project (`app/project.yml`).
- Relay server: `server/main.py` (FastAPI, port 8420). APNs sending is implemented and
  already handles the sandbox correctly.
- Full detailed walkthrough (follow it, don't reinvent): **`app/SETUP.md`**.

## Fixed facts — use these exact values
| Thing | Value |
|---|---|
| Bundle ID | `com.cathode.approvals` |
| Apple Team ID | `R5T9D4ATJQ` (already set in `project.yml`) |
| APNs topic | `com.cathode.approvals` (same as bundle id) |
| Relay port | `8420` |
| APNs env | **sandbox** for the dev build (server default; don't change) |

## Prerequisites you must be running on
- A **Mac with Xcode 16+**, `xcodegen` (`brew install xcodegen`), and a **physical iPhone**
  connected and trusted. (A simulator cannot receive real APNs pushes — must be a device.)
- The Mac and the phone on the **same Wi-Fi** as the machine that will run the relay.

---

## Steps that NEED the human (Henry) — do not attempt to automate
Apple ID login + 2FA and the one-time `.p8` download can't be scripted. Ask Henry to do
these at <https://developer.apple.com/account>, or pause and request them:

1. **Register App ID** `com.cathode.approvals` with the **Push Notifications** capability.
2. **Create an APNs Auth Key (.p8)** → download it once → record the **Key ID** (10 chars).
   Team ID is already known (`R5T9D4ATJQ`).
3. Place the `.p8` somewhere **outside the repo** (or a gitignored path). It must never be
   committed — `.gitignore` already blocks `*.p8`, but keep it out of the tree anyway.

Full detail: `app/SETUP.md` §1.

---

## Steps you (Hermes) can do
### 1. Generate + build the app
```bash
cd app
xcodegen generate
# Build & install to the connected device (automatic signing, team already set):
xcodebuild -project CathodeApprovals.xcodeproj -scheme CathodeApprovals \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates
```
If automatic provisioning needs an Xcode-logged-in Apple account, open the project
(`open CathodeApprovals.xcodeproj`) and have Henry confirm the team once; then re-run.
On the phone: **allow notifications** when prompted.

### 2. Run the relay with the APNs credentials
```bash
cd ../server
uv sync
export WATCH_APPROVAL_APNS_KEY=/abs/path/AuthKey_XXXXXXXXXX.p8   # from the human step
export WATCH_APPROVAL_APNS_KEY_ID=XXXXXXXXXX                     # the Key ID
export WATCH_APPROVAL_APNS_TEAM_ID=R5T9D4ATJQ
export WATCH_APPROVAL_APNS_TOPIC=com.cathode.approvals
export WATCH_APPROVAL_APNS_SANDBOX=1                             # dev build → sandbox
uv run python main.py                                           # 0.0.0.0:8420
```

### 3. Point the app at the relay + register
- In the app's **Server** field, enter the relay machine's LAN URL (e.g.
  `http://192.168.1.50:8420`). Tap **Test Connection** → should go green.
- Tap **Re-register for Notifications**. Confirm the server log shows `Device registered: …`.
- Grab the device token from the app screen or the Xcode console
  (`[Approvals] Device token: …`).

### 4. End-to-end acceptance test
```bash
curl -s -X POST http://<relay-ip>:8420/api/request \
  -H 'Content-Type: application/json' \
  -d '{"tool_name":"Bash","tool_input":{"command":"rm -rf build/"}}'
# → {"request_id":"<id>","status":"pending"}
```
Expect a notification "**Claude Code Approval — Run: rm -rf build/**" with **✓ Approve /
✗ Deny** on the iPhone (and mirrored to the Apple Watch when the phone is **locked**).
Tap **Approve**, then:
```bash
curl -s http://<relay-ip>:8420/api/request/<id>   # → status: "approved"
```

## Definition of done
- App installed on the physical iPhone, notifications authorized.
- A `curl`ed request produces a real push, and tapping Approve/Deny on the phone **or the
  watch** flips the relay's status to `approved`/`denied`.

## Report back to Henry
- The **Key ID** used (Team ID is `R5T9D4ATJQ`), and where the `.p8` is stored.
- Confirmation the round-trip worked (paste the two `curl` results).
- Any signing/provisioning snags, and the device token if useful.
- **Do not commit** the `.p8` or any exported secrets.

## Known gotchas (see `app/SETUP.md` troubleshooting table)
- No push → dev build must use the **APNs sandbox** (`WATCH_APPROVAL_APNS_SANDBOX=1`, the default).
- `BadDeviceToken` → sandbox/prod mismatch or token from a different build.
- `TopicDisallowed`/403 → topic must equal `com.cathode.approvals`.
- Push arrives but Approve does nothing → phone can't reach the relay; check the Server URL / same LAN.
- Shows on phone but never the watch → Apple only mirrors to the watch when the phone is **locked/idle**.

## NOT in scope for this handoff
Wiring into Cathode (the `main.js` `requestPermission` seam) and remote reachability
(Tailscale) are Phases 1–2, handled separately. Phase 0 is just: real push → real
approve/deny round-trip.
