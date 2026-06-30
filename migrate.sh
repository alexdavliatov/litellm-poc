#!/usr/bin/env bash
# migrate.sh - one-stop migration of Claude Code + Claude Desktop + Codex from
# cloud onto the shared LiteLLM gateway, via cc-switch. Subcommands:
#
#   install   Install cc-switch (brew cask) and verify dependencies.
#   import    Clone YOUR OWN current cc-switch profiles, swap only the connection
#             to the gateway, create 'LiteLLM Local' profiles + a sourceable
#             litellm-local.env snippet. (alias: migrate)
#   status    Show cc-switch profiles, the active one, and gateway reachability.
#   rollback  Restore the most recent cc-switch DB backup taken by import.
#
# Gateway URL and model aliases are baked in below (edit GATEWAY / ALIAS_* to
# change them). Nothing personal is baked in: import reads each machine's own
# profiles, so every teammate keeps THEIR plugins / MCPs / skills. Existing
# profiles are never modified; the cc-switch DB is backed up before any write.
#
# Examples:
#   ./migrate.sh install
#   ./migrate.sh import                 # prompts for your LiteLLM virtual key
#   ./migrate.sh import --key sk-xxx --activate
#   ./migrate.sh status
#   ./migrate.sh rollback

set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

CC_SWITCH_DB="$HOME/.cc-switch/cc-switch.db"
ENV_FILE="$REPO_DIR/.env"
SNIPPET="$REPO_DIR/litellm-local.env"

# --- Team gateway config (edit here) ---------------------------------------
GATEWAY="https://litellm.tangome.cloud"
ALIAS_OPUS="claude-opus-4-8[1M]"
ALIAS_SONNET="claude-sonnet-4-6"
ALIAS_HAIKU="claude-haiku-4-5"
ALIAS_CODEX="claude-sonnet-4-6"          # model Codex uses (via /v1/responses)
APPS_DEFAULT="claude,claude-desktop,codex"
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() { grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; }

cmd_install() {
  say "Checking dependencies..."
  have python3 || die "python3 not found."
  have curl    || die "curl not found."
  if have cc-switch; then
    say "  ok cc-switch already installed ($(cc-switch --version 2>/dev/null | head -1))"
  else
    have brew || die "Homebrew not found. Install from https://brew.sh then re-run."
    say "  Installing cc-switch (brew cask)..."
    brew install --cask cc-switch
  fi
  have docker && say "  ok docker present (not needed for a remote gateway)" || say "  -- docker not found (fine for a remote gateway)"
  [[ -f "$CC_SWITCH_DB" ]] || say "  -- open the cc-switch app once to create the DB, then: ./migrate.sh import"
  say "Done. Next: ./migrate.sh import"
}

