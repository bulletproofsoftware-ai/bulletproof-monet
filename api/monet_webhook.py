#!/usr/bin/env python3
"""Monet Telegram webhook receiver (Phase 2 transport + UX).

Dedicated FastAPI service receiving the Telegram webhook directly. Handles:
- message: text -> Phase 1 dispatch pipeline (inline or promoted); /menu -> inline keyboard
- callback_query: inline-button presses -> routed actions
- message_reaction: emoji reactions -> stored as feedback (learning signal)
Responds 200 fast.
"""
import glob
import os
import shutil
import subprocess
import sys
from fastapi import FastAPI, Request, BackgroundTasks
import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.realpath(__file__)), "..", "lib"))
import monet_paths
from safe_paths import UnsafeIdentifier, safe_join

sys.path.insert(0, monet_paths.API_DIR)
import tg_ui

AUTHORIZED = os.environ.get("MONET_AUTHORIZED_CHAT", "")
if not AUTHORIZED or AUTHORIZED == "YOUR_CHAT_ID":
    # Fail closed, but say so. An unset allow-list rejects every update, and
    # silent rejection is indistinguishable from a broken webhook registration
    # -- the deployer sees Telegram delivering nothing and has no clue why.
    print(
        "monet-webhook: MONET_AUTHORIZED_CHAT is not set; every update will be "
        "rejected. Set it to your numeric Telegram chat id in .env.",
        file=sys.stderr,
        flush=True,
    )
OWNER_NAME = os.environ.get("MONET_OWNER_NAME", "the operator")
DISPATCH = monet_paths.path("monet-dispatch.sh")  # chat-only (kept for reference)
ROUTER = monet_paths.path("bridges/monet-tg.sh")  # full command router (all /commands + chat)
TG_SEND = monet_paths.path("tg-send.sh")
LOG = os.path.join(monet_paths.LOG_DIR, "webhook.log")
PENDING_DIR = monet_paths.PENDING_DIR  # approve/deny action store

# Commands that need arguments -> usage prompt shown via force_reply when sent bare.
# Every key MUST be on the command allowlist (see scripts/tg-register-commands.sh
# and the /help handler in bridges/monet-tg.sh). A key with no handler behind it
# force-replies into a dead end.
USAGE = {
    "/remind":   "⏰ Reminder — reply with:  <when> <what>\ne.g.  30m call dentist",
    "/ss":       "📸 Screenshot — reply with a URL:\ne.g.  https://example.com",
    "/clip":     "📎 Clip — reply with:  <tag> <content>\ne.g.  ideas ship the docs rewrite",
    "/find":     "🔎 Find — reply with a search query for your saved clips.",
    "/search":   "🔎 Search — reply with a query to search your local data.",
    "/mark":     "🔖 Bookmark — reply with a label for this moment.",
    "/recall":   "🔖 Recall — reply with a bookmark label or keyword.",
}

app = FastAPI(title="Monet Webhook", docs_url=None, redoc_url=None)


def _log(msg):
    try:
        with open(LOG, "a") as fh:
            fh.write(msg + "\n")
    except Exception:
        pass


@app.get("/healthz")
def healthz():
    return {"ok": True, "service": "monet-webhook"}


# Above this rendered height, deliver as a document instead of a photo so
# Telegram does not recompress a full-page screenshot into an unreadable strip.
TALL_PX = 2500

# Public /ss URLs map to this local dir; read dimensions off disk rather than
# re-fetching over the network.
_URL_DIRS = (
    ("/ss/", "/var/www/screenshots/"),
)


def _png_height(url):
    """Return PNG pixel height for a local-backed public URL, else None."""
    try:
        import struct
        path = None
        for prefix, base in _URL_DIRS:
            if prefix in url:
                path = base + url.rsplit("/", 1)[-1]
                break
        if not path or not os.path.isfile(path):
            return None
        with open(path, "rb") as fh:
            head = fh.read(24)
        if head[:8] != b"\x89PNG\r\n\x1a\n":
            return None
        return struct.unpack(">II", head[16:24])[1]
    except Exception:
        return None


