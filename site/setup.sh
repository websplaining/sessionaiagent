#!/bin/bash

GREEN='\033[0;32m'
NC='\033[0m'
DIR=/root/session-claw-bridge
API=https://opencode.ai/zen/go/v1/models
FALLBACK=(glm-5.1 glm-5 kimi-k2.6 deepseek-v4-pro deepseek-v4-flash mimo-v2.5 minimax-m2.7 qwen3.7-max qwen3.6-plus)
DEFAULT_MODEL=opencode-go/deepseek-v4-pro

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
  read -p "Pick a number (or type model) [deepseek-v4-pro]: " p </dev/tty
  if [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le ${#list[@]} ]]; then
    outvar="opencode-go/${list[$((p-1))]}"
  elif [[ -n "$p" ]]; then outvar="$p"
  else outvar="$DEFAULT_MODEL"; fi
  echo -e "  ${GREEN}Selected: $outvar${NC}"
  echo ""
}

show_bot_id() {
  journalctl --sync 2>/dev/null || true
  sleep 6
  local id
  id=$(journalctl -u claw-bridge -n 50 --no-pager 2>/dev/null | grep -oP 'SESSION_ID \K\S+' | tail -1 || true)
  echo -e "AI Agent Session ID:  ${GREEN}${id:-check logs}${NC}"
  echo "1. Open Session, paste this ID to send a message request"
  echo "2. Only your Session ID (${1}) can message the bot"
}

init_openclaw() {
  openclaw onboard --accept-risk --non-interactive --skip-health --skip-daemon --skip-bootstrap \
    --auth-choice opencode-go --opencode-go-api-key "$1" >/dev/null 2>&1 || true
  openclaw config set agents.defaults.model.primary "$2" >/dev/null 2>&1 || true
  openclaw config set agents.defaults.models "{\"$2\":{}}" --strict-json --merge >/dev/null 2>&1 || true
}

install_hermes() {
  echo "==> Installing Hermes Agent... (this may take a few minutes)"
  apt-get install -y -qq python3-pip python3-venv 2>/dev/null || true
  pip3 install -q --break-system-packages hermes-agent 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"
  mkdir -p ~/.hermes
  echo "OPENCODE_GO_API_KEY=${1:-$API_KEY}" > ~/.hermes/.env
}

# ── manage menu ──────────────────────────────────────────────────

if [[ -f "$DIR/.env" ]]; then
  source <(grep -E '^(MODEL|BACKEND|OPENCODE_API_KEY|OWNER_SESSION_ID)=' "$DIR/.env" 2>/dev/null || true)
  echo "Already installed."
  echo -e "  Engine: ${GREEN}${BACKEND:-openclaw}${NC}"
  echo -e "  Model:  ${GREEN}${MODEL:-none}${NC}"
  echo ""
  echo "  1) Change model"
  echo "  2) Switch engine"
  echo "  3) Uninstall"
  echo ""
  read -p "Choice [1-3]: " act </dev/tty

  if [[ "$act" == 3 ]]; then
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

  if [[ "$act" == 2 ]]; then
    echo ""; echo "  1) OpenClaw   2) Hermes Agent"
    read -p "Choice [1-2]: " eng </dev/tty
    if [[ "$eng" == 2 ]]; then
      install_hermes "$OPENCODE_API_KEY"; sed -i 's|^BACKEND=.*|BACKEND=hermes|' "$DIR/.env"
      echo -e "${GREEN}Switched to Hermes.${NC}"
    else
      sed -i 's|^BACKEND=.*|BACKEND=openclaw|' "$DIR/.env"
      init_openclaw "$OPENCODE_API_KEY" "$MODEL"
      echo -e "${GREEN}Switched to OpenClaw.${NC}"
    fi
    systemctl restart claw-bridge
    echo -n "==> Restarting..."; show_bot_id "$OWNER_SESSION_ID"; exit 0
  fi

  echo ""; fetch_models models; pick_model models NEW
  echo -n "==> Applying..."
  sed -i "s|^MODEL=.*|MODEL=$NEW|" "$DIR/.env"
  [[ "${BACKEND:-openclaw}" == openclaw ]] && init_openclaw "$OPENCODE_API_KEY" "$NEW"
  systemctl restart claw-bridge
  echo ""; show_bot_id "$OWNER_SESSION_ID"; exit 0
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
curl -sL https://sessionaiagent.com/session-claw-bridge.tar.gz | tar xz
cd "$DIR" && bun install --quiet >/dev/null 2>&1

echo ""; echo "==> Configuration"; echo ""

read -p "Session Recovery Password (13 words): " MNEMONIC </dev/tty
echo ""
read -p "Your Session ID (owner): " OWNER </dev/tty
while [[ -z "$OWNER" ]]; do read -p "Required: " OWNER </dev/tty; done

echo ""
PRICE=$(curl -sf --max-time 5 "https://opencode.ai/go" 2>/dev/null | grep -oP '\$\d+ for your first month, then \$\d+/month' | head -1 || true)
echo -e "You need an OpenCode Go subscription."
echo -e "${PRICE:-\$5 first month, then \$10/month} - use my link:"
echo -e "  ${GREEN}https://opencode.ai/go?ref=9Q6GKAZPK6${NC}"
read -p "API key: " API_KEY </dev/tty

echo ""; echo "AI engine: 1) OpenClaw  2) Hermes Agent"
  read -p "Choice [1-2]: " ENG </dev/tty

if [[ "$ENG" == 2 ]]; then
  echo -e "  ${GREEN}Engine: Hermes Agent${NC}"
  install_hermes "$API_KEY"; BACKEND=hermes
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
[[ "$BACKEND" == openclaw ]] && init_openclaw "$API_KEY" "$MODEL"

cp "$DIR/claw-bridge.service" /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now claw-bridge
echo ""

echo -n "==> Starting..."
sleep 6 && echo "" && show_bot_id "$OWNER"
echo "Re-run this script to change model, switch engine, or uninstall."
echo "Logs:   journalctl -u claw-bridge -f"
echo "Stop:   systemctl stop claw-bridge"
