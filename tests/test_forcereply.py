"""force_reply tests: bare arg-commands prompt, and the reply completes them."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from conftest import TEST_CHAT_ID  # noqa: E402

import pytest  # noqa: E402


@pytest.fixture
def hook(monkeypatch, tmp_path):
    """Stubbed webhook client capturing force_reply prompts and dispatched text.

    PENDING_DIR is a fresh tmp_path per test, so the old glob-based cleanup of
    stale reply_* markers in the install root is unnecessary.
    """
    import monet_webhook
    fr, disp = [], []
    monkeypatch.setattr(monet_webhook.tg_ui, "send_force_reply",
                        lambda ch, t: fr.append(t) or {"ok": True})
    monkeypatch.setattr(monet_webhook, "_run_dispatch", lambda ch, t: disp.append(t))
    pending = tmp_path / "pending"
    pending.mkdir()
    monkeypatch.setattr(monet_webhook, "PENDING_DIR", str(pending))

    from fastapi.testclient import TestClient

    class Hook:
        client = TestClient(monet_webhook.app)
        pending_dir = str(pending)

    h = Hook()
    h.fr, h.disp = fr, disp
    return h


def test_bare_argcmd_prompts(hook):
    # /remind is on the command allowlist and takes arguments, so a bare send
    # must force_reply with usage rather than dispatch an empty command.
    hook.client.post("/webhook/monet-tg-inbound",
                     json={"message": {"chat": {"id": TEST_CHAT_ID}, "text": "/remind"}})
    assert hook.fr and "reply with" in hook.fr[0].lower(), \
        f"should force_reply with usage, got {hook.fr}"
    assert not hook.disp, "bare arg-cmd must NOT dispatch empty"
    assert os.path.isfile(os.path.join(hook.pending_dir, f"reply_{TEST_CHAT_ID}")), \
        "pending reply stashed"


def test_reply_completes_command(hook):
    # The reply path only makes sense after a bare arg-command stashed its
    # pending marker, so establish that precondition explicitly rather than
    # depending on another test having run first.
    hook.client.post("/webhook/monet-tg-inbound",
                     json={"message": {"chat": {"id": TEST_CHAT_ID}, "text": "/remind"}})
    assert os.path.isfile(os.path.join(hook.pending_dir, f"reply_{TEST_CHAT_ID}"))
    hook.disp.clear()

    hook.client.post("/webhook/monet-tg-inbound", json={
        "message": {"chat": {"id": TEST_CHAT_ID}, "text": "30m call dentist",
                    "reply_to_message": {"message_id": 1}}})
    assert hook.disp == ["/remind 30m call dentist"], \
        f"reply should combine into command, got {hook.disp}"
    assert not os.path.isfile(os.path.join(hook.pending_dir, f"reply_{TEST_CHAT_ID}")), \
        "pending marker should be consumed by the reply"


def test_noarg_command_still_direct(hook):
    hook.client.post("/webhook/monet-tg-inbound",
                     json={"message": {"chat": {"id": TEST_CHAT_ID}, "text": "/status"}})
    assert hook.disp == ["/status"], \
        f"/status has no USAGE, should dispatch directly, got {hook.disp}"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
