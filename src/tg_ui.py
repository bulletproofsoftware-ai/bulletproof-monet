"""Telegram inline-keyboard builders and helpers for Monet (Phase 2 UX)."""
import json
import os
import urllib.request

BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
API = f"https://api.telegram.org/bot{BOT_TOKEN}"


def inline_keyboard(rows):
    """rows: list of list of (text, callback_data). Returns Telegram reply_markup dict."""
    return {"inline_keyboard": [
        [{"text": t, "callback_data": cb} for (t, cb) in row] for row in rows
    ]}


def menu_keyboard():
    """The /menu quick-action keyboard."""
    return inline_keyboard([
        [("🔒 Security brief", "act:cyber"), ("🌦 Weather", "act:weather")],
        [("📋 Skills", "act:skills"), ("🧠 Memory stats", "act:memstats")],
        [("❌ Cancel current job", "act:cancel")],
    ])


def approve_deny_keyboard(token):
    """Approve/Deny buttons carrying an action token."""
    return inline_keyboard([[("✅ Approve", f"approve:{token}"), ("🚫 Deny", f"deny:{token}")]])


def _post(method, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{API}/{method}", data=data,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"ok": False, "error": str(e)}


def send_message(chat_id, text, reply_markup=None):
    payload = {"chat_id": chat_id, "text": text}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return _post("sendMessage", payload)


def edit_message(chat_id, message_id, text, reply_markup=None):
    payload = {"chat_id": chat_id, "message_id": message_id, "text": text}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return _post("editMessageText", payload)


def answer_callback(callback_query_id, text=None):
    payload = {"callback_query_id": callback_query_id}
    if text:
        payload["text"] = text
    return _post("answerCallbackQuery", payload)


def send_force_reply(chat_id, prompt_text):
    """Send a message that opens Telegram's reply box (force_reply) with a placeholder."""
    return _post("sendMessage", {
        "chat_id": chat_id,
        "text": prompt_text,
        "reply_markup": {"force_reply": True, "input_field_placeholder": "type the value(s) here"},
    })
