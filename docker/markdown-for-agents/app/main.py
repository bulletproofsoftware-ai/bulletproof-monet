"""
Markdown for Agents - Self-hosted HTML-to-Markdown content negotiation service.

Sits behind nginx. When a request arrives with Accept: text/markdown,
nginx routes here. This service fetches the original HTML from the
origin backend, converts it to markdown, and returns it with
Cloudflare-compatible headers (x-markdown-tokens, Content-Signal, Vary).

Two modes:
  - Sidecar: ORIGIN_BACKEND env var points to the local app (e.g. http://app:8080)
  - Proxy:   Pass X-Original-URL header with the full URL to fetch
"""

import os
import re
import logging

import ipaddress
import socket
from urllib.parse import urlparse

import httpx
import trafilatura
from fastapi import FastAPI, Request, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mfa")

# --- SSRF protection ---------------------------------------------------------
# build_origin_url() honours a caller-supplied X-Original-URL header and the
# result is fetched with httpx, so without these checks any client could make
# this service request arbitrary internal addresses — including cloud metadata
# endpoints on 169.254.169.254.
#
# Ported from bulletproof-markdown-for-agents, which is the upstream of this
# vendored copy and already carried the hardened implementation.
_BLOCKED_NETWORKS = [
    ipaddress.ip_network("127.0.0.0/8"),       # Loopback
    ipaddress.ip_network("10.0.0.0/8"),        # RFC1918
    ipaddress.ip_network("172.16.0.0/12"),     # RFC1918
    ipaddress.ip_network("192.168.0.0/16"),    # RFC1918
    ipaddress.ip_network("169.254.0.0/16"),    # Link-local / cloud metadata
    ipaddress.ip_network("0.0.0.0/8"),         # "This network" — 0.0.0.0 reaches localhost on Linux
    ipaddress.ip_network("100.64.0.0/10"),     # CGNAT / Tailscale — no ipaddress predicate covers this
    ipaddress.ip_network("::1/128"),           # IPv6 loopback
    ipaddress.ip_network("fc00::/7"),          # IPv6 private
    ipaddress.ip_network("fe80::/10"),         # IPv6 link-local
]


def _blocked_ip(addr: ipaddress._BaseAddress) -> bool:
    # ::ffff:127.0.0.1 reaches the same host as 127.0.0.1, so an IPv4-mapped
    # address has to be unwrapped before any range test. Recent CPython folds
    # this into is_private, but unwrapping explicitly keeps the check correct
    # on older interpreters too.
    mapped = getattr(addr, "ipv4_mapped", None)
    if mapped is not None:
        addr = mapped
    # The named list above documents intent; these predicates catch the rest of
    # the special-purpose space (0.0.0.0/8, 198.18.0.0/15, 240.0.0.0/4,
    # multicast, ...) so the block list cannot silently fall behind the IANA
    # registry.
    if (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr.is_unspecified
    ):
        return True
    return any(addr in network for network in _BLOCKED_NETWORKS)


def _log_safe(value: object, limit: int = 200) -> str:
    """Flatten a value for logging so it cannot forge log records.

    A caller-controlled URL carrying CR/LF would otherwise inject entire fake
    log lines. Control characters are escaped and the result is truncated.
    """
    text = str(value)
    text = re.sub(r"[\x00-\x1f\x7f]", lambda m: "\\x%02x" % ord(m.group()), text)
    return text[:limit] + ("..." if len(text) > limit else "")


def validate_url(url: str) -> str:
    """Return *url* if it is safe to fetch, else raise ValueError."""
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"blocked scheme: {parsed.scheme!r}")
    if not parsed.hostname:
        raise ValueError("no hostname in URL")
    try:
        infos = socket.getaddrinfo(parsed.hostname, None, socket.AF_UNSPEC)
    except socket.gaierror as exc:
        raise ValueError(f"DNS resolution failed for {parsed.hostname}") from exc
    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if _blocked_ip(addr):
            raise ValueError(f"blocked: {parsed.hostname} resolves to internal IP {addr}")
    return url


class SSRFSafeTransport(httpx.AsyncHTTPTransport):
    """Connect only to an address that was validated for this request.

    validate_url() resolves once; a hostname whose DNS answer changes between
    that check and the connection would otherwise slip through. Re-resolving
    here is not sufficient on its own — the socket layer would resolve a third
    time, and a rebinding server can return a public address to both of our
    lookups and a private one to that final resolution.

    So the validated address is substituted into the URL and the connection is
    pinned to it. The original hostname is carried in the Host header and in
    the TLS SNI extension, which httpcore passes through as `server_hostname`,
    so certificate verification stays bound to the real hostname rather than
    to the literal IP.
    """

    async def handle_async_request(self, request):
        hostname = request.url.host
        try:
            infos = socket.getaddrinfo(hostname, None, socket.AF_UNSPEC)
        except socket.gaierror as exc:
            raise httpx.ConnectError(f"DNS resolution failed for {hostname}") from exc
        if not infos:
            raise httpx.ConnectError(f"no address returned for {hostname}")
        for info in infos:
            addr = ipaddress.ip_address(info[4][0])
            if _blocked_ip(addr):
                raise httpx.ConnectError(
                    f"SSRF blocked: {hostname} resolved to internal IP {addr}"
                )

        # Every answer passed, so pinning to the first cannot select a blocked
        # address. Host must be captured before the URL is rewritten.
        pinned = ipaddress.ip_address(infos[0][4][0])
        request.headers["Host"] = request.url.netloc.decode("ascii")
        request.extensions = {**request.extensions, "sni_hostname": hostname}
        request.url = request.url.copy_with(host=str(pinned))
        return await super().handle_async_request(request)

