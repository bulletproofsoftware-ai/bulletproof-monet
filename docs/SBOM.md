# Monet — Software Bill of Materials

Monet is primarily an orchestration tree of shell and Python scripts that drive external
services (Claude Code CLI, Qdrant, Ollama, n8n). It has one packaged Node component with
a lockfile — the memory MCP server — plus a small pinned Python dependency set in the
HTML→Markdown proxy, and several third-party container base images.

## Node component — `mcp/claude-memory-mcp`

A machine-readable CycloneDX SBOM is committed at
[`claude-memory-mcp.cyclonedx.json`](claude-memory-mcp.cyclonedx.json)
(CycloneDX 1.5), generated with `npm sbom --sbom-format cyclonedx --omit dev`.

**Direct runtime dependencies:**

| Package | Version | License |
|---------|---------|---------|
| `@modelcontextprotocol/sdk` | ^1.0.0 | MIT |
| `zod` | ^3.23.0 | MIT |

**Full runtime dependency graph:** 92 components.

**License distribution:**

| License | Components |
|---------|-----------:|
| MIT | 82 |
| ISC | 7 |
| BSD-3-Clause | 2 |
| BSD-2-Clause | 1 |

All licenses are permissive (MIT / ISC / BSD family) and compatible with the project's
Apache-2.0 license. Development-only dependencies (`typescript`, `@types/node`) are
excluded from the runtime SBOM above.

## Python dependencies — HTML→Markdown proxy

`docker/markdown-for-agents/app/requirements.txt` (pinned):

| Package | Version | License |
|---------|---------|---------|
| `fastapi` | 0.115.8 | MIT |
| `uvicorn[standard]` | 0.34.0 | BSD-3-Clause |
| `httpx` | 0.28.1 | BSD-3-Clause |
| `trafilatura` | 2.0.0 | Apache-2.0 |
| `playwright` | 1.50.0 | Apache-2.0 |

The rest of the repository's Python (management API, memory governor, utility scripts)
relies on the standard library plus `requests`; those scripts are run with the host's
Python and are not packaged.

## Container base images

| Image | Used by |
|-------|---------|
| `python:3.12-slim` | `docker/markdown-for-agents` (runs as non-root `appuser`, uid 10001) |
| `qdrant/qdrant:latest` | vector memory backend |
| `n8nio/n8n:latest` | workflow orchestration |
| `postgres:16-alpine` | n8n persistence |

> Pinning note: the Qdrant and n8n images are referenced by the `:latest` tag in the
> reference compose file. For reproducible deployments, pin these to specific digests.

## Regenerating the Node SBOM

```bash
cd mcp/claude-memory-mcp
npm install
npm sbom --sbom-format cyclonedx --omit dev > ../../docs/claude-memory-mcp.cyclonedx.json
```

---

Apache-2.0 © 2026 bulletproofsoftware-ai. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