cmd_import() {
  local key="" mint=false dry=false activate=false
  local do_claude=true do_desk=true do_codex=true app_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key)          key="$2"; shift 2 ;;
      --mint)         mint=true; shift ;;
      --activate)     activate=true; shift ;;
      --dry-run)      dry=true; shift ;;
      --claude-only)  app_override="claude"; shift ;;
      --desktop-only) app_override="claude-desktop"; shift ;;
      --codex-only)   app_override="codex"; shift ;;
      --no-claude)    do_claude=false; shift ;;
      --no-desktop)   do_desk=false; shift ;;
      --no-codex)     do_codex=false; shift ;;
      *) die "import: unknown argument $1" ;;
    esac
  done

  local url="$GATEWAY" opus="$ALIAS_OPUS" sonnet="$ALIAS_SONNET" haiku="$ALIAS_HAIKU" gpt="$ALIAS_CODEX" apps="$APPS_DEFAULT"
  [[ -n "$app_override" ]] && apps="$app_override"
  case ",$apps," in *,claude,*) :;; *) do_claude=false;; esac
  case ",$apps," in *,claude-desktop,*) :;; *) do_desk=false;; esac
  case ",$apps," in *,codex,*) :;; *) do_codex=false;; esac

  local have_db=true
  [[ -f "$CC_SWITCH_DB" ]] || { have_db=false; say "WARN cc-switch DB not found - env snippet only (run ./migrate.sh install)."; }

  if curl -sS -m 3 "$url/health/liveliness" >/dev/null 2>&1; then say "OK gateway reachable at $url"; else say "WARN gateway not reachable at $url (setup still proceeds)."; fi

  if $mint; then
    [[ -f "$ENV_FILE" ]] || die "--mint needs $ENV_FILE (LITELLM_MASTER_KEY)."
    local mk; mk="$(grep -E '^LITELLM_MASTER_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
    [[ -n "$mk" ]] || die "LITELLM_MASTER_KEY empty in $ENV_FILE."
    say "Minting a virtual key..."
    key="$(curl -sS -X POST "$url/key/generate" -H "Authorization: Bearer $mk" -H "Content-Type: application/json" -d "{\"models\":[\"$opus\",\"$sonnet\",\"$haiku\",\"$gpt\"],\"max_budget\":10,\"key_alias\":\"cli-migrate\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("key",""))')"
    [[ "$key" == sk-* ]] || die "mint failed (gateway up? master key correct?)."
    say "  Minted ${key:0:10}..."
  fi
  [[ -n "$key" ]] || { read -r -s -p "Paste LiteLLM virtual key (sk-, hidden): " key; echo ""; }
  [[ -n "$key" ]] || die "no virtual key provided."

  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  if ! $dry && $have_db; then
    cp "$CC_SWITCH_DB" "$CC_SWITCH_DB.before-migrate-$ts"
    say "Backed up cc-switch DB -> $CC_SWITCH_DB.before-migrate-$ts"
  fi

  CC_SWITCH_DB="$CC_SWITCH_DB" KEY="$key" URL="$url" SNIPPET="$SNIPPET" \
  DRY=$($dry && echo 1 || echo 0) DB=$($have_db && echo 1 || echo 0) \
  DOC=$($do_claude && echo 1 || echo 0) DOD=$($do_desk && echo 1 || echo 0) DOX=$($do_codex && echo 1 || echo 0) \
  A_OPUS="$opus" A_SONNET="$sonnet" A_HAIKU="$haiku" A_GPT="$gpt" \
  python3 <<'PYEOF'
import json, sqlite3, time, os
e=os.environ
db=e["CC_SWITCH_DB"]; key=e["KEY"]; url=e["URL"]; snippet=e["SNIPPET"]
dry=e["DRY"]=="1"; have_db=e["DB"]=="1"
do_claude=e["DOC"]=="1"; do_desk=e["DOD"]=="1"; do_codex=e["DOX"]=="1"
A=dict(opus=e["A_OPUS"],sonnet=e["A_SONNET"],haiku=e["A_HAIKU"],gpt=e["A_GPT"])
ts_ms=int(time.time()*1000)

conn=None
if have_db:
    conn=sqlite3.connect(db,timeout=10); conn.execute("PRAGMA busy_timeout=10000")

def current(app):
    q="SELECT settings_config,name,website_url,icon,icon_color,meta FROM providers WHERE app_type=? {} LIMIT 1"
    return conn.execute(q.format("AND is_current=1"),(app,)).fetchone() or conn.execute(q.format(""),(app,)).fetchone()

def upsert(id_,app,name,cfg,web,icon,color,meta):
    if dry: print("  [dry-run] would write "+app+" '"+name+"' (id="+id_+")"); return
    conn.execute("DELETE FROM providers WHERE id=? AND app_type=?",(id_,app))
    conn.execute("INSERT INTO providers (id,app_type,name,settings_config,website_url,category,created_at,sort_index,icon,icon_color,meta,is_current,in_failover_queue,cost_multiplier) VALUES (?,?,?,?,?,?,?,?,?,?,?,0,0,'1.0')",
        (id_,app,name,json.dumps(cfg),web,"aggregator",ts_ms,999,icon,color,json.dumps(meta)))
    print("  OK "+app+" profile '"+name+"' (id="+id_+")")

def anthropic(app, full):
    if not have_db: return
    id_="litellm-local-"+app; row=current(app)
    if row:
        cfg=json.loads(row[0] or "{}"); env=dict(cfg.get("env",{}))
        env["ANTHROPIC_BASE_URL"]=url; env["ANTHROPIC_AUTH_TOKEN"]=key
        if full:
            env["ANTHROPIC_MODEL"]=A["sonnet"]; env["ANTHROPIC_SMALL_FAST_MODEL"]=A["haiku"]
            for k in list(env):
                if "OPUS_MODEL" in k or "FABLE_MODEL" in k: env[k]=A["opus"]
                elif "SONNET_MODEL" in k: env[k]=A["sonnet"]
                elif "HAIKU_MODEL" in k: env[k]=A["haiku"]
        cfg["env"]=env
        upsert(id_,app,"LiteLLM Local",cfg,url,row[3] or "newapi",row[4] or "#00A67E",json.loads(row[5] or "{}"))
    else:
        print("  ! no current "+app+" profile; connection-only profile")
        upsert(id_,app,"LiteLLM Local",{"env":{"ANTHROPIC_BASE_URL":url,"ANTHROPIC_AUTH_TOKEN":key}},url,"newapi","#00A67E",{})

if do_claude: anthropic("claude",True)
if do_desk:   anthropic("claude-desktop",False)
if do_codex and have_db:
    toml=('model_provider = "litellm"\n'+'model = "'+A["gpt"]+'"\n'+'model_reasoning_effort = "high"\ndisable_response_storage = true\n\n[model_providers.litellm]\nname = "LiteLLM Local"\n'+'base_url = "'+url+'/v1"\nwire_api = "responses"\nrequires_openai_auth = true')
    upsert("litellm-local-codex","codex","LiteLLM Local",{"auth":{"OPENAI_API_KEY":key},"config":toml},url,"newapi","#00A67E",{})

if conn is not None and not dry: conn.commit()
if conn is not None: conn.close()

se={}
if do_claude:
    se.update({"ANTHROPIC_BASE_URL":url,"ANTHROPIC_AUTH_TOKEN":key,"ANTHROPIC_MODEL":A["sonnet"],"ANTHROPIC_SMALL_FAST_MODEL":A["haiku"],"ANTHROPIC_DEFAULT_OPUS_MODEL":A["opus"],"ANTHROPIC_DEFAULT_SONNET_MODEL":A["sonnet"],"ANTHROPIC_DEFAULT_HAIKU_MODEL":A["haiku"]})
if do_codex: se["LITELLM_API_KEY"]=key
if se and not dry:
    L=["# Source to point Claude Code + Codex CLI at the LiteLLM gateway.","# Touches nothing else. Revert: open a new terminal or unset.",""]
    L+=["export "+k+"="+v for k,v in se.items()]
    if "LITELLM_API_KEY" in se:
        L+=["","# Codex also needs this in ~/.codex/config.toml (cc-switch writes it on switch):",'#   model_provider = "litellm"','#   model = "'+A["gpt"]+'"',"#   [model_providers.litellm]",'#   base_url = "'+url+'/v1"','#   wire_api = "responses"','#   requires_openai_auth = true']
    open(snippet,"w").write("\n".join(L)+"\n"); print("  OK wrote "+snippet)
PYEOF

  if ! $dry && [[ -f "$SNIPPET" ]]; then
    chmod 600 "$SNIPPET"
    grep -qxF "litellm-local.env" "$REPO_DIR/.gitignore" 2>/dev/null || printf '\n# Migration snippet (contains a live virtual key)\nlitellm-local.env\n' >> "$REPO_DIR/.gitignore"
  fi

  if $activate && ! $dry && $have_db && have cc-switch; then
    $do_claude && cc-switch use --app claude litellm-local-claude 2>/dev/null && say "Activated Claude Code"
    $do_codex  && cc-switch use --app codex  litellm-local-codex  2>/dev/null && say "Activated Codex"
    $do_desk   && say "Claude Desktop: switch in the cc-switch app (CLI cannot target claude-desktop)."
  fi

  say ""
  say "----------------------------------------------------------------------"
  if $dry; then
    say "Dry run complete. No changes written."
  else
    say "Done."
    $have_db && say "Created 'LiteLLM Local' cc-switch profile(s), cloned from your own."
    say ""
    say "Use the gateway:"
    $have_db && say "  - cc-switch app -> pick 'LiteLLM Local' per app (or --activate for Claude Code/Codex)"
    say "  - or per-shell:  source $SNIPPET && claude"
    say ""
    say "Roll back:  ./migrate.sh rollback   (or pick your old profile in cc-switch)"
  fi
}

