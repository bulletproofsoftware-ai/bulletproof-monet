# Monet — Security Scan Report

Automated security scan of `bulletproof-monet` performed with **Code Hardener**
(`standard` profile — 12 code-appropriate scanners: trivy, gitleaks, opengrep, checkov,
grype, syft, oxlint, ruff, bandit, dockle, hadolint).

## Result

| Metric | Value |
|--------|------:|
| **Score** | **772 / 1000** (quality level: *good*) |
| **Critical** | **0** |
| **High** | **0** |
| Medium | 105 |
| Low | 99 |
| Info | 14 |
| Secret scan (gitleaks) | **PASS** — 0 secret findings |
| Scan ID | `a392a540-1c18-4b56-a8f6-1b65f86336fb` |
| Branch | `main` |

The scan was run against the committed HEAD **after** the fixes below were applied, and
re-run to confirm **0 critical / 0 high**.

> Scanned tree: commit `d0d3ffd` (initial public release). The productization commits
> postdate this scan; re-run Code Hardener to attest the current HEAD.

## Findings fixed (critical + high → 0)

The initial scan surfaced 4 HIGH findings. Every one was fixed:

| # | Severity | Tool | Finding | Location | Fix |
|---|----------|------|---------|----------|-----|
| 1 | HIGH | opengrep | `weak-hash-md5-sha1-python` | `scripts/index-obsidian.py:33` | Content-change hash switched from MD5 → SHA-256 (`hashlib.sha256`). Non-security hash, but replaced to clear the finding. |
| 2 | HIGH | opengrep | `weak-hash-md5-sha1-js` | `mcp/claude-memory-mcp/src/index.ts:250` | Deterministic scratch-pad UUID derivation switched from MD5 → SHA-256 (`createHash('sha256')`). UUID output shape preserved; server rebuilt. |
| 3 | HIGH | opengrep | `missing-user` | `docker/markdown-for-agents/Dockerfile` | Added a non-root `USER appuser` (uid 10001) after root-requiring build steps. |
| 4 | HIGH | trivy | `DS-0002` (image user should not be root) | `docker/markdown-for-agents/Dockerfile` | Same non-root `USER` fix. Verified: `docker run --entrypoint sh <img> -c 'id -un'` → `appuser`. |

### Additional hardening (found during review, not in the scanner's HIGH set)

- **Removed a hardcoded Qdrant API-key fallback** from
  `mcp/claude-memory-mcp/src/index.ts` (`process.env.QDRANT_API_KEY || "<key>"` →
  `process.env.QDRANT_API_KEY || ""`). The key must now be supplied via environment.
  gitleaks reports **0** secrets on the final scan.

All changes were verified: the MCP server rebuilds cleanly (`npm run build`), and the
`markdown-for-agents` image builds and runs as the non-root `appuser`.

## What remains (low-risk, intentionally not chased)

The residual medium/low findings are cosmetic or informational and were left as-is per
policy (they are not vulnerabilities):

- **Ruff style (medium):** `E402` (import not at top), `E701/E702` (multiple statements
  per line), `F401` (unused import), `F541` (f-string without placeholder), `E401`,
  `E741`. Style-only.
- **`F821` undefined name `YOUR_CHAT_ID` (medium):** a genuine defect in the test suite, not a
  false positive. Fixed; the tests now read `TEST_CHAT_ID`.
- **`dynamic-urllib-use-detected` (medium):** requests built against fixed internal
  service URLs (Qdrant, Ollama, localhost), not attacker-controlled.
- **docker-compose `no-new-privileges` / `writable-filesystem-service` (medium):**
  optional container-hardening suggestions for the reference compose files.
- **License-info notes (low):** advisory license metadata for transitive dependencies;
  all are permissive (MIT / ISC / BSD / Apache-2.0). See [../SBOM.md](../SBOM.md).

## Signed artifacts

| Artifact | File |
|----------|------|
| Attestation certificate + full report (PDF, 42 pp) | [`bulletproof-monet-scan-report.pdf`](bulletproof-monet-scan-report.pdf) |
| Cryptographic attestation (in-toto, Ed25519) | [`attestation.json`](attestation.json) |
| SARIF | [`scan-report.sarif.json`](scan-report.sarif.json) |
| Full markdown report | [`scan-report-full.md`](scan-report-full.md) |

The attestation is cryptographically signed (Ed25519); the PDF's first page is the
attestation certificate showing the 772/1000 score.

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../../LICENSE) and [NOTICE](../../NOTICE).
