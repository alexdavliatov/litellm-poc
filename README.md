# LiteLLM + Open WebUI PoC

Single Docker Compose stack that puts one OpenAI-compatible API gateway ([LiteLLM](https://github.com/BerriAI/litellm)) in front of OpenAI, Anthropic, Gemini, DeepSeek, and local Ollama models, with [Open WebUI](https://github.com/open-webui/open-webui) as a chat front-end.

## What's included

| Service | Port | Purpose |
|---|---|---|
| LiteLLM proxy | 4000 | AI gateway — routing, virtual keys, budgets, spend tracking |
| Open WebUI | 3000 | Chat UI backed by LiteLLM |
| Postgres | — (internal) | Stores virtual keys, teams, spend logs |
| Ollama | 11434 | Local model runner (optional fallback) |

**Models pre-configured:** `gpt-5.5`, `claude-opus-4.8`, `claude-sonnet-4.6`, `claude-haiku`, `gemini-2.5-pro`, `gemini-2.5-flash`, `deepseek-v4-pro`, `deepseek-v4-flash`, `llama3.1-local`, plus a `smart` alias that load-balances across providers with automatic fallbacks.

## Prerequisites

- Docker + Docker Compose
- API keys for the providers you want to use (at least one)

## Quick start

```bash
# 1. Clone
git clone https://github.com/alexdavliatov/litellm-poc.git
cd litellm-poc

# 2. Generate secrets and enter your API keys
./setup.sh

# 3. Start everything
docker compose up -d

# 4. Open the chat UI
open http://localhost:3000

# 5. Open the admin UI (login with your LITELLM_MASTER_KEY from .env)
open http://localhost:4000/ui
```

`setup.sh` generates all random secrets and writes `.env`. Re-run with `--force` to regenerate.

## Configuration

### Adding / removing models

Edit `litellm-config.yaml`. Add a block under `model_list`, then restart:

```bash
docker compose restart litellm
```

### Skipping a provider

Leave its key blank in `.env` (or set it to a placeholder). LiteLLM will skip models that fail auth. Fallback chains in `litellm-config.yaml` route around unavailable providers automatically.

### Disabling Ollama

Comment out the `ollama` service in `docker-compose.yml` and remove `llama3.1-local` references from `litellm-config.yaml`. Ollama is optional — it's only needed for local/offline fallback.

### GPU support for Ollama

Uncomment the `deploy.resources` block in the `ollama` service in `docker-compose.yml` (requires NVIDIA Container Toolkit).

## Virtual keys (per-user budgets)

Virtual keys let you hand out scoped, budget-limited keys without exposing your master key.

**Via UI:** `http://localhost:4000/ui` → Virtual Keys → Create Key

**Via API:**

```bash
source .env
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["claude-sonnet-4.6","gpt-5.5"],"max_budget":5,"key_alias":"my-key"}'
```

The response contains `"key": "sk-..."` — use that wherever you'd use an OpenAI key.

## Connecting AI coding tools

### Claude Code

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=<virtual-key>
export ANTHROPIC_MODEL=claude-sonnet-4.6
export ANTHROPIC_SMALL_FAST_MODEL=claude-haiku
claude
```

Unset to revert: `unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL`

### Codex CLI

Add to `~/.codex/config.toml`:

```toml
model = "gpt-5.5"
model_provider = "litellm"

[model_providers.litellm]
name = "LiteLLM"
base_url = "http://localhost:4000/v1"
env_key = "LITELLM_API_KEY"
wire_api = "responses"
```

```bash
export LITELLM_API_KEY=<virtual-key>
codex
```

### Any OpenAI-compatible client

Point `base_url` at `http://localhost:4000/v1` and use any virtual key as the API key.

## Monitoring spend

- **Logs / usage:** `http://localhost:4000/ui` → Logs / Usage
- Spend is tracked per virtual key. Open WebUI does **not** show USD costs — check LiteLLM UI.
- A key stops working once it hits `max_budget`. Delete or regenerate via UI or API.

## Useful commands

```bash
docker compose up -d          # start all services
docker compose down           # stop (data volumes preserved)
docker compose down -v        # stop and delete all data
docker compose logs -f litellm  # tail LiteLLM logs
docker exec -it ollama ollama pull llama3.1  # pull a local model
```