cmd_status() {
  local url="$GATEWAY"
  say "Gateway: $url"
  if curl -sS -m 3 "$url/health/liveliness" >/dev/null 2>&1; then say "  reachable: yes"; else say "  reachable: no"; fi
  [[ -f "$CC_SWITCH_DB" ]] || { say "cc-switch DB not found."; return; }
  CC_SWITCH_DB="$CC_SWITCH_DB" python3 <<'PYEOF'
import sqlite3, os
c=sqlite3.connect(os.environ["CC_SWITCH_DB"])
print("\ncc-switch profiles (* = active):")
for app in ("claude","claude-desktop","codex"):
    rows=c.execute("SELECT name,is_current FROM providers WHERE app_type=? ORDER BY is_current DESC,name",(app,)).fetchall()
    if not rows: continue
    print("  "+app+":")
    for name,cur in rows: print("    "+("*" if cur else " ")+" "+name)
PYEOF
}

cmd_rollback() {
  local file="${1:-}"
  [[ -n "$file" ]] || file="$(ls -1t "$CC_SWITCH_DB".before-migrate-* 2>/dev/null | head -1 || true)"
  [[ -n "$file" && -f "$file" ]] || die "no backup found (looked for $CC_SWITCH_DB.before-migrate-*)."
  say "Restore $file -> $CC_SWITCH_DB ?"
  read -r -p "  [y/N] " r; [[ "$r" =~ ^[Yy]$ ]] || { say "Aborted."; exit 0; }
  cp "$file" "$CC_SWITCH_DB"
  say "Restored. Restart cc-switch / re-open apps to pick up the change."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install)        cmd_install "$@" ;;
  import|migrate) cmd_import "$@" ;;
  status)         cmd_status "$@" ;;
  rollback)       cmd_rollback "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$cmd' (try: install import status rollback)" ;;
esac
