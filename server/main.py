"""
Watch Approval Relay Server

Bridges Claude Code PreToolUse hooks with an Apple Watch app.
Claude Code submits approval requests, the watch responds,
and Claude Code polls for the result.

Endpoints:
  POST /api/request      — Claude Code submits a request
  GET  /api/request/{id} — Claude Code polls for response
  POST /api/respond/{id} — Apple Watch sends decision
  POST /api/register     — Apple Watch registers device token
"""

import os
import uuid
import time
import hmac
import hashlib
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SHARED_SECRET = os.environ.get("WATCH_APPROVAL_SECRET", "change-me-in-production")
REQUEST_TIMEOUT = int(os.environ.get("WATCH_APPROVAL_TIMEOUT", "300"))  # seconds
APNS_KEY_PATH = os.environ.get("WATCH_APPROVAL_APNS_KEY")
APNS_KEY_ID = os.environ.get("WATCH_APPROVAL_APNS_KEY_ID")
APNS_TEAM_ID = os.environ.get("WATCH_APPROVAL_APNS_TEAM_ID")
APNS_TOPIC = os.environ.get("WATCH_APPROVAL_APNS_TOPIC")  # bundle ID (e.g. com.cathode.approvals)
# A build signed with `aps-environment: development` (Xcode run/debug) talks to the
# APNs SANDBOX. Only a TestFlight/App Store build uses production. Default to sandbox
# so on-device dev builds actually receive pushes; set WATCH_APPROVAL_APNS_SANDBOX=0
# once you ship a production build.
APNS_USE_SANDBOX = os.environ.get("WATCH_APPROVAL_APNS_SANDBOX", "1") not in ("0", "false", "False", "")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("watch-approval")

app = FastAPI(title="Watch Approval Relay")

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


@dataclass
class ApprovalRequest:
    id: str
    tool_name: str
    tool_input: dict
    status: str  # "pending" | "approved" | "denied" | "timeout" | "cancelled"
    created_at: float = field(default_factory=time.time)
    respond_by: float = field(default_factory=lambda: time.time() + REQUEST_TIMEOUT)
    summary: str | None = None

    def is_expired(self) -> bool:
        return time.time() > self.respond_by


# In-memory store. Replace with Redis or SQLite for persistence across restarts.
_pending: dict[str, ApprovalRequest] = {}

# Registered device tokens for APNs push
_device_tokens: set[str] = set()

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class RequestSubmit(BaseModel):
    tool_name: str
    tool_input: dict
    # Optional caller-built notification text + tool kind. When Cathode submits a
    # request it knows the best summary (the ACP toolCall title); fall back to the
    # server's own summarizer when absent (e.g. the plain curl test).
    summary: str | None = None
    kind: str | None = None


class RequestResponse(BaseModel):
    request_id: str
    status: str
    decision: str | None = None


class WatchResponse(BaseModel):
    decision: str  # "approve" or "deny"


class DeviceRegistration(BaseModel):
    device_token: str


# ---------------------------------------------------------------------------
# Auth helper
# ---------------------------------------------------------------------------


def verify_auth(authorization: str | None = Header(None)) -> None:
    """Verify the shared secret via Bearer token."""
    if not SHARED_SECRET or SHARED_SECRET == "change-me-in-production":
        return  # Auth disabled in dev mode
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer":
        raise HTTPException(status_code=401, detail="Expected Bearer token")
    if not hmac.compare_digest(token, SHARED_SECRET):
        raise HTTPException(status_code=401, detail="Invalid token")


# ---------------------------------------------------------------------------
# APNs helper (stub — real push happens when credentials are configured)
# ---------------------------------------------------------------------------


