# Подключение Claude Code и Codex к LiteLLM (демо)

Оба CLI ходят в локальный LiteLLM по **виртуальному ключу**. Весь трафик и
расход видно в LiteLLM UI (`http://localhost:4000/ui`), бюджет ключа ограничивает
траты. По окончании демо всё откатывается в исходное состояние.

## 0. Предусловие

LiteLLM запущен (`docker compose up -d`), мастер-ключ в окружении:

```bash
export LITELLM_MASTER_KEY=sk-...   # из .env
```

## 1. Выпустить виртуальный ключ

Через UI: `http://localhost:4000/ui` → Virtual Keys → Create Key
(выбрать модели, задать budget).

Или командой:

```bash
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models":["claude-sonnet-4.6","claude-haiku","gpt-5.5","deepseek-v4-pro","deepseek-v4-flash"],"max_budget":5,"key_alias":"demo-cli"}'
```

Из ответа возьми `"key": "sk-..."` — дальше это `VIRTUAL_KEY`.

---

## 2. Claude Code

Claude Code общается по Anthropic Messages API (`/v1/messages`), который LiteLLM
отдаёт. Настройка через переменные окружения — легко откатить.

```bash
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=VIRTUAL_KEY
export ANTHROPIC_MODEL=claude-sonnet-4.6        # алиас из litellm-config.yaml
export ANTHROPIC_SMALL_FAST_MODEL=claude-haiku  # быстрая модель для мелочей
claude
```

### Откат

```bash
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
```

Или просто открой новый терминал — переменные не сохраняются между сессиями.
Claude Code вернётся к обычному входу (подписка / прямой Anthropic-ключ).

---

## 3. Codex CLI

С февраля 2026 Codex поддерживает только `wire_api = "responses"` (Responses API).
LiteLLM этот эндпоинт умеет, поэтому база указывает на `/v1`.

Сначала бэкап конфига:

```bash
cp ~/.codex/config.toml ~/.codex/config.toml.bak
```

Добавь в `~/.codex/config.toml`:

```toml
model = "gpt-5.5"
model_provider = "litellm"

[model_providers.litellm]
name = "LiteLLM"
base_url = "http://localhost:4000/v1"
env_key = "LITELLM_API_KEY"
wire_api = "responses"
```

Запуск:

```bash
export LITELLM_API_KEY=VIRTUAL_KEY
codex
```

> ID провайдера не может быть `openai`, `ollama` или `lmstudio` — они зарезервированы.
> Поэтому используем `litellm`.

### Откат

```bash
mv ~/.codex/config.toml.bak ~/.codex/config.toml   # вернуть прежний конфиг
unset LITELLM_API_KEY
```

Если бэкапа не было — просто удали блок `[model_providers.litellm]` и строки
`model_provider = "litellm"` / `model = "gpt-5.5"`, вернув `model_provider = "openai"`.

---

## Проверка во время демо

> **Важно:** Open WebUI — только чат-фронтенд. Расход в USD *нигде* не отображается
> внутри Open WebUI. Смотреть деньги / токены нужно в **LiteLLM UI**.

- Расход и логи запросов: `http://localhost:4000/ui` → Logs / Usage.
- Лимит бюджета на ключе остановит траты после превышения `max_budget`.
- Можно отозвать ключ в любой момент: UI → Virtual Keys → Delete, или
  `curl -X POST http://localhost:4000/key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" -d '{"keys":["VIRTUAL_KEY"]}'`
