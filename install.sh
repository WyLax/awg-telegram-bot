#!/usr/bin/env bash
# Installs the bot on a server that already runs AmneziaWG (awg0).
# Run as root in an interactive shell:  bash install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
[ -t 0 ] || { echo "Run this in an interactive shell (it asks for the bot token)"; exit 1; }

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

python3 -m venv /opt/awg-bot/venv
/opt/awg-bot/venv/bin/pip install -q -r /opt/awg-bot/requirements.txt
chown -R awgbot:awgbot /opt/awg-bot

# Only the helper may be run as root, and only by the bot user.
echo 'awgbot ALL=(root) NOPASSWD: /usr/local/sbin/awg-peerctl' > /etc/sudoers.d/awg-bot
chmod 0440 /etc/sudoers.d/awg-bot
visudo -cf /etc/sudoers.d/awg-bot >/dev/null

PORT="$(awk -F= '/^ *ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "$CONF")"
GUESS="$(curl -s --max-time 5 https://api.ipify.org || true)"
read -rp "Public server address for client profiles [${GUESS}:${PORT}]: " ENDPOINT
ENDPOINT="${ENDPOINT:-${GUESS}:${PORT}}"
read -rp "Allowed Telegram user IDs (comma separated): " ADMIN_IDS
read -rsp "Bot token from @BotFather (input is hidden): " BOT_TOKEN; echo

printf 'ENDPOINT=%s\n' "$ENDPOINT" > /etc/awg-bot/settings.env
chmod 0600 /etc/awg-bot/settings.env

umask 077
printf 'BOT_TOKEN=%s\nADMIN_IDS=%s\n' "$BOT_TOKEN" "$ADMIN_IDS" > /etc/awg-bot/bot.env
chown root:awgbot /etc/awg-bot/bot.env
chmod 0640 /etc/awg-bot/bot.env
unset BOT_TOKEN

install -m 0644 "$HERE/deploy/awg-bot.service" /etc/systemd/system/awg-bot.service
systemctl daemon-reload
systemctl enable --now awg-bot
sleep 2
systemctl --no-pager --lines=5 status awg-bot || true
echo "Done. Send /start to your bot in Telegram."
