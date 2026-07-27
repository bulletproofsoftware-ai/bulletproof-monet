# Security Scan Report: bulletproof-monet

**Scan ID:** `a392a540-1c18-4b56-a8f6-1b65f86336fb`
**Date:** 2026-07-24T22:33:29.497Z
**Score:** 862/1000 (good)
**Branch:** main | **Commit:** `N/A`
**Profile:** standard

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 105 |
| Low | 99 |
| Info | 14 |
| **Total (open)** | **218** |

> **Note:** The counts above reflect _open_ findings only.
> 2 scanner(s) were skipped — see "Skipped Scanners" below.

## Scanners Executed

| Scanner | Status | Findings | Duration | Notes |
|---------|--------|----------|----------|-------|
| trivy | pass | 96 | 3.1s |  |
| gitleaks | pass | 0 | 0.6s |  |
| opengrep | pass | 20 | 8.4s |  |
| checkov | pass | 0 | 3.7s |  |
| grype | pass | 1 | 3.4s |  |
| syft | pass | 5 | 1.6s |  |
| package-validator | skipped | 0 | 0.0s |  |
| oxlint | pass | 0 | 0.0s |  |
| ruff | pass | 94 | 0.0s |  |
| actionlint | skipped | 0 | 0.0s | _skipped: no_matching_files_ |
| jscpd | pass | 0 | 0.0s |  |
| typos | pass | 14 | 0.0s |  |
| _file_inventory | pass | 0 | 0.0s |  |

## Medium Findings (105)

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:10`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:9`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:8`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:7`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] \`json\` imported but unused

- **File:** `tg-memory.py:6`
- **Scanner:** ruff
- **Rule:** `RUFF-F401`

**What's wrong:** `json` imported but unused

**How to fix:** Auto-fix available: Remove unused import: `json` (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:6`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tg-memory.py:5`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_webhook_ux.py:47`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_webhook_ux.py:45`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_webhook_ux.py:32`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_webhook_ux.py:24`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_webhook_ux.py:23`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_webhook_ux.py:17`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple imports on one line

- **File:** `tests/test_webhook_ux.py:1`
- **Scanner:** ruff
- **Rule:** `RUFF-E401`

**What's wrong:** Multiple imports on one line

**How to fix:** Auto-fix available: Split imports (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_webhook.py:37`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_webhook.py:37`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_webhook.py:36`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_webhook.py:36`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_webhook.py:18`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple imports on one line

- **File:** `tests/test_webhook.py:1`
- **Scanner:** ruff
- **Rule:** `RUFF-E401`

**What's wrong:** Multiple imports on one line

