#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# -------------------------

# Мини-обёртка над Telegram Bot API (x-www-form-urlencoded)
_tg_api() {
  # _tg_api <method> <data_as_x_www_form_urlencoded>
  # Печатает JSON-ответ; код возврата curl прокидывает наружу
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

# Достаём chat.id из JSON getUpdates (message/edited_message/channel_post/my_chat_member)
_tg_extract_chat_id() {
  # читает JSON из stdin, пытается найти "chat":{"id":...} в разных типах событий
  grep -oE '"(message|edited_message|channel_post|my_chat_member)"[[:space:]]*:[[:space:]]*\{[^}]*"chat"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-?[0-9]+' \
    | tail -n1 \
    | grep -oE '-?[0-9]+' \
    || return 1
}

# Берём последний update_id из JSON
_tg_last_update_id() {
  grep -oE '"update_id"[[:space:]]*:[[:space:]]*[0-9]+' | tail -n1 | grep -oE '[0-9]+' || true
}

# Красивые сообщения
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

  # 2) chat_id: ручной ввод или автоопределение
  echo "Укажи chat_id (например, 123456789 или -100xxxxxxxxxx)."
  echo "Оставь ПУСТО — попробую автоопределить (отправь боту /start или любое сообщение)."
  read -rp "chat_id: " TG_CHAT_ID

  if [[ -z "${TG_CHAT_ID:-}" ]]; then
    warn "Автоопределение chat_id: открой Telegram и напиши боту. Жду до 60 секунд…"

    # 2.1) Проверим, не включён ли webhook (409 — конфликт)
    local resp last_id deadline upd_id cid
    resp="$(_tg_api "getUpdates" "timeout=0")" || resp=""
    if echo "$resp" | grep -q '"error_code"[[:space:]]*:[[:space:]]*409'; then
      warn "Обнаружен webhook (409). getUpdates недоступен. Введи chat_id вручную либо отключи webhook:
      curl -sS \"https://api.telegram.org/bot${TG_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true\""
    else
      # 2.2) Очистим старые апдейты, чтобы ждать ТОЛЬКО новые
      last_id="$(_tg_last_update_id <<<"$resp")"
      if [[ -n "$last_id" ]]; then
        _tg_api "getUpdates" "offset=$((last_id+1))&timeout=0" >/dev/null 2>&1 || true
      fi

      # 2.3) Длинный опрос: до 60 сек, каждые ~15 сек
      deadline=$((SECONDS + 60))
      while (( SECONDS < deadline )); do
        resp="$(_tg_api "getUpdates" "timeout=15")" || resp=""
        if echo "$resp" | _tg_ok; then
          if cid="$(_tg_extract_chat_id <<<"$resp")"; then
            TG_CHAT_ID="$cid"
            info "Определён chat_id: ${TG_CHAT_ID}"
            break
          fi
          # сдвигаем offset, чтобы не крутиться на одних и тех же апдейтах
          upd_id="$(_tg_last_update_id <<<"$resp")"
          [[ -n "$upd_id" ]] && _tg_api "getUpdates" "offset=$((upd_id+1))&timeout=0" >/dev/null 2>&1 || true
        fi
      done
    fi

    if [[ -z "${TG_CHAT_ID:-}" ]]; then
      read -rp "Не удалось определить chat_id автоматически. Введи chat_id вручную: " TG_CHAT_ID
      [[ -n "${TG_CHAT_ID:-}" ]] || { error "chat_id по-прежнему пуст. Прерываю настройку Telegram."; return 1; }
    fi
  fi

  # 3) Сохранить конфиг
  cat >/etc/secure-bootstrap.conf <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 /etc/secure-bootstrap.conf

  # 4) Утилита tg-send для произвольных сообщений (годится для ручных тестов)
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

  # 5) Скрипт: уведомление о необходимости перезагрузки
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

  # 6) systemd units (watcher на /var/run/reboot-required)
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

  # 7) ТЕСТОВОЕ СООБЩЕНИЕ (всегда URL-кодируем поля!)
  local host msg resp
  host="$(hostname -f 2>/dev/null || hostname)"
  msg="✅ Тестовое сообщение: бот подключен на ${host} ($(date -u +'%Y-%m-%d %H:%M:%S UTC'))"

  resp="$(
    curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${msg}"
  )" || resp=""

  if echo "$resp" | _tg_ok; then
    info "Тестовое сообщение отправлено в Telegram (chat_id=${TG_CHAT_ID}). Проверь чат."
    install -d -m 755 /var/lib/reboot-notify-telegram
    : > /var/lib/reboot-notify-telegram/verified
  else
    warn "Не удалось отправить тестовое сообщение. Ответ API:"
    echo "$resp" | sed -n '1,200p'
    warn "Проверь BOT TOKEN и chat_id. При необходимости повтори настройку."
  fi
}

# Если скрипт запускают напрямую — выполняем настройку
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  setup_reboot_notify_telegram
fi