ORIGIN_BACKEND = os.environ.get("ORIGIN_BACKEND", "").rstrip("/")
MAX_HTML_BYTES = int(os.environ.get("MAX_HTML_BYTES", 5_000_000))  # 5 MB
CONTENT_SIGNAL = os.environ.get("CONTENT_SIGNAL", "ai-train=yes, search=yes, ai-input=yes")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", 15))
SSL_CA_BUNDLE = os.environ.get("SSL_CERT_FILE", True)  # True = default certifi, or path to system CA

app = FastAPI(docs_url=None, redoc_url=None)


def estimate_tokens(text: str) -> int:
    """Rough token estimate: split on whitespace + punctuation boundaries."""
    return int(len(re.findall(r"\S+", text)) * 0.75)


def build_origin_url(request: Request, path: str) -> str | None:
    """Determine the origin URL to fetch HTML from."""
    # Explicit header takes priority (proxy mode)
    explicit = request.headers.get("x-original-url")
    if explicit:
        return explicit

    # Sidecar mode: use configured backend
    if ORIGIN_BACKEND:
        url = f"{ORIGIN_BACKEND}/{path}"
        if request.url.query:
            url += f"?{request.url.query}"
        return url

    # Reconstruct from forwarded headers
    scheme = request.headers.get("x-forwarded-proto", "https")
    host = request.headers.get("x-forwarded-host")
    if not host:
        return None
    url = f"{scheme}://{host}/{path}"
    if request.url.query:
        url += f"?{request.url.query}"
    return url


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.api_route("/{path:path}", methods=["GET", "HEAD"])
async def convert(request: Request, path: str):
    origin_url = build_origin_url(request, path)
    if not origin_url:
        return Response(
            content="Cannot determine origin URL. Set ORIGIN_BACKEND or pass X-Original-URL header.",
            status_code=502,
        )

    # X-Original-URL is caller-controlled, so the target must be validated
    # before it is fetched.
    try:
        origin_url = validate_url(origin_url)
    except ValueError as exc:
        # The reason stays server-side. validate_url's message names the IP the
        # hostname resolved to, so echoing it back would turn this endpoint into
        # an SSRF oracle: an attacker could map internal address space by
        # watching which hostnames report which private IPs.
        log.warning("Refusing to fetch %s: %s", _log_safe(origin_url), _log_safe(exc))
        return Response(content="Refused to fetch origin URL.", status_code=400)

    log.info("Fetching %s", _log_safe(origin_url))

    # Fetch original HTML from origin. SSRFSafeTransport re-validates the
    # resolved address at connect time, so a rebinding DNS answer cannot
    # sneak past the check above. follow_redirects is disabled because a
    # redirect to an internal address would bypass validate_url entirely.
    try:
        async with httpx.AsyncClient(
            follow_redirects=False,
            timeout=REQUEST_TIMEOUT,
            limits=httpx.Limits(max_connections=50),
            verify=SSL_CA_BUNDLE,
            transport=SSRFSafeTransport(),
        ) as client:
            resp = await client.get(
                origin_url,
                headers={
                    "Accept": "text/html",
                    "User-Agent": "MarkdownForAgents/1.0",
                },
            )
    except httpx.TimeoutException:
        return Response(content="Origin timeout", status_code=504)
    except httpx.RequestError as exc:
        log.error("Origin request failed: %s", exc)
        return Response(content="Origin unreachable", status_code=502)

    if resp.status_code != 200:
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            media_type=resp.headers.get("content-type", "text/html"),
        )

    content_type = resp.headers.get("content-type", "")
    if "text/html" not in content_type:
        # Not HTML - pass through as-is
        return Response(
            content=resp.content,
            status_code=200,
            media_type=content_type,
        )

    if len(resp.content) > MAX_HTML_BYTES:
        return Response(content="Page too large for conversion", status_code=413)

    html = resp.text

    # Convert to markdown with trafilatura
    markdown = trafilatura.extract(
        html,
        output_format="markdown",
        include_links=True,
        include_images=True,
        include_tables=True,
        include_comments=False,
        favor_recall=True,
    )

    if not markdown:
        log.warning("Conversion produced no output for %s", _log_safe(origin_url))
        return Response(
            content=html,
            status_code=200,
            media_type="text/html; charset=utf-8",
            headers={"vary": "accept"},
        )

    # Build frontmatter from page metadata
    metadata = trafilatura.extract(html, output_format="xml", include_links=False)
    title_match = re.search(r"<title>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
    desc_match = re.search(
        r'<meta\s+name=["\']description["\']\s+content=["\'](.*?)["\']',
        html,
        re.IGNORECASE,
    )

    frontmatter_parts = []
    if title_match:
        title = title_match.group(1).strip()
        frontmatter_parts.append(f"title: {title}")
    if desc_match:
        desc = desc_match.group(1).strip()
        frontmatter_parts.append(f"description: {desc}")

    if frontmatter_parts:
        fm = "---\n" + "\n".join(frontmatter_parts) + "\n---\n\n"
        markdown = fm + markdown

    tokens = estimate_tokens(markdown)

    if request.method == "HEAD":
        return Response(
            content="",
            status_code=200,
            media_type="text/markdown; charset=utf-8",
            headers={
                "x-markdown-tokens": str(tokens),
                "content-signal": CONTENT_SIGNAL,
                "vary": "accept",
                "x-converted-by": "markdown-for-agents/1.0",
            },
        )

    return Response(
        content=markdown,
        status_code=200,
        media_type="text/markdown; charset=utf-8",
        headers={
            "x-markdown-tokens": str(tokens),
            "content-signal": CONTENT_SIGNAL,
            "vary": "accept",
            "x-converted-by": "markdown-for-agents/1.0",
        },
    )
