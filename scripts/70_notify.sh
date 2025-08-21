#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# -------------------------

# Обёртка над Telegram Bot API (x-www-form-urlencoded), без jq
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

# Достаём chat.id из JSON getUpdates (находим любой блок "chat":{"id":...})
_tg_extract_chat_id() {
  grep -oE '"chat"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-?[0-9]+' \
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

  # 2) Проверка webhook
  local wh resp last_id deadline upd_id cid
  wh="$(
    curl -fsS -m 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/getWebhookInfo" 2>/dev/null || true
  )"
  if echo "$wh" | grep -q '"url"[[:space:]]*:[[:space:]]*"http'; then
    warn "Похоже, у бота включён webhook — long polling (getUpdates) не работает."
    read -rp "Отключить webhook автоматически (deleteWebhook + drop_pending_updates)? [Y/n]: " ans
    ans="${ans:-Y}"
    if [[ "${ans,,}" != "n" ]]; then
      curl -fsS -m 20 "https://api.telegram.org/bot${TG_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" >/dev/null || true
      info "Webhook отключён и очередь очищена."
    else
      warn "Оставили webhook включённым — автоопределение chat_id может не сработать."
    fi
  fi

  # 3) chat_id: автоопределение через getUpdates с очисткой очереди и длинным опросом
  warn "Автоопределение chat_id: открой Telegram и напиши сообщение боту (например /start). Жду до 60 секунд…"

  resp="$(_tg_api "getUpdates" "timeout=0")" || resp=""

  # Если прямо сейчас в ответе есть chat_id — используем его
  if cid="$(_tg_extract_chat_id <<<"$resp")"; then
    TG_CHAT_ID="$cid"
    info "Найден chat_id из текущих апдейтов: ${TG_CHAT_ID}"
  else
    # Очистим старые апдейты, чтобы ждать ТОЛЬКО новые
    last_id="$(_tg_last_update_id <<<"$resp")"
    if [[ -n "$last_id" ]]; then
      _tg_api "getUpdates" "offset=$((last_id+1))&timeout=0" >/dev/null 2>&1 || true
    fi

    # Длинный опрос: до 60 сек
    deadline=$((SECONDS + 60))
    while (( SECONDS < deadline )); do
      resp="$(_tg_api "getUpdates" "timeout=15")" || resp=""
      if echo "$resp" | _tg_ok; then
        if cid="$(_tg_extract_chat_id <<<"$resp")"; then
          TG_CHAT_ID="$cid"
          info "Определён chat_id: ${TG_CHAT_ID}"
          # Сдвинем offset, чтобы не крутиться на одних и тех же апдейтах
          upd_id="$(_tg_last_update_id <<<"$resp")"
          [[ -n "$upd_id" ]] && _tg_api "getUpdates" "offset=$((upd_id+1))&timeout=0" >/dev/null 2>&1 || true
          break
        fi
        upd_id="$(_tg_last_update_id <<<"$resp")"
        [[ -n "$upd_id" ]] && _tg_api "getUpdates" "offset=$((upd_id+1))&timeout=0" >/dev/null 2>&1 || true
      fi
    done
  fi

  # 4) Если всё ещё пусто — даём шанс оставить пустым и попробуем ещё 30с
  if [[ -z "${TG_CHAT_ID:-}" ]]; then
    warn "Не удалось автоматически найти chat_id."
    echo "Можно ввести chat_id вручную (например, 874949157 или -100xxxxxxxxxx)."
    read -rp "chat_id (или оставь пустым — попробуем подождать 30с): " TG_CHAT_ID
    if [[ -z "${TG_CHAT_ID:-}" ]]; then
      warn "Ок, ещё 30 секунд на сообщение боту… Напиши ему сейчас."
      deadline=$((SECONDS + 30))
      while (( SECONDS < deadline )); do
        resp="$(_tg_api "getUpdates" "timeout=10")" || resp=""
        if echo "$resp" | _tg_ok; then
          if cid="$(_tg_extract_chat_id <<<"$resp")"; then
            TG_CHAT_ID="$cid"
            info "Определён chat_id: ${TG_CHAT_ID}"
            upd_id="$(_tg_last_update_id <<<"$resp")"
            [[ -n "$upd_id" ]] && _tg_api "getUpdates" "offset=$((upd_id+1))&timeout=0" >/dev/null 2>&1 || true
            break
          fi
        fi
      done
    fi
  fi

  if [[ -z "${TG_CHAT_ID:-}" ]]; then
    error "chat_id по-прежнему пуст. Прерываю настройку Telegram."
    return 1
  fi

  # 5) Сохранить конфиг
  cat >/etc/secure-bootstrap.conf <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 /etc/secure-bootstrap.conf

  # 6) Утилита tg-send для ручных тестов
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

  # 7) Скрипт: уведомление о необходимости перезагрузки
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

  # 8) systemd units (watcher на /var/run/reboot-required)
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

  # 9) Тестовое сообщение (всегда URL-кодируем поля)
  local host msg resp_test
  host="$(hostname -f 2>/dev/null || hostname)"
  msg="✅ Тестовое сообщение: бот подключен на ${host} ($(date -u +'%Y-%m-%d %H:%M:%S UTC'))"

  resp_test="$(
    curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${msg}"
  )" || resp_test=""

  if echo "$resp_test" | _tg_ok; then
    info "Тестовое сообщение отправлено в Telegram (chat_id=${TG_CHAT_ID}). Проверь чат."
    install -d -m 755 /var/lib/reboot-notify-telegram
    : > /var/lib/reboot-notify-telegram/verified
  else
    warn "Не удалось отправить тестовое сообщение. Ответ API:"
    echo "$resp_test" | sed -n '1,200p'
    warn "Проверь BOT TOKEN и chat_id. При необходимости повтори настройку."
  fi
}

# Если скрипт запускают напрямую — выполняем настройку
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  setup_reboot_notify_telegram
fi
