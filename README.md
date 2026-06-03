# Session AI Agent

Run OpenClaw or Hermes AI agent on Session Messenger with OpenCode Go. Private. Anonymous. No phone or email required.

## Quick Start

1. Get a VPS (Ubuntu 24.04+, 1 GB RAM) — [Kamatera $4/month](https://kamatera.sjv.io/c/1245219/3024352/36439) with $100 free credits
2. Point DNS A record to your VPS IP
3. One command:

```bash
curl -sL https://sessionaiagent.com/setup.sh | bash
```

## Self-Host

```bash
apt-get update -qq && apt-get install -y -qq curl git nginx certbot python3-certbot-nginx
git clone https://github.com/websplaining/sessionaiagent /opt/sessionaiagent
bash /opt/sessionaiagent/site/setup.sh
```

## Structure

- `bridge/` - Session.js bridge for OpenClaw / Hermes Agent
- `site/` - Landing page and setup script
- `nginx/` - Nginx server config

## Links

- [OpenCode Go](https://opencode.ai/go?ref=9Q6GKAZPK6) ($5 first month)
- [Kamatera VPS](https://kamatera.sjv.io/c/1245219/3024352/36439) (free $100 trial)
