#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# -------------------------

# Обёртка над Telegram Bot API (x-www-form-urlencoded), без jq
_tg_api() {
  local method="$1"; shift || true
  local data="${*:-}"
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}" \
       -H 'Content-Type: application/x-www-form-urlencoded' \
       --data "$data"
}

# Возвращает 0, если в stdin есть "ok": true
_tg_ok() {
  grep -q '"ok":[[:space:]]*true' 2>/dev/null
}

# Достаём chat.id из JSON getUpdates
_tg_extract_chat_id() {
  grep -oE '"(message|edited_message|channel_post|my_chat_member)"[[:space:]]*:[[:space:]]*\{[^}]*"chat"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-?[0-9]+' \
    | tail -n1 \
    | grep -oE -- '-?[0-9]+' \
    || return 1
}

# Берём последний update_id из JSON
_tg_last_update_id() {
  grep -oE '"update_id"[[:space:]]*:[[:space:]]*[0-9]+' \
    | tail -n1 \
    | grep -oE -- '[0-9]+' \
    || true
}

# Цветные сообщения
info(){ echo -e "\e[32m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

# ---------------------------------------
# ОСНОВНАЯ НАСТРОЙКА TELEGRAM-УВЕДОМЛЕНИЙ
# ---------------------------------------
setup_reboot_notify_telegram() {
  info "Настраиваю Telegram-уведомления о необходимости перезагрузки…"
  read -rp "Включить Telegram-уведомления? [y/N]: " TG_CHOICE
  [[ "${TG_CHOICE,,}" == "y" ]] || { info "Telegram-уведомления пропущены."; return 0; }

  # 1) Токен бота
  read -rp "Укажи Telegram BOT TOKEN (например, 123456:ABC...): " TG_BOT_TOKEN
  if [[ -z "${TG_BOT_TOKEN:-}" ]]; then
    error "BOT TOKEN пуст. Прерываю настройку Telegram."; return 1
  fi

  # 2) Попробуем автоматически определить chat_id
  local resp
  resp="$(_tg_api "getUpdates" "timeout=0")" || resp=""
  TG_CHAT_ID="$(_tg_extract_chat_id <<<"$resp" || true)"

  if [[ -n "${TG_CHAT_ID:-}" ]]; then
    info "Автоматически определён chat_id: ${TG_CHAT_ID}"
  else
    warn "Не удалось автоматически найти chat_id. Убедись, что написал боту сообщение."
    echo "Укажи chat_id (например, 123456789 или -100xxxxxxxxxx)."
    read -rp "chat_id: " TG_CHAT_ID
    [[ -n "${TG_CHAT_ID:-}" ]] || { error "chat_id пуст. Прерываю настройку."; return 1; }
  fi

  # 3) Сохранить конфиг
  cat >/etc/secure-bootstrap.conf <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 /etc/secure-bootstrap.conf

  # 4) Утилита tg-send для ручных тестов
  cat >/usr/local/sbin/tg-send <<'EOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/secure-bootstrap.conf
TEXT="${*:-🔎 test}"
curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     --data-urlencode "chat_id=${TG_CHAT_ID}" \
     --data-urlencode "text=${TEXT}"
EOT
  chmod +x /usr/local/sbin/tg-send

  # 5) Скрипт уведомления о необходимости перезагрузки
  cat >/usr/local/sbin/reboot-notify-telegram <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/secure-bootstrap.conf
STAMP_DIR=/var/lib/reboot-notify-telegram
mkdir -p "$STAMP_DIR"

if [[ -f /var/run/reboot-required ]]; then
  HOST=$(hostname -f 2>/dev/null || hostname)
  PKG_COUNT=$(wc -l </var/run/reboot-required.pkgs 2>/dev/null || echo 0)
  TEXT="⚠️ Сервер ${HOST}: требуется перезагрузка после обновлений. Пакетов: ${PKG_COUNT}.
Команда для админа: sudo reboot (в удобное время)."
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
       -H 'Content-Type: application/x-www-form-urlencoded' \
       --data-urlencode "chat_id=${TG_CHAT_ID}" \
       --data-urlencode "text=${TEXT}" >/dev/null || true
fi
EOS
  chmod +x /usr/local/sbin/reboot-notify-telegram

  # 6) systemd units
  cat >/etc/systemd/system/reboot-notify.service <<'EOS'
[Unit]
Description=Notify via Telegram when reboot is required

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reboot-notify-telegram
EOS

  cat >/etc/systemd/system/reboot-notify.path <<'EOS'
[Unit]
Description=Watch /var/run/reboot-required and trigger telegram notify

[Path]
PathExists=/var/run/reboot-required

[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload
  systemctl enable --now reboot-notify.path

  # 7) Тестовое сообщение
  local host msg resp2
  host="$(hostname -f 2>/dev/null || hostname)"
  msg="✅ Тестовое сообщение: бот подключен на ${host} ($(date -u +'%Y-%m-%d %H:%M:%S UTC'))"

  resp2="$(
    curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${msg}"
  )" || resp2=""

  if echo "$resp2" | _tg_ok; then
    info "Тестовое сообщение отправлено в Telegram (chat_id=${TG_CHAT_ID}). Проверь чат."
    install -d -m 755 /var/lib/reboot-notify-telegram
    : > /var/lib/reboot-notify-telegram/verified
  else
    warn "Не удалось отправить тестовое сообщение. Ответ API:"
    echo "$resp2" | sed -n '1,200p'
    warn "Проверь BOT TOKEN и chat_id."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  setup_reboot_notify_telegram
fi
