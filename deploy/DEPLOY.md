# Deploy the Watch Approval relay on a Raspberry Pi / Linux box

An always-on relay both your Windows and Mac Cathode point at, and your phone registers
with once. LAN-only to start; add Tailscale later for away-from-home (last section).

## 0. Reserve a static LAN IP
Everything points at this box, so give it a fixed address. In your router's DHCP
settings, reserve an IP for the Pi (e.g. **`192.168.1.50`**). We'll call it `<PI_IP>`.

## 1. Get the code + your key onto the Pi
```bash
git clone https://github.com/hplant6/watch-approval.git
cd watch-approval
# Copy your APNs key to deploy/AuthKey.p8 (scp/USB/cloud). It's gitignored.
cp /path/to/AuthKey_7Z385599QY.p8 deploy/AuthKey.p8
```

## 2. Configure
```bash
cd deploy
cp .env.example .env      # Key ID / Team / Topic are pre-filled; set a SECRET if you like
```

## 3a. Run with Docker (recommended)
Needs Docker + the compose plugin, and a **64-bit** Pi OS (so `cryptography`/`aioapns`
install from wheels — no compiler).
```bash
docker compose up -d --build
docker compose logs -f          # watch startup
```
It restarts automatically on boot and crash. Device tokens persist in a named volume.

## 3b. Or run natively with systemd
```bash
cd ../server && uv sync
# create relay.env with the APNs vars (see deploy/.env.example) + an absolute
# WATCH_APPROVAL_APNS_KEY=/home/pi/watch-approval/deploy/AuthKey.p8
sudo cp ../deploy/watch-approval.service /etc/systemd/system/
sudo systemctl enable --now watch-approval
journalctl -u watch-approval -f
```

## 4. Verify
```bash
curl http://localhost:8420/health          # on the Pi
curl http://<PI_IP>:8420/health            # from your desktop/Mac → same JSON
```

## 5. Point everything at the Pi
- **Cathode (both the Windows desktop and the Mac):** Settings → Watch Approval →
  URL `http://<PI_IP>:8420` (+ the same secret if you set one) → Enable → Test → Save.
  No more per-machine relay; both just use the Pi.
- **Phone (Cathode Approvals app):** Server `http://<PI_IP>:8420` → **Re-register once**.
  Tokens are persisted now, so you won't need to do this again — and switching between
  the desktop and the Mac requires **no phone changes at all.**

## 6. Test
Have an agent run a risky command on either machine → notification on your wrist →
expand it → **Approve** → the agent proceeds.

---

## Later: away-from-home (Tailscale)
LAN-only means the phone's Approve/Deny only reaches the Pi on home Wi-Fi. To use it
anywhere, add [Tailscale](https://tailscale.com) to the **Pi**, **both computers**, and
the **iPhone** (its iOS app), then point Cathode + the phone at the Pi's tailnet address
(e.g. `http://100.x.y.z:8420` or its MagicDNS name) instead of `<PI_IP>`. APNs already
delivers the push anywhere; Tailscale just gets the *decision* back to the Pi from
cellular. Set `WATCH_APPROVAL_SECRET` before exposing it beyond your LAN.
