#!/usr/bin/env bash
set -Eeuo pipefail

# Вспомогательные функции для Telegram API без внешних зависимостей (jq не нужен)
_tg_api() {
  # _tg_api <method> <data_as_x_www_form_urlencoded>
  # Возвращает: печатает JSON-ответ, код возврата curl прокидывает наружу
  local method="$1"; shift || true
  local data="$*"
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}" \
       -H 'Content-Type: application/x-www-form-urlencoded' \
       --data "$data"
}

_tg_ok() {
  # Читает JSON из stdin, возвращает 0 если "ok": true
  grep -q '"ok":\s*true' 2>/dev/null
}

_tg_extract_chat_id() {
  # На вход подаётся JSON getUpdates; пытаемся вытащить chat.id (включая отрицательные для супергрупп/каналов)
  # Возвращает найденный id через stdout, 0 если нашли, 1 если нет
  local id
  id="$(grep -oE '"chat"\s*:\s*\{\s*"id"\s*:\s*-?[0-9]+' | tail -n1 | grep -oE '-?[0-9]+')" || true
  [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
  return 1
}

setup_reboot_notify_telegram(){
  info "Настраиваю Telegram-уведомления о необходимости перезагрузки…"
  read -rp "Включить Telegram-уведомления? [y/N]: " TG_CHOICE
  [[ "${TG_CHOICE,,}" == "y" ]] || { info "Telegram-уведомления пропущены."; return 0; }

  # 1) Токен бота
  read -rp "Укажи Telegram BOT TOKEN (например, 123456:ABC...): " TG_BOT_TOKEN
  if [[ -z "${TG_BOT_TOKEN:-}" ]]; then
    error "BOT TOKEN пуст. Прерываю настройку Telegram."; return 1
  fi

  # 2) Получить chat_id: вручную или авто-detect
  echo "Укажи chat_id (например, 123456789 или -100xxxxxxxxxx)."
  echo "Оставь ПУСТО — попробую автоопределить (нужно написать /start боту в Telegram)."
  read -rp "chat_id: " TG_CHAT_ID

  if [[ -z "${TG_CHAT_ID:-}" ]]; then
    warn "Автоопределение chat_id: открой Telegram и отправь боту сообщение (/start). Жду до 60 секунд…"
    local got=0 resp=''
    # три длинных лонг-пулинга по 20 секунд
    for _ in 1 2 3; do
      resp="$(_tg_api "getUpdates" "timeout=20")" || resp=""
      if echo "$resp" | grep -q '"error_code":\s*409'; then
        warn "Бот использует webhook → getUpdates недоступен. Введи chat_id вручную."
        break
      fi
      if echo "$resp" | _tg_ok; then
        if cid="$(_tg_extract_chat_id <<<"$resp")"; then
          TG_CHAT_ID="$cid"; got=1; break
        fi
      fi
    done
    if [[ $got -ne 1 ]]; then
      read -rp "Не удалось определить chat_id автоматически. Введи chat_id вручную: " TG_CHAT_ID
      [[ -n "${TG_CHAT_ID:-}" ]] || { error "chat_id по-прежнему пуст. Прерываю настройку Telegram."; return 1; }
    else
      info "Определён chat_id: ${TG_CHAT_ID}"
    fi
  fi

  # 3) Сохранить конфиг
  cat >/etc/secure-bootstrap.conf <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 /etc/secure-bootstrap.conf

  # 4) Утилита отправки произвольных сообщений (можно использовать потом для тестов)
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

  # 5) Скрипт уведомления о необходимости перезагрузки (как раньше)
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

  # 7) ТЕСТОВОЕ СООБЩЕНИЕ
  local host msg resp
  host="$(hostname -f 2>/dev/null || hostname)"
  msg="✅ Тестовое сообщение: бот подключен на ${host} ($(date -u +'%Y-%m-%d %H:%M:%S UTC'))"
  resp="$(_tg_api "sendMessage" "chat_id=${TG_CHAT_ID}&text=$(printf '%s' "$msg" | sed 's/[&]/\\&/g')")" || resp=""
  if echo "$resp" | _tg_ok; then
    info "Тестовое сообщение отправлено в Telegram (chat_id=${TG_CHAT_ID}). Проверь чат."
    # отметка-верификация (для возможных отчётов)
    install -d -m 755 /var/lib/reboot-notify-telegram
    : > /var/lib/reboot-notify-telegram/verified
  else
    warn "Не удалось отправить тестовое сообщение. Ответ API:"
    echo "$resp" | sed -n '1,200p'
    warn "Проверь BOT TOKEN и chat_id. Можешь повторить настройку, запустив скрипт снова."
  fi
}
