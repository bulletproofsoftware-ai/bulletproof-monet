# bulletproof-monet — discoverability aid. Every target delegates to a real
# script; there is no second implementation here.

.PHONY: check install up down logs test smoke

check:   ; ./install.sh --check
install: ; ./install.sh
up:      ; docker compose up -d
down:    ; docker compose down
logs:    ; docker compose logs -f --tail=100
smoke:   ; ./deploy/smoke-test.sh --local-only
# tests/run-all.sh is created by spec 005; this target fails until then.
test:    ; ./tests/run-all.sh
