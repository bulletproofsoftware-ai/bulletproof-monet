"""Approve/deny action-token tests for the inline-button callback path."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from conftest import TEST_CHAT_ID  # noqa: E402

import pytest  # noqa: E402


@pytest.fixture
def hook(monkeypatch, tmp_path):
    """Stubbed webhook client plus captured dispatch/callback/message traffic.

    Returns a namespace with .client, .disp, .ans, .sent and .mk(token, prompt),
    which writes an action token into the fixture's temporary PENDING_DIR.
    """
    import monet_webhook
    disp, ans, sent = [], [], []
    monkeypatch.setattr(monet_webhook, "_run_dispatch", lambda ch, t: disp.append((ch, t)))
    monkeypatch.setattr(monet_webhook.tg_ui, "answer_callback",
                        lambda i, text=None: ans.append(text) or {"ok": True})
    monkeypatch.setattr(monet_webhook.tg_ui, "send_message",
                        lambda ch, t, rm=None: sent.append(t) or {"ok": True})
    pending = tmp_path / "pending"
    pending.mkdir()
    monkeypatch.setattr(monet_webhook, "PENDING_DIR", str(pending))

    from fastapi.testclient import TestClient

    class Hook:
        client = TestClient(monet_webhook.app)
        pending_dir = str(pending)

        @staticmethod
        def mk(token, prompt):
            with open(os.path.join(str(pending), token), "w") as fh:
                fh.write(prompt)

    h = Hook()
    h.disp, h.ans, h.sent = disp, ans, sent
    return h


def test_approve_executes(hook):
    hook.mk("tokA", "do the thing")
    hook.client.post("/webhook/monet-tg-inbound", json={
        "callback_query": {"id": "1", "data": "approve:tokA",
                           "message": {"chat": {"id": TEST_CHAT_ID}}}})
    assert hook.disp == [(TEST_CHAT_ID, "do the thing")], \
        f"approve should dispatch, got {hook.disp}"
    assert not os.path.exists(os.path.join(hook.pending_dir, "tokA")), \
        "token should be consumed"


def test_deny_cancels(hook):
    hook.mk("tokD", "dangerous thing")
    hook.client.post("/webhook/monet-tg-inbound", json={
        "callback_query": {"id": "2", "data": "deny:tokD",
                           "message": {"chat": {"id": TEST_CHAT_ID}}}})
    assert hook.disp == [], f"deny must NOT dispatch, got {hook.disp}"
    assert not os.path.exists(os.path.join(hook.pending_dir, "tokD")), "token consumed"


def test_expired_token(hook):
    hook.client.post("/webhook/monet-tg-inbound", json={
        "callback_query": {"id": "3", "data": "approve:nope",
                           "message": {"chat": {"id": TEST_CHAT_ID}}}})
    assert hook.disp == [] and any("expired" in (a or "").lower() for a in hook.ans), \
        f"expired handling, ans={hook.ans}"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
