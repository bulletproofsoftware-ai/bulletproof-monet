"""UX-surface tests: /menu keyboard, callback action routing, reactions."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from conftest import TEST_CHAT_ID, UNAUTHORIZED_CHAT_ID  # noqa: E402

import pytest  # noqa: E402


@pytest.fixture
def hook(monkeypatch, tmp_path):
    """Stubbed webhook client capturing dispatch, callbacks, sends and REACTION logs."""
    import monet_webhook
    disp, cb_ans, reactions, sent = [], [], [], []
    monkeypatch.setattr(monet_webhook, "_run_dispatch", lambda c, t: disp.append((c, t)))
    monkeypatch.setattr(monet_webhook.tg_ui, "answer_callback",
                        lambda cbid, text=None: cb_ans.append((cbid, text)) or {"ok": True})
    monkeypatch.setattr(monet_webhook.tg_ui, "send_message",
                        lambda c, t, rm=None: sent.append((c, t, rm)) or {"ok": True})
    monkeypatch.setattr(monet_webhook, "_log",
                        lambda m: (reactions.append(m) if "REACTION" in m else None))
    pending = tmp_path / "pending"
    pending.mkdir()
    monkeypatch.setattr(monet_webhook, "PENDING_DIR", str(pending))

    from fastapi.testclient import TestClient

    class Hook:
        client = TestClient(monet_webhook.app)

    h = Hook()
    h.disp, h.cb_ans, h.reactions, h.sent = disp, cb_ans, reactions, sent
    return h


def test_menu_shows_keyboard(hook):
    r = hook.client.post("/webhook/monet-tg-inbound",
                         json={"message": {"chat": {"id": TEST_CHAT_ID}, "text": "/menu"}})
    assert r.status_code == 200
    assert len(hook.sent) == 1 and hook.sent[0][2] is not None, "menu should send a keyboard"


def test_callback_routes_action(hook):
    r = hook.client.post("/webhook/monet-tg-inbound", json={
        "callback_query": {"id": "c1", "data": "act:weather",
                           "message": {"chat": {"id": TEST_CHAT_ID}}}})
    assert r.status_code == 200
    assert hook.cb_ans and hook.cb_ans[0][0] == "c1", "should answer callback"
    assert hook.disp and "weather" in hook.disp[0][1].lower(), \
        f"should dispatch weather, got {hook.disp}"


def test_reaction_logged(hook):
    r = hook.client.post("/webhook/monet-tg-inbound", json={
        "message_reaction": {"chat": {"id": TEST_CHAT_ID}, "message_id": 42,
                             "new_reaction": [{"type": "emoji", "emoji": "🔥"}]}})
    assert r.status_code == 200
    assert any("🔥" in x for x in hook.reactions), \
        f"reaction should be logged, got {hook.reactions}"


def test_unauthorized_callback_blocked(hook):
    assert UNAUTHORIZED_CHAT_ID != TEST_CHAT_ID, "negative case must use a different id"
    r = hook.client.post("/webhook/monet-tg-inbound", json={
        "callback_query": {"id": "c2", "data": "act:weather",
                           "message": {"chat": {"id": UNAUTHORIZED_CHAT_ID}}}})
    assert r.status_code == 200 and not hook.disp, "unauthorized callback must not dispatch"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
