# Security Policy

## Supported versions

There are no tagged releases yet. Fixes land on `main` only.

| Version | Supported |
|---------|-----------|
| `main`  | Yes       |
| Any older commit | No — rebase onto `main` |

## Reporting a vulnerability

Please report privately through GitHub private vulnerability reporting:

https://github.com/bulletproofsoftware-ai/bulletproof-monet/security/advisories/new

If that is unavailable to you, email **security@bulletproofsoftware.ai** instead.

**Do not open a public issue for a vulnerability.** Public issues are fine for ordinary bugs.

What to expect:

- **Acknowledgement within 5 business days.** This is a commitment, not decoration. This is a
  small project; a shorter promise would be one that gets broken.
- An assessment, and a fix or an explicit "won't fix" with reasoning, once triaged.
- Credit in the advisory if you want it.

Please include the commit you tested, what you did, and what happened. A proof of concept is
welcome but not required.

## Scope

**In scope:** code in this repository — the bot handlers, the webhook receiver, the management
API, the installer, the injection pre-filter, the bundled `claude-memory` MCP server, and the
compose/nginx/systemd deployment templates.

**Out of scope:** the Claude Code CLI, Telegram, Twilio, Qdrant, n8n, Ollama, Postgres, Docker,
and every other third-party component. Report those to their own maintainers. Issues that
reduce to "the operator misconfigured their host" are also out of scope, though documentation
gaps that *invite* that misconfiguration are in scope and worth reporting.

## Threat model — read this before deploying

This section is the point of this file. Deploying Monet means accepting the following. None of
it is theoretical; all of it is how the system works by design.

- **Monet invokes the Claude Code CLI with `--dangerously-skip-permissions`.** Anything the
  assistant decides to do, it does — file reads, file writes, shell commands — with the
  privileges of the service user, with no per-action confirmation. Deploy only on a host where
  that is acceptable. Treat the service account as fully compromised in any scenario where the
  model is successfully manipulated.

- **Authorization is a single chat ID compared as a string.** `MONET_AUTHORIZED_CHAT` in
  `api/monet_webhook.py` is the entire access-control model. There are no roles, sessions, or
  second factors. Anyone who can deliver a request carrying that chat id to your webhook can
  drive the assistant. This is why the webhook must be:
  - behind TLS (`deploy/nginx/monet.conf.template` terminates TLS 1.2/1.3),
  - configured with the Telegram `secret_token` (`WEBHOOK_SECRET`, sent as the
    `X-Telegram-Bot-Api-Secret-Token` header and validated on receipt), and
  - source-IP restricted to Telegram's published ranges (the template ships
    `allow 149.154.160.0/20; allow 91.108.4.0/22; deny all;`).

  Running the webhook on plain HTTP, or without `WEBHOOK_SECRET`, removes essentially all of
  the authorization strength.

- **`BOT_TOKEN` is a bearer credential for the entire bot.** Anyone holding it can read every
  message sent to the bot and send messages as it. It is not scoped and not revocable per-use —
  rotate it via BotFather if exposed.

- **Prompt injection is a live risk.** Monet ingests web pages, documents, images, and
  transcribed audio. The pre-filter at `lib/injection_filter.py` reduces this exposure but does
  **not** eliminate it — no such filter does. Content fetched from the internet can attempt to
  steer the assistant, and the assistant runs with skipped permissions (see the first bullet).
  Assume that any untrusted content you ask Monet to read is an attempt to issue instructions.

- **The Docker stack binds every port to `127.0.0.1`.** If you rebind any of them to `0.0.0.0`,
  Qdrant, n8n, and Postgres become internet-reachable. n8n in particular can execute arbitrary
  code by design, so exposing it is equivalent to publishing a remote shell.

- **Secrets live in `.env` on disk in plaintext.** `chmod 600` it. It is gitignored, and CI
  fails if it is ever committed (both a tracked-filename check and a gitleaks scan of history
  and working tree).

## Hardening checklist

Before you expose the webhook to the internet:

- [ ] Dedicated, non-login service user; Monet does not run as root.
- [ ] `.env` is `chmod 600` and owned by the service user.
- [ ] TLS on the webhook with a valid certificate (not self-signed).
- [ ] `WEBHOOK_SECRET` set, registered with Telegram, and validated on receipt.
- [ ] nginx source-IP allow-list restricted to Telegram's ranges.
- [ ] `MONET_AUTHORIZED_CHAT` and `TG_AUTHORIZED_USER_ID` both set to your own chat id.
- [ ] Every service port bound to loopback; verify with `ss -ltnp`.
- [ ] Host firewall denies inbound except 443 (and your SSH port).
- [ ] Regular `docker compose pull` to pick up base-image security fixes.
- [ ] Review the audit log periodically (`GET /audit` on the management API, bearer-auth).
- [ ] Rotate `BOT_TOKEN` if it has ever been pasted anywhere shared.

## Known scan status

Independent scan results are published at [`docs/scan/scan-report.md`](docs/scan/scan-report.md)
— 0 critical, 0 high, gitleaks clean, scanned at commit `d0d3ffd`.

That scan predates the productization commits on `main`. Re-run before relying on it. The
`hygiene` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs gitleaks on every
push and pull request, over both git history and the working tree.
