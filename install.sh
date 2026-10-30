#!/usr/bin/env bash
# Installs the bot on a server that already runs AmneziaWG (awg0).
#
#   sudo bash install.sh                       # interactive: asks for everything
#   sudo ENDPOINT=1.2.3.4:443 ADMIN_IDS=123 bash install.sh
#                                              # non-interactive; add the token afterwards with
#                                              #   sudo awg-bot-set-token
#
# BOT_TOKEN may also be passed in the environment, but prefer the hidden prompt.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/amnezia/amneziawg/awg0.conf
[ -f "$CONF" ] || { echo "$CONF not found - is AmneziaWG set up?"; exit 1; }
command -v awg >/dev/null || { echo "awg not found"; exit 1; }

apt-get install -y -qq python3-venv >/dev/null

id awgbot >/dev/null 2>&1 || useradd --system --home /opt/awg-bot --shell /usr/sbin/nologin awgbot
mkdir -p /opt/awg-bot /etc/awg-bot
install -m 0644 "$HERE/bot/bot.py" /opt/awg-bot/bot.py
install -m 0644 "$HERE/bot/requirements.txt" /opt/awg-bot/requirements.txt
install -m 0750 "$HERE/server/awg-peerctl" /usr/local/sbin/awg-peerctl
install -m 0750 "$HERE/server/awg-bot-set-token" /usr/local/sbin/awg-bot-set-token

python3 -m venv /opt/awg-bot/venv
/opt/awg-bot/venv/bin/pip install -q -r /opt/awg-bot/requirements.txt
chown -R awgbot:awgbot /opt/awg-bot

# Only the helper may be run as root, and only by the bot user.
echo 'awgbot ALL=(root) NOPASSWD: /usr/local/sbin/awg-peerctl' > /etc/sudoers.d/awg-bot
chmod 0440 /etc/sudoers.d/awg-bot
visudo -cf /etc/sudoers.d/awg-bot >/dev/null

PORT="$(awk -F= '/^ *ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "$CONF")"
GUESS="$(curl -s --max-time 5 https://api.ipify.org || true)"

if [ -z "${ENDPOINT:-}" ]; then
  [ -t 0 ] || { echo "Set ENDPOINT=host:port or run in an interactive shell"; exit 1; }
  read -rp "Public server address for client profiles [${GUESS}:${PORT}]: " ENDPOINT
  ENDPOINT="${ENDPOINT:-${GUESS}:${PORT}}"
fi
if [ -z "${ADMIN_IDS:-}" ]; then
  [ -t 0 ] || { echo "Set ADMIN_IDS=id1,id2 or run in an interactive shell"; exit 1; }
  read -rp "Allowed Telegram user IDs (comma separated): " ADMIN_IDS
fi
if [ -z "${BOT_TOKEN:-}" ] && [ -t 0 ]; then
  read -rsp "Bot token from @BotFather (input hidden, Enter to add it later): " BOT_TOKEN; echo
fi

# Keep a token saved by an earlier run if none was given this time.
if [ -z "${BOT_TOKEN:-}" ] && [ -f /etc/awg-bot/bot.env ]; then
  BOT_TOKEN="$(sed -n 's/^BOT_TOKEN=//p' /etc/awg-bot/bot.env)"
fi

printf 'ENDPOINT=%s\n' "$ENDPOINT" > /etc/awg-bot/settings.env
chmod 0600 /etc/awg-bot/settings.env

umask 077
printf 'BOT_TOKEN=%s\nADMIN_IDS=%s\n' "${BOT_TOKEN:-}" "$ADMIN_IDS" > /etc/awg-bot/bot.env
chown root:awgbot /etc/awg-bot/bot.env
chmod 0640 /etc/awg-bot/bot.env

install -m 0644 "$HERE/deploy/awg-bot.service" /etc/systemd/system/awg-bot.service
systemctl daemon-reload
systemctl enable awg-bot >/dev/null 2>&1

if [ -n "${BOT_TOKEN:-}" ]; then
  unset BOT_TOKEN
  systemctl restart awg-bot
  sleep 2
  systemctl --no-pager --lines=5 status awg-bot || true
  echo "Done. Send /start to your bot in Telegram."
else
  echo "Installed. The bot is not started yet: add the token with"
  echo "  sudo awg-bot-set-token"
fi
