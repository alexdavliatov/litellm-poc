# LiteLLM + Open WebUI — PoC Plan

A local Docker Compose proof-of-concept that puts one chat UI (Open WebUI) in
front of an LLM gateway (LiteLLM) routing to OpenAI, Anthropic, Google Gemini,
and a local Ollama model — with virtual keys, budgets, and spend tracking on.

## Goals this PoC proves

1. **Unified chat UI** — one Open WebUI front-end, many models behind it.
2. **Cost tracking & keys** — per-user/team virtual keys, budgets, USD spend logs.
3. **Multi-provider routing** — model aliases, load balancing, and fallbacks across providers.
4. **Auth & access control** — Open WebUI accounts + LiteLLM keys/teams scoping who uses what.

## Architecture

```
                 ┌──────────────┐      OpenAI-compatible      ┌──────────────┐
   Browser  ───▶ │  Open WebUI  │ ──── /v1/chat/completions ─▶│   LiteLLM    │
   :3000         │  (chat UI,   │                             │  (gateway,   │
                 │   accounts)  │                             │   keys,      │
                 └──────────────┘                             │   budgets)   │
                                                              └──────┬───────┘
                                            ┌────────────────────────┼────────────────────────┐
                                  ┌─────────┬───────────┼───────────┬──────────────┐
                                  ▼         ▼           ▼           ▼              ▼
                            OpenAI API  Anthropic API  Gemini API  Ollama (local :11434)
                                                                                          │
                                                              Postgres ◀── keys / teams / spend
```

- **Open WebUI** (`:3000`) — front-end and user auth. Talks only to LiteLLM.
- **LiteLLM** (`:4000`) — the gateway. Routing, fallbacks, virtual keys, budgets, spend, admin UI at `/ui`.
- **Postgres** — persists keys, teams, and spend. Required for keys/budgets/UI.
- **Ollama** (`:11434`) — local open-weight models; proves the no-external-API path.

## Milestones

**M0 — Prereqs (15 min).** Docker + Compose installed. OpenAI and Anthropic API keys in hand. Generate secrets (`openssl rand -hex 32`).

**M1 — Bring up the stack (15 min).** `cp .env.example .env`, fill values, `docker compose up -d`. Confirm all containers healthy.

**M2 — Wire models (15 min).** Pull a local model (`docker exec -it ollama ollama pull llama3.1`). Verify LiteLLM lists every model and that a test completion works for each provider.

**M3 — Chat through the UI (15 min).** Create the first Open WebUI admin account, pick a model from the dropdown, send messages. Confirm OpenAI, Anthropic, and the local model all respond.

**M4 — Keys, budgets, spend (30 min).** In LiteLLM admin UI (`:4000/ui`): create a team, mint a virtual key with a small budget, swap that key into Open WebUI, send traffic, watch spend accrue and the budget enforce.

**M5 — Routing & fallback (20 min).** Call the `smart` alias to see load-balancing; temporarily break one provider key to watch the fallback kick in.

**M6 — Auth & access control (20 min).** Tighten Open WebUI signups (admin-approval / disable open registration), and scope models per team/key in LiteLLM so users only see what they're allowed.

## Validation criteria (PoC is "done" when)

- A non-technical user logs into Open WebUI and chats with at least 3 models from one dropdown.
- Spend appears in USD per key/team in the LiteLLM UI after real traffic.
- A virtual key with a tiny budget is blocked once the budget is exceeded.
- Killing one provider's key triggers a successful fallback to another provider.
- New Open WebUI signups require admin approval (no open registration).

## Quick start

```bash
cp .env.example .env          # then edit .env with your keys + secrets
docker compose up -d
docker exec -it ollama ollama pull llama3.1   # optional local model

# Verify the gateway
curl http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Then open:
- Chat UI → http://localhost:3000  (create the first account = admin)
- LiteLLM admin → http://localhost:4000/ui  (log in with the master key)

## Files in this PoC

- `docker-compose.yml` — the four services (LiteLLM, Postgres, Open WebUI, Ollama).
- `litellm-config.yaml` — model list, master key/DB, budget ceilings, routing + fallbacks.
- `.env.example` — secrets and provider keys (copy to `.env`).

## Notes & gotchas

- The first account created in Open WebUI becomes admin; lock down registration right after (M6).
- `LITELLM_SALT_KEY` encrypts stored provider keys — set it once before adding keys; changing it later orphans them.
- For PoC simplicity Open WebUI uses the master key. In any shared setting, give it a scoped **virtual key** instead.
- Local models need RAM (and ideally a GPU). Drop the `ollama` service if you only want hosted providers.
- This is a PoC: no TLS, no backups, secrets in `.env`. Don't expose it to the internet as-is.

## Beyond the PoC (production hardening)

TLS/reverse proxy, SSO (OAuth/OIDC) in Open WebUI, managed Postgres with backups,
secrets in a vault, rate-limit alerting, and per-provider keys via the LiteLLM key
manager rather than env vars.