**How to fix:** Auto-fix available: Split imports (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_forcereply.py:39`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_forcereply.py:37`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_forcereply.py:31`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_forcereply.py:25`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_forcereply.py:16`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_forcereply.py:15`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_forcereply.py:12`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Module level import not at top of file

- **File:** `tests/test_forcereply.py:11`
- **Scanner:** ruff
- **Rule:** `RUFF-E402`

**What's wrong:** Module level import not at top of file

**How to fix:** See: https://docs.astral.sh/ruff/rules/module-import-not-at-top-of-file

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_forcereply.py:7`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple imports on one line

- **File:** `tests/test_forcereply.py:1`
- **Scanner:** ruff
- **Rule:** `RUFF-E401`

**What's wrong:** Multiple imports on one line

**How to fix:** Auto-fix available: Split imports (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_approve.py:40`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (colon)

- **File:** `tests/test_approve.py:38`
- **Scanner:** ruff
- **Rule:** `RUFF-E701`

**What's wrong:** Multiple statements on one line (colon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-colon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_approve.py:32`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_approve.py:31`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_approve.py:25`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_approve.py:24`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Undefined name \`YOUR_CHAT_ID\`

- **File:** `tests/test_approve.py:18`
- **Scanner:** ruff
- **Rule:** `RUFF-F821`

**What's wrong:** Undefined name `YOUR_CHAT_ID`

**How to fix:** See: https://docs.astral.sh/ruff/rules/undefined-name

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_approve.py:17`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `tests/test_approve.py:7`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple imports on one line

- **File:** `tests/test_approve.py:1`
- **Scanner:** ruff
- **Rule:** `RUFF-E401`

**What's wrong:** Multiple imports on one line

**How to fix:** Auto-fix available: Split imports (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Local variable \`proc\` is assigned to but never used

- **File:** `scripts/memory-governor.py:187`
- **Scanner:** ruff
- **Rule:** `RUFF-F841`

**What's wrong:** Local variable `proc` is assigned to but never used

**How to fix:** Auto-fix available: Remove assignment to unused variable `proc` (applicability: unsafe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/memory-governor.py:164`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] \`datetime.timedelta\` imported but unused

- **File:** `scripts/memory-governor.py:20`
- **Scanner:** ruff
- **Rule:** `RUFF-F401`

**What's wrong:** `datetime.timedelta` imported but unused

**How to fix:** Auto-fix available: Remove unused import: `datetime.timedelta` (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] \`time\` imported but unused

- **File:** `scripts/memory-export.py:17`
- **Scanner:** ruff
- **Rule:** `RUFF-F401`

**What's wrong:** `time` imported but unused

**How to fix:** Auto-fix available: Remove unused import: `time` (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/index-obsidian.py:378`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/index-obsidian.py:377`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] Multiple statements on one line (semicolon)

- **File:** `scripts/index-obsidian.py:332`
- **Scanner:** ruff
- **Rule:** `RUFF-E702`

**What's wrong:** Multiple statements on one line (semicolon)

**How to fix:** See: https://docs.astral.sh/ruff/rules/multiple-statements-on-one-line-semicolon

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/index-obsidian.py:329`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/index-obsidian.py:328`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

### [MEDIUM] f-string without any placeholders

- **File:** `scripts/index-obsidian.py:87`
- **Scanner:** ruff
- **Rule:** `RUFF-F541`

**What's wrong:** f-string without any placeholders

**How to fix:** Auto-fix available: Remove extraneous `f` prefix (applicability: safe)

**Action:** Plan to fix this issue in your next sprint or release.

---

> ... and 55 more medium findings

## Low Findings (99)

- **SBOM-LICENSE-UNKNOWN**: Unknown License: uvicorn@0.34.0 (`/docker/markdown-for-agents/app/requirements.txt`)
- **SBOM-LICENSE-UNKNOWN**: Unknown License: trafilatura@2.0.0 (`/docker/markdown-for-agents/app/requirements.txt`)
- **SBOM-LICENSE-UNKNOWN**: Unknown License: playwright@1.50.0 (`/docker/markdown-for-agents/app/requirements.txt`)
- **SBOM-LICENSE-UNKNOWN**: Unknown License: httpx@0.28.1 (`/docker/markdown-for-agents/app/requirements.txt`)
- **SBOM-LICENSE-UNKNOWN**: Unknown License: fastapi@0.115.8 (`/docker/markdown-for-agents/app/requirements.txt`)
- **LICENSE-Apache-2.0**: License Compliance: Apache-2.0 in  (`LICENSE`)
- **LICENSE-BSD-3-Clause**: License Compliance: BSD-3-Clause in httpx (`docker/markdown-for-agents/app/requirements.txt`)
- **LICENSE-ISC**: License Compliance: ISC in zod-to-json-schema (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-ISC**: License Compliance: ISC in wrappy (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-ISC**: License Compliance: ISC in which (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in vary (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in unpipe (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in type-is (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in toidentifier (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in statuses (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in side-channel-weakmap (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in side-channel-map (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in side-channel-list (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in side-channel (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in shebang-regex (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in shebang-command (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-ISC**: License Compliance: ISC in setprototypeof (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in serve-static (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in send (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in safer-buffer (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in router (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in require-from-string (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in raw-body (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in range-parser (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-BSD-3-Clause**: License Compliance: BSD-3-Clause in qs (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in proxy-addr (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in pkce-challenge (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in path-to-regexp (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in path-key (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in parseurl (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-ISC**: License Compliance: ISC in once (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in on-finished (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in object-inspect (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in object-assign (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in negotiator (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in ms (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in mime-types (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in mime-db (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in merge-descriptors (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in media-typer (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in math-intrinsics (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-BSD-2-Clause**: License Compliance: BSD-2-Clause in json-schema-typed (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in json-schema-traverse (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-MIT**: License Compliance: MIT in jose (`mcp/claude-memory-mcp/package-lock.json`)
- **LICENSE-ISC**: License Compliance: ISC in isexe (`mcp/claude-memory-mcp/package-lock.json`)

> ... and 49 more low findings

## Skipped Scanners (2)

Scanners that did not run on this scan, with the reason why and how to enable them.

| Scanner | Reason | How to enable |
|---------|--------|---------------|
| `actionlint` | no_matching_files | No .github/workflows directory found — actionlint requires GitHub Actions workflow files |
| `package-validator` | unknown | _(no hint)_ |

## Recommendations

1. Update 96 vulnerable dependency/dependencies -- run `npm audit fix` or equivalent

---
*Generated by Code Hardener v0.1.0 | 2026-07-24T22:34:51.677Z*