"""SSRF defences in docker/markdown-for-agents/app/main.py.

That service fetches a caller-supplied X-Original-URL, so its address checks
are the only thing standing between a request and the cloud metadata endpoint.
CodeQL alert #6 (py/partial-ssrf) was dismissed on the strength of these
checks, so they need tests that fail loudly if the guarantee ever regresses.

The module is loaded by path rather than imported normally: it lives under
docker/ (not on sys.path) and pulls in trafilatura, which is a container-only
dependency. trafilatura is stubbed so the security logic can be tested on a
host that never installs the conversion stack.
"""
import importlib.util
import ipaddress
import os
import socket
import sys
import types

import httpx
import pytest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MAIN_PY = os.path.join(REPO_ROOT, "docker", "markdown-for-agents", "app", "main.py")


def _load_main():
    """Import main.py by path with its container-only dependency stubbed."""
    if "trafilatura" not in sys.modules:
        stub = types.ModuleType("trafilatura")
        stub.extract = lambda *a, **k: ""
        sys.modules["trafilatura"] = stub
    spec = importlib.util.spec_from_file_location("mfa_main", MAIN_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mfa = _load_main()


def _addrinfo(ip):
    """Shape a getaddrinfo() answer for *ip* the way socket returns one."""
    if ipaddress.ip_address(ip).version == 6:
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", (ip, 0, 0, 0))]
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0))]


# --- _blocked_ip -------------------------------------------------------------

@pytest.mark.parametrize("addr", [
    "127.0.0.1",          # loopback
    "10.0.0.1",           # RFC1918
    "172.16.0.1",         # RFC1918
    "192.168.1.1",        # RFC1918
    "169.254.169.254",    # cloud metadata — the one that matters most
    "0.0.0.0",            # reaches localhost on Linux
    "0.0.0.1",
    "100.64.0.1",         # CGNAT/Tailscale — no ipaddress predicate covers this
    "198.18.0.1",         # benchmarking range
    "224.0.0.1",          # multicast
    "240.0.0.1",          # reserved
    "255.255.255.255",    # broadcast
    "::1",                # IPv6 loopback
    "fc00::1",            # IPv6 unique-local
    "fe80::1",            # IPv6 link-local
    "::",                 # unspecified
    "::ffff:127.0.0.1",   # IPv4-mapped loopback — must be unwrapped first
    "::ffff:169.254.169.254",
])
def test_blocked_ip_rejects_internal(addr):
    assert mfa._blocked_ip(ipaddress.ip_address(addr)) is True


@pytest.mark.parametrize("addr", ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700::1111"])
def test_blocked_ip_allows_public(addr):
    assert mfa._blocked_ip(ipaddress.ip_address(addr)) is False


# --- validate_url ------------------------------------------------------------

@pytest.mark.parametrize("url", [
    "file:///etc/passwd",
    "gopher://example.com/",
    "ftp://example.com/",
])
def test_validate_url_rejects_non_http_scheme(url):
    with pytest.raises(ValueError, match="blocked scheme"):
        mfa.validate_url(url)


def test_validate_url_rejects_missing_hostname():
    with pytest.raises(ValueError, match="no hostname"):
        mfa.validate_url("http:///just-a-path")


def test_validate_url_rejects_internal_resolution(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo",
                        lambda *a, **k: _addrinfo("169.254.169.254"))
    with pytest.raises(ValueError, match="internal IP"):
        mfa.validate_url("http://metadata.attacker.test/")


def test_validate_url_accepts_public_resolution(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34"))
    assert mfa.validate_url("https://example.com/x") == "https://example.com/x"


def test_validate_url_rejects_when_any_answer_is_internal(monkeypatch):
    """A hostname that resolves to both a public and a private address is unsafe."""
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k:
                        _addrinfo("93.184.216.34") + _addrinfo("127.0.0.1"))
    with pytest.raises(ValueError, match="internal IP"):
        mfa.validate_url("http://split-horizon.test/")


# --- SSRFSafeTransport -------------------------------------------------------

@pytest.fixture
def no_dial(monkeypatch):
    """Stop super().handle_async_request() short of opening a socket.

    The pinning assertions care about how the request was rewritten, not about
    the response, so the parent transport is replaced with a stub.
    """
    async def _stub(self, request):
        return httpx.Response(200, request=request)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", _stub)


@pytest.mark.anyio
async def test_transport_pins_validated_ip(monkeypatch, no_dial):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _addrinfo("93.184.216.34"))
    t = mfa.SSRFSafeTransport()
    req = httpx.Request("GET", "https://example.com/page")
    await t.handle_async_request(req)

    # The connection targets the literal validated address, so the socket
    # layer has no hostname left to re-resolve.
    assert req.url.host == "93.184.216.34"
    # ...while the origin still sees the real Host and TLS still verifies
    # against the real name.
    assert req.headers["Host"] == "example.com"
    assert req.extensions["sni_hostname"] == "example.com"


@pytest.mark.anyio
async def test_transport_blocks_internal_at_connect_time(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: _addrinfo("169.254.169.254"))
    t = mfa.SSRFSafeTransport()
    req = httpx.Request("GET", "http://rebind.attacker.test/")
    with pytest.raises(httpx.ConnectError, match="SSRF blocked"):
        await t.handle_async_request(req)


@pytest.mark.anyio
async def test_transport_rejects_rebinding_second_answer(monkeypatch):
    """validate_url saw a public address; the connect-time answer is internal."""
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k:
                        _addrinfo("93.184.216.34") + _addrinfo("127.0.0.1"))
    t = mfa.SSRFSafeTransport()
    req = httpx.Request("GET", "http://rebind.attacker.test/")
    with pytest.raises(httpx.ConnectError, match="SSRF blocked"):
        await t.handle_async_request(req)


@pytest.mark.anyio
async def test_transport_raises_on_dns_failure(monkeypatch):
    def boom(*a, **k):
        raise socket.gaierror("nope")
    monkeypatch.setattr(socket, "getaddrinfo", boom)
    t = mfa.SSRFSafeTransport()
    req = httpx.Request("GET", "http://nxdomain.test/")
    with pytest.raises(httpx.ConnectError, match="DNS resolution failed"):
        await t.handle_async_request(req)


@pytest.fixture
def anyio_backend():
    return "asyncio"