def _run_dispatch(chat_id: str, text: str):
    import traceback
    try:
        # Route through monet-tg.sh (full command router). Args: MSG, TG_FILE_ID(empty), CHAT_ID.
        # It handles all /commands AND falls through to async chat dispatch. Command handlers
        # print their result to stdout; we deliver that. Chat path may deliver out-of-band.
        out = subprocess.run([ROUTER, text, "", chat_id],
                             capture_output=True, text=True, timeout=150)
        _log(f"_run_router chat={chat_id} rc={out.returncode} out_len={len(out.stdout or '')} err={(out.stderr or '')[:200]}")
        result = (out.stdout or "").strip()
        if result:
            import re as _re
            m = _re.search(r"\[IMG\](.*?)\[/IMG\]", result)
            if m:
                # An image marker: upload as a Telegram PHOTO, not raw text.
                # Pass the PUBLIC URL to sendPhoto (JSON method needs URL/file_id, not a local path).
                img_ref = m.group(1).strip()
                caption = _re.sub(r"\[IMG\].*?\[/IMG\]", "", result).strip()
                # Telegram recompresses sendPhoto: a tall full-page screenshot
                # comes back ~391px wide and unreadable. Route tall images to
                # sendDocument, which preserves the original resolution.
                h = _png_height(img_ref)
                if h and h > TALL_PX:
                    resp = tg_ui.send_document(chat_id, img_ref, caption)
                    _log(f"delivered DOCUMENT chat={chat_id} url={img_ref} h={h} ok={resp.get('ok') if isinstance(resp, dict) else resp}")
                else:
                    r = subprocess.run([TG_SEND, chat_id, "--photo", img_ref],
                                       input=caption, text=True, capture_output=True, timeout=60)
                    _log(f"delivered PHOTO chat={chat_id} url={img_ref} h={h} tg_rc={r.returncode} out={(r.stdout or '')[:120]}")
            else:
                subprocess.run([TG_SEND, chat_id], input=result, text=True, timeout=30)
    except Exception as e:
        _log(f"_run_dispatch ERROR chat={chat_id}: {type(e).__name__}: {e}\n{traceback.format_exc()}")


# --- callback_query action handlers (inline buttons) ---
ACTION_PROMPTS = {
    "cyber": "Give me today's cybersecurity intel brief.",
    "weather": "What's the weather right now?",
    "skills": "/skills",
    "memstats": "Show my memory stats.",
}


def _handle_callback(cb):
    data = cb.get("data", "")
    chat_id = str((cb.get("message") or {}).get("chat", {}).get("id", ""))
    cbid = cb.get("id", "")
    if not chat_id or chat_id != AUTHORIZED:
        tg_ui.answer_callback(cbid, "unauthorized")
        return
    if data == "act:cancel":
        # Cancel the most recently modified queued job. Done in Python rather than
        # via a shell so no path is ever interpolated into a command string.
        jobs = sorted(glob.glob(os.path.join(monet_paths.QUEUE_DIR, "q*")),
                      key=os.path.getmtime, reverse=True)
        if jobs:
            shutil.rmtree(jobs[0], ignore_errors=True)
        tg_ui.answer_callback(cbid, "Cancelled current job")
        tg_ui.send_message(chat_id, "🚫 Cancelled the current background job.")
        return
    if data.startswith("act:"):
        key = data.split(":", 1)[1]
        prompt = ACTION_PROMPTS.get(key)
        tg_ui.answer_callback(cbid, f"Running: {key}")
        if prompt:
            _run_dispatch(chat_id, prompt)
        return
    if data.startswith("approve:") or data.startswith("deny:"):
        decision, token = data.split(":", 1)
        import os as _os
        # The token comes from a Telegram callback payload. Joining it to
        # PENDING_DIR directly allowed "../.." to escape the directory — and
        # this handler reads the file and then deletes it, so a traversal was
        # an arbitrary-delete primitive, not just a read.
        try:
            path = str(safe_join(PENDING_DIR, token))
        except UnsafeIdentifier:
            print(
                f"monet-webhook: rejected approval token with unsafe path: {token!r}",
                file=sys.stderr,
            )
            tg_ui.answer_callback(cbid, "This request expired.")
            return
        if not _os.path.isfile(path):
            tg_ui.answer_callback(cbid, "This request expired.")
            return
        with open(path) as fh:
            pending_prompt = fh.read()
        _os.remove(path)
        if decision == "approve":
            tg_ui.answer_callback(cbid, "Approved ✅")
            tg_ui.send_message(chat_id, "✅ Approved — running it now.")
            _run_dispatch(chat_id, pending_prompt)
        else:
            tg_ui.answer_callback(cbid, "Denied 🚫")
            tg_ui.send_message(chat_id, "🚫 Denied — I won't run it.")
        return
    tg_ui.answer_callback(cbid, "ok")


