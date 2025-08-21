#!/usr/bin/env bash
set -Eeuo pipefail
setup_reboot_notify_telegram(){
  info "Настраиваю Telegram-уведомления о необходимости перезагрузки (по желанию)..."
  read -rp "Включить Telegram-уведомления при требуемой перезагрузке? [y/N]: " TG_CHOICE
  [[ "${TG_CHOICE,,}" == "y" ]] || { info "Пропущено."; return 0; }

  read -rp "BOT TOKEN (123456:ABC...): " TG_BOT_TOKEN
  read -rp "chat_id (число или @username, лучше числовой): " TG_CHAT_ID

  cat >/etc/secure-bootstrap.conf <<E
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
E
  chmod 600 /etc/secure-bootstrap.conf

  cat >/usr/local/sbin/reboot-notify-telegram <<'E'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/secure-bootstrap.conf
if [[ -f /var/run/reboot-required ]]; then
  HOST=$(hostname -f 2>/dev/null || hostname)
  PKG_COUNT=$(wc -l </var/run/reboot-required.pkgs 2>/dev/null || echo 0)
  TEXT="⚠️ Сервер ${HOST}: требуется перезагрузка после обновлений. Пакетов: ${PKG_COUNT}.
Команда: sudo reboot (в удобное время)."
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
       -d chat_id="${TG_CHAT_ID}" -d text="${TEXT}" >/dev/null || true
fi
E
  chmod +x /usr/local/sbin/reboot-notify-telegram

  cat >/etc/systemd/system/reboot-notify.service <<'E'
[Unit]
Description=Notify via Telegram when reboot is required
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reboot-notify-telegram
E

  cat >/etc/systemd/system/reboot-notify.path <<'E'
[Unit]
Description=Watch /var/run/reboot-required and trigger telegram notify
[Path]
PathExists=/var/run/reboot-required
[Install]
WantedBy=multi-user.target
E

  systemctl daemon-reload
  systemctl enable --now reboot-notify.path
  [[ -f /var/run/reboot-required ]] && systemctl start reboot-notify.service || true
}
