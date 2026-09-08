#!/bin/bash

GREEN='\033[0;32m'
NC='\033[0m'
DIR=/root/session-claw-bridge
API=https://opencode.ai/zen/go/v1/models
FALLBACK=(deepseek-v4-flash kimi-k3 glm-5.3 glm-5.3-flash deepseek-v4-pro grok-4.5 qwen3.8-max mimo-v2.5 minimax-m3 hy4-preview)
DEFAULT_MODEL=opencode-go/deepseek-v4-flash

echo ""
echo "  Session AI Agent"
echo "  ----------------"
echo ""

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r /dev/tty ]] || { echo "No terminal available." >&2; exit 1; }

# ── helpers ──────────────────────────────────────────────────────

spinner() {
  local pid=$1 chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s" "${chars:$((i++ % ${#chars})):1}"
    sleep 0.1
  done
  printf "\r  \r"
}

fetch_models() {
  local -n out=$1; out=()
  echo "  Fetching models..."
  local json
  json=$(timeout 10 curl -sf --max-time 8 "$API" 2>/dev/null || true)
  if [[ -n "$json" ]]; then
    while IFS= read -r m; do [[ -n "$m" ]] && out+=("$m")
    done < <(echo "$json" | grep -oP '"id"\s*:\s*"\K[^"]+' 2>/dev/null || true)
  fi
  [[ ${#out[@]} -eq 0 ]] && out=("${FALLBACK[@]}")
}

pick_model() {
  local -n list=$1 outvar=$2
  for i in "${!list[@]}"; do printf " %2s) opencode-go/%s\n" "$((i+1))" "${list[$i]}"; done
  echo ""
  read -p "Pick a number (or type model) [${DEFAULT_MODEL#opencode-go/}]: " p </dev/tty
  if [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le ${#list[@]} ]]; then
    outvar="opencode-go/${list[$((p-1))]}"
  elif [[ -n "$p" ]]; then outvar="$p"
  else outvar="$DEFAULT_MODEL"; fi
  echo -e "  ${GREEN}Selected: $outvar${NC}"
  echo ""
}

show_bot_id() {
  local id="" file=/tmp/session-ai-agent/session-id.txt
  for i in 1 2 3 4 5; do
    [[ -f "$file" ]] && { id=$(cat "$file"); break; }
    sleep 3
  done
  echo -e "AI Agent Session ID:  ${GREEN}${id:-check logs}${NC}"
  echo "1. Open Session, paste this ID to send a message request"
  echo "2. Only your Session ID (${1}) can message the bot"
}

init_openclaw() {
  openclaw onboard --accept-risk --non-interactive --skip-health --skip-daemon --skip-bootstrap \
    --auth-choice opencode-go --opencode-go-api-key "$1" >/dev/null 2>&1 || true
  openclaw config set agents.defaults.model.primary "$2" >/dev/null 2>&1 || true
  openclaw config set agents.defaults.models "{\"$2\":{}}" --strict-json --merge >/dev/null 2>&1 || true

  if [[ "$2" == opencode-go/* ]]; then
    local bare="${2#opencode-go/}"
    local tmp entries

    # Full field set newer OpenClaw builds expect, so validation doesn't silently reject
    # the entry. Preserves already-registered models instead of replacing the whole array.
    entries=$(python3 -c '
import json, sys
entry = {
    "id": sys.argv[1], "name": sys.argv[1],
    "api": "openai-completions",
    "baseUrl": "https://opencode.ai/zen/go/v1",
    "reasoning": False,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    "contextWindow": 200000,
    "maxTokens": 8192,
}
try:
    cur = json.loads(sys.argv[2] or "[]")
except Exception:
    cur = []
arr = [e for e in cur if e.get("id") != sys.argv[1]] + [entry]
print(json.dumps(arr))
' "$bare" "$(openclaw config get models.providers.opencode-go.models --json 2>/dev/null || echo '[]')") \
      || entries="[{\"id\":\"$bare\",\"name\":\"$bare\",\"api\":\"openai-completions\",\"baseUrl\":\"https://opencode.ai/zen/go/v1\",\"reasoning\":false,\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":200000,\"maxTokens\":8192}]"

    if ! grep -q '^OPENCODE_SESSION=' "$DIR/.env" 2>/dev/null; then
      OPENCODE_SESSION=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "saa-$(date +%s)")
      echo "OPENCODE_SESSION=$OPENCODE_SESSION" >> "$DIR/.env"
    else
      OPENCODE_SESSION=${OPENCODE_SESSION:-$(grep -oP '^OPENCODE_SESSION=\K.*' "$DIR/.env" 2>/dev/null)}
    fi

    tmp=$(mktemp)
    printf '{ models: { providers: { "opencode-go": { models: %s, headers: { "x-opencode-session": "%s" } } } } }\n' "$entries" "$OPENCODE_SESSION" > "$tmp"
    openclaw config patch --file "$tmp" >/dev/null 2>&1
    rm -f "$tmp"

    # Verify it actually registered - no more silent failure.
    if ! openclaw config get models.providers.opencode-go.models --json 2>/dev/null | grep -q "\"id\": \"$bare\""; then
      echo "  WARNING: could not register $bare in OpenClaw providers."
      echo "  Add { id: \"$bare\", name: \"$bare\", api: \"openai-completions\", baseUrl: \"https://opencode.ai/zen/go/v1\" }"
      echo "  to models.providers.opencode-go.models manually."
    fi
    if ! openclaw config get models.providers.opencode-go.headers --json 2>/dev/null | grep -q 'x-opencode-session'; then
      echo "  WARNING: could not register the OpenCode session header."
      echo "  Requests to opencode.ai will be rejected (MissingSessionID)."
    fi
  fi
}

install_hermes() {
  echo "==> Installing Hermes Agent..."
  local log=/tmp/hermes-install.log start=$SECONDS PY="" pid="" last="" venv_ok=""
  : > "$log"
  rm -rf "$HOME/.hermes/venv"

  # Pick a usable Python (<3.14): python3.13 → python3.12 → apt install 3.12+venv → uv.
  # Never silently fall back to a 3.14+ python: it can only install the broken 0.15.x build.
  for c in python3.13 python3.12; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -m venv "$HOME/.hermes/venv" >/dev/null 2>&1; then
      PY="$c"; venv_ok=1; break
    fi
  done
  if [[ -z "$venv_ok" ]] && apt-get install -y -qq python3.12 python3.12-venv >/dev/null 2>&1 && \
     command -v python3.12 >/dev/null 2>&1 && python3.12 -m venv "$HOME/.hermes/venv" >/dev/null 2>&1; then
    PY=python3.12; venv_ok=1
  fi
  if [[ -z "$venv_ok" ]]; then
    echo "  No working Python <3.14 found - using uv (downloads its own Python, first run slower)"
    ( curl -fsSL https://astral.sh/uv/install.sh | sh > "$log" 2>&1
      "$HOME/.local/bin/uv" venv --python 3.12 --quiet "$HOME/.hermes/venv" >> "$log" 2>&1
      "$HOME/.local/bin/uv" pip install --python "$HOME/.hermes/venv" --quiet hermes-agent >> "$log" 2>&1
      ln -sf "$HOME/.hermes/venv/bin/hermes" /usr/local/bin/hermes ) &
    pid=$!
  else
    echo "  Using $PY..."
    ( "$HOME/.hermes/venv/bin/pip" install --upgrade --quiet hermes-agent >> "$log" 2>&1
      ln -sf "$HOME/.hermes/venv/bin/hermes" /usr/local/bin/hermes ) &
    pid=$!
  fi

  while kill -0 "$pid" 2>/dev/null; do
    last=$(tail -1 "$log" 2>/dev/null | tr -d '\r' | cut -c1-70)
    printf "\r  [%02d:%02d] %s   " $(((SECONDS-start)/60)) $(((SECONDS-start)%60)) "${last:-working...}"
    sleep 2
  done
  printf "\r  Install took %dm%02ds          \n" $(((SECONDS-start)/60)) $(((SECONDS-start)%60))

  export PATH="$HOME/.local/bin:$PATH"
  if ! which hermes >/dev/null 2>&1 || [[ -L /usr/local/bin/hermes && ! -e /usr/local/bin/hermes ]]; then
    echo "  Hermes install failed - last log lines:"
    tail -5 "$log" 2>/dev/null
    return 1
  fi
  V=$(hermes --version 2>&1 | head -1)
  VM=$(echo "$V" | grep -oP 'v\K[0-9]+\.[0-9]+' | head -1)
  echo "  Hermes installed: $V"
  if [[ -n "$VM" ]] && (( $(echo "$VM" | cut -d. -f2) < 16 )); then
    echo "  ERROR: old Hermes build ($VM) - one-shot replies are broken."
    echo "  Re-run after fixing: rm -rf ~/.hermes && apt-get install python3.12 python3.12-venv"
    return 1
  fi
  mkdir -p ~/.hermes
  local HKEY="${1:-$API_KEY}"
  echo "OPENCODE_GO_API_KEY=$HKEY" > ~/.hermes/.env

  # hermes 0.19 has no native x-opencode-session support (added post-0.19).
  # Route through a custom provider that injects the header, or opencode.ai
  # returns 400 MissingSessionID - exactly the bug openclaw had.
  if ! grep -q '^OPENCODE_SESSION=' "$DIR/.env" 2>/dev/null; then
    OPENCODE_SESSION=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "saa-$(date +%s)")
    echo "OPENCODE_SESSION=$OPENCODE_SESSION" >> "$DIR/.env"
  else
    OPENCODE_SESSION=${OPENCODE_SESSION:-$(grep -oP '^OPENCODE_SESSION=\K.*' "$DIR/.env" 2>/dev/null)}
  fi
  cat > ~/.hermes/config.yaml << EOF
providers:
  ocgo:
    base_url: https://opencode.ai/zen/go/v1
    api_key: $HKEY
    extra_headers:
      x-opencode-session: $OPENCODE_SESSION
EOF

  local bare model out
  model=${MODEL:-opencode-go/deepseek-v4-flash}
  bare=${model#opencode-go/}
  echo "  Testing one-shot reply (model: $model)..."
  out=$(timeout 90 hermes -z "Reply with exactly: OK" --provider ocgo --model "$bare" 2>&1 | head -c 300)
  if [[ -z "$out" || "$out" == *Error* || "$out" == *error* ]]; then
    echo "  WARNING: smoke test returned no usable reply (${out:-empty})."
    echo "  Check your OpenCode Go API key, then re-run setup."
  else
    echo "  Smoke test OK: ${out:0:60}"
  fi
}

# ── manage menu ──────────────────────────────────────────────────

if [[ -f "$DIR/.env" ]]; then
  source <(grep -E '^(MODEL|BACKEND|OPENCODE_API_KEY|OWNER_SESSION_ID|OPENCODE_SESSION)=' "$DIR/.env" 2>/dev/null || true)
  while true; do
  echo "Already installed."
  echo -e "  Engine: ${GREEN}${BACKEND:-openclaw}${NC}"
  echo -e "  Model:  ${GREEN}${MODEL:-none}${NC}"
  echo ""
  echo "  1) Change model"
  if [[ "${BACKEND:-openclaw}" == openclaw ]]; then
    echo -e "  2) Switch engine -> ${GREEN}Hermes Agent${NC}"
  else
    echo -e "  2) Switch engine -> ${GREEN}OpenClaw${NC}"
  fi
  echo "  3) View Session ID"
  echo "  4) Uninstall"
  echo "  5) Exit"
  echo ""
  read -p "Choice [1-5]: " act </dev/tty

  if [[ "$act" == 4 ]]; then
    read -p "Uninstall? [y/N]: " yn </dev/tty
    [[ "$yn" =~ ^[Yy] ]] || exit 0
    systemctl stop claw-bridge 2>/dev/null || true
    systemctl disable claw-bridge 2>/dev/null || true
    rm -f /etc/systemd/system/claw-bridge.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$DIR" /root/.openclaw /root/.hermes
    echo -e "${GREEN}Done.${NC}"
    exit 0
  fi

  if [[ "$act" == 3 ]]; then
    show_bot_id "$OWNER_SESSION_ID"
    echo ""
    continue
  fi

  if [[ "$act" == 2 ]]; then
    if [[ "${BACKEND:-openclaw}" == openclaw ]]; then
      if install_hermes "$OPENCODE_API_KEY"; then
        sed -i 's|^BACKEND=.*|BACKEND=hermes|' "$DIR/.env"
        grep -q '^OPENCODE_GO_API_KEY=' "$DIR/.env" || echo "OPENCODE_GO_API_KEY=$OPENCODE_API_KEY" >> "$DIR/.env"
        echo -e "${GREEN}Switched to Hermes.${NC}"
      else
        echo "  Hermes installation failed. Staying on OpenClaw."
      fi
    else
      which openclaw >/dev/null 2>&1 || {
        echo -n "==> Installing OpenClaw..."
        export PATH="/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
        npm install -g openclaw@latest >/dev/null 2>&1 &
        spinner $!
      }
      sed -i 's|^BACKEND=.*|BACKEND=openclaw|' "$DIR/.env"
      echo -n "==> Configuring OpenClaw..."
      ( init_openclaw "$OPENCODE_API_KEY" "$MODEL" && timeout 120 openclaw agent --local --session-id warmup --model "$MODEL" --message "Reply with exactly: OK" --json >/dev/null 2>&1 ) & spinner $!
      echo -e "${GREEN}Switched to OpenClaw.${NC}"
    fi
    systemctl restart claw-bridge
    echo -n "==> Restarting..."; show_bot_id "$OWNER_SESSION_ID"; exit 0
  fi

  if [[ "$act" == 1 ]]; then
    echo ""; fetch_models models; pick_model models NEW
    echo -n "==> Applying..."
    sed -i "s|^MODEL=.*|MODEL=$NEW|" "$DIR/.env"
    if [[ "${BACKEND:-openclaw}" == openclaw ]]; then
      echo -n "Configuring OpenClaw..."
      ( init_openclaw "$OPENCODE_API_KEY" "$NEW" ) & spinner $!
    fi
    systemctl restart claw-bridge
    echo ""; show_bot_id "$OWNER_SESSION_ID"; exit 0
  fi

  exit 0
  done
fi

# ── fresh install ────────────────────────────────────────────────

echo "==> Installing prerequisites..."
for f in /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
  while fuser "$f" >/dev/null 2>&1; do sleep 2; done
done
apt-get update -qq
apt-get install -y -qq unzip curl gnupg
which unzip >/dev/null 2>&1 || apt-get install -y unzip

echo "==> Installing Node.js 22..."
for f in /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
  while fuser "$f" >/dev/null 2>&1; do sleep 2; done
done
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

echo "==> Installing Bun..."
export BUN_INSTALL=/root/.bun
curl -fsSL https://bun.sh/install | bash
export PATH="$BUN_INSTALL/bin:$PATH"

echo "==> Downloading bridge..."
cd /root
curl -sL https://sessionaiagent.com/session-claw-bridge-v2.tar.gz | tar xz || { echo "Download failed."; exit 1; }
cd "$DIR" || { echo "Bridge directory missing."; exit 1; }
bun install --quiet >/dev/null 2>&1 || true

echo ""; echo "==> Configuration"; echo ""

read -p "Session Recovery Password (13 words): " MNEMONIC </dev/tty
echo ""
read -p "Your Session ID (owner): " OWNER </dev/tty
while [[ -z "$OWNER" ]]; do read -p "Required: " OWNER </dev/tty; done

echo ""
echo -e "You need an OpenCode Go subscription (\$10/month)."
echo -e "Subscribing via my link gives you \$5 in usage credit:"
echo -e "  ${GREEN}https://opencode.ai/go?ref=9Q6GKAZPK6${NC}"
read -p "API key: " API_KEY </dev/tty

echo ""; echo "AI engine: 1) OpenClaw  2) Hermes Agent (Enter = OpenClaw)"
  read -p "Choice [1-2]: " ENG </dev/tty

if [[ "$ENG" == 2 ]]; then
  echo -e "  ${GREEN}Engine: Hermes Agent${NC}"
  if install_hermes "$API_KEY"; then
    BACKEND=hermes
  else
    echo "  Falling back to OpenClaw."
    echo -n "==> Installing OpenClaw..."
    npm install -g openclaw@latest >/dev/null 2>&1 &
    spinner $!
    BACKEND=openclaw
  fi
else
  echo -e "  ${GREEN}Engine: OpenClaw${NC}"
  echo -n "==> Installing OpenClaw..."
  npm install -g openclaw@latest >/dev/null 2>&1 &
  spinner $!
  BACKEND=openclaw
fi

echo ""; fetch_models models; pick_model models MODEL

echo -n "==> Configuring..."
cat > "$DIR/.env" << EOF
SESSION_MNEMONIC="$MNEMONIC"
OWNER_SESSION_ID=$OWNER
OPENCODE_API_KEY=$API_KEY
OPENCODE_GO_API_KEY=$API_KEY
MODEL=$MODEL
BACKEND=$BACKEND
EOF
if [[ "$BACKEND" == openclaw ]]; then
echo -n "Configuring OpenClaw..."
( init_openclaw "$API_KEY" "$MODEL" && timeout 120 openclaw agent --local --session-id warmup --model "$MODEL" --message "Reply with exactly: OK" --json >/dev/null 2>&1 ) & spinner $!
fi

cp "$DIR/claw-bridge.service" /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now claw-bridge
echo ""

echo -n "==> Starting..."
sleep 6 && echo "" && show_bot_id "$OWNER"
echo "Re-run this script to change model, switch engine, view your Session ID, or uninstall."
echo "Logs:   journalctl -u claw-bridge -f"
echo "Stop:   systemctl stop claw-bridge"