def _handle_reaction(mr):
    """Store a reaction as a lightweight feedback signal."""
    chat_id = str((mr.get("chat") or {}).get("id", ""))
    if chat_id != AUTHORIZED:
        return
    new = mr.get("new_reaction", [])
    emojis = [r.get("emoji", "") for r in new if r.get("type") == "emoji"]
    mid = mr.get("message_id", "")
    _log(f"REACTION chat={chat_id} msg={mid} emojis={emojis}")
    # positive reactions -> feedback note in memory (non-blocking, best-effort)
    if emojis:
        note = f"[reaction feedback] {OWNER_NAME} reacted {''.join(emojis)} to Monet message {mid}"
        try:
            subprocess.Popen(["python3", monet_paths.path("tg-memory.py"), "store", chat_id,
                              note, "user reaction feedback"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


@app.post("/webhook/monet-tg-inbound")
async def inbound(request: Request, bg: BackgroundTasks):
    try:
        update = await request.json()
    except Exception:
        return {"ok": True}
    update = update or {}

    # 1. callback_query (inline button press)
    if "callback_query" in update:
        bg.add_task(_handle_callback, update["callback_query"])
        return {"ok": True}

    # 2. message_reaction (emoji reaction)
    if "message_reaction" in update:
        bg.add_task(_handle_reaction, update["message_reaction"])
        return {"ok": True}

    # 3. message (text)
    msg = update.get("message") or {}
    chat = str((msg.get("chat") or {}).get("id", ""))
    text = msg.get("text") or ""
    if chat and chat == AUTHORIZED and text:
        stripped = text.strip()
        if stripped == "/menu":
            tg_ui.send_message(chat, "What would you like?", tg_ui.menu_keyboard())
        elif stripped in USAGE:
            # A command that needs args was sent bare -> prompt via force_reply.
            tg_ui.send_force_reply(chat, USAGE[stripped] + f"\n\n(replying will run {stripped} with your input)")
            # stash which command this reply should complete
            import os as _os
            _os.makedirs(PENDING_DIR, exist_ok=True)
            with open(_os.path.join(PENDING_DIR, f"reply_{chat}"), "w") as fh:
                fh.write(stripped)
        else:
            # If this is a reply to a force_reply prompt, prepend the pending command.
            import os as _os
            rp = _os.path.join(PENDING_DIR, f"reply_{chat}")
            reply_to = (msg.get("reply_to_message") or {})
            if _os.path.isfile(rp) and reply_to:
                with open(rp) as fh:
                    pending_cmd = fh.read().strip()
                _os.remove(rp)
                text = f"{pending_cmd} {stripped}"
            bg.add_task(_run_dispatch, chat, text)
    return {"ok": True}