async def send_push_notification(request_id: str, tool_name: str, tool_input: dict, summary: str | None = None):
    """Send an APNs push notification to all registered devices."""
    if not _device_tokens:
        log.warning("No registered devices — push notification skipped")
        return
    if not all([APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC]):
        log.warning("APNs not configured — push notification skipped")
        return

    try:
        from aioapns import APNs, NotificationRequest, PushType  # type: ignore[import-untyped]

        # aioapns expects the key *content*, not a file path
        with open(APNS_KEY_PATH) as f:
            key_content = f.read()

        client = APNs(
            key=key_content,
            key_id=APNS_KEY_ID,
            team_id=APNS_TEAM_ID,
            topic=APNS_TOPIC,
            use_sandbox=APNS_USE_SANDBOX,
        )

        # Prefer the caller's summary; fall back to the server's own guesser.
        summary = summary or _summarize_request(tool_name, tool_input)
        payload = {
            "aps": {
                "alert": {
                    "title": "Cathode Approval",
                    "body": summary,
                },
                "category": "APPROVAL_REQUEST",
                "sound": "permission.aiff",
                "badge": 1,
                "mutable-content": 1,
            },
            "request_id": request_id,
            "tool_name": tool_name,
        }

        for token in _device_tokens:
            notification = NotificationRequest(
                device_token=token,
                message=payload,
                push_type=PushType.ALERT,
            )
            await client.send_notification(notification)

        log.info(f"Push sent for request {request_id} to {len(_device_tokens)} device(s)")

    except ImportError:
        log.warning("aioapns not installed — push notification skipped. Install with: uv add aioapns")
    except Exception as e:
        log.error(f"Failed to send push: {e}")


def _summarize_request(tool_name: str, tool_input: dict) -> str:
    """Create a one-line summary of the tool request."""
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        return f"Run: {cmd[:80]}{'...' if len(cmd) > 80 else ''}"
    elif tool_name in ("Edit", "Write"):
        path = tool_input.get("file_path", "unknown")
        return f"Edit: {path}"
    elif tool_name == "WebSearch":
        query = tool_input.get("query", tool_input.get("explanation", ""))
        return f"Search: {query[:80]}"
    else:
        return f"{tool_name}: {str(tool_input)[:80]}"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    return {"status": "ok", "pending_requests": len(_pending)}


@app.post("/api/register")
async def register_device(body: DeviceRegistration, auth=Header(None)):
    """Register a device token for push notifications."""
    verify_auth(auth)
    _device_tokens.add(body.device_token)
    log.info(f"Device registered: {body.device_token[:20]}...")
    return {"status": "registered", "device_count": len(_device_tokens)}


@app.post("/api/request", response_model=RequestResponse)
async def submit_request(body: RequestSubmit, auth=Header(None)):
    """Claude Code submits a new approval request."""
    verify_auth(auth)

    # Clean up expired requests
    expired = [rid for rid, req in _pending.items() if req.is_expired()]
    for rid in expired:
        _pending.pop(rid, None)

    request_id = str(uuid.uuid4())[:8]
    req = ApprovalRequest(
        id=request_id,
        tool_name=body.tool_name,
        tool_input=body.tool_input,
        status="pending",
    )
    _pending[request_id] = req

    log.info(f"New request {request_id}: {body.tool_name}")

    req.summary = body.summary

    # Send push notification asynchronously
    await send_push_notification(request_id, body.tool_name, body.tool_input, body.summary)

    return RequestResponse(request_id=request_id, status="pending")


@app.get("/api/request/{request_id}", response_model=RequestResponse)
async def poll_request(request_id: str, auth=Header(None)):
    """Claude Code polls for the watch's decision."""
    verify_auth(auth)

    req = _pending.get(request_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Request not found")

    if req.is_expired() and req.status == "pending":
        req.status = "timeout"
        log.info(f"Request {request_id} timed out")

    return RequestResponse(
        request_id=req.id,
        status=req.status,
        decision=req.status if req.status != "pending" else None,
    )


@app.post("/api/respond/{request_id}")
async def respond(request_id: str, body: WatchResponse):
    """Apple Watch sends its decision."""
    req = _pending.get(request_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Request not found")
    if req.status != "pending":
        raise HTTPException(status_code=409, detail=f"Request already {req.status}")

    if body.decision not in ("approve", "deny"):
        raise HTTPException(status_code=400, detail="Decision must be 'approve' or 'deny'")

    req.status = "approved" if body.decision == "approve" else "denied"
    log.info(f"Request {request_id}: {req.status}")

    return {"status": "ok", "request_id": request_id, "decision": req.status}


@app.post("/api/cancel/{request_id}")
async def cancel(request_id: str, auth=Header(None)):
    """Cathode marks a request handled elsewhere (in-app decision won the race), so a
    late watch tap gets a clean 409 instead of flipping an already-resolved prompt."""
    verify_auth(auth)
    req = _pending.get(request_id)
    if req is None:
        return {"status": "not_found", "request_id": request_id}
    if req.status == "pending":
        req.status = "cancelled"
        log.info(f"Request {request_id} cancelled (decided in-app)")
    return {"status": req.status, "request_id": request_id}


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8420, log_level="info")
