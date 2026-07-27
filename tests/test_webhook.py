"""Webhook transport tests: health, authorization, malformed payloads."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from conftest import TEST_CHAT_ID, UNAUTHORIZED_CHAT_ID  # noqa: E402

import pytest  # noqa: E402


@pytest.fixture
def client(monkeypatch, tmp_path):
    """TestClient with dispatch stubbed and PENDING_DIR pointed at tmp_path.

    monkeypatch auto-restores, so nothing leaks into other test modules when
    pytest collects the whole suite into a single process.
    """
    import monet_webhook
    calls = []
    monkeypatch.setattr(monet_webhook, "_run_dispatch",
                        lambda chat, text: calls.append((chat, text)))
    pending = tmp_path / "pending"
    pending.mkdir()
    monkeypatch.setattr(monet_webhook, "PENDING_DIR", str(pending))
    from fastapi.testclient import TestClient
    c = TestClient(monet_webhook.app)
    c.calls = calls
    return c


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200 and r.json()["ok"] is True


def test_authorized_triggers_dispatch(client):
    r = client.post("/webhook/monet-tg-inbound",
                    json={"message": {"chat": {"id": TEST_CHAT_ID}, "text": "hello"}})
    assert r.status_code == 200 and r.json()["ok"] is True
    assert client.calls == [(TEST_CHAT_ID, "hello")], \
        f"expected dispatch call, got {client.calls}"


def test_unauthorized_ignored(client):
    r = client.post("/webhook/monet-tg-inbound",
                    json={"message": {"chat": {"id": UNAUTHORIZED_CHAT_ID}, "text": "hi"}})
    assert r.status_code == 200 and r.json()["ok"] is True
    assert client.calls == [], f"unauthorized chat should be ignored, got {client.calls}"


def test_malformed_acked(client):
    r = client.post("/webhook/monet-tg-inbound", content=b"not json")
    assert r.status_code == 200


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
