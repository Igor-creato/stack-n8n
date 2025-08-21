#!/usr/bin/env bash
set -Eeuo pipefail

configure_ufw(){
  info "Настраиваю UFW..."
  [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw

  ufw default deny incoming
  ufw default allow outgoing

  # Веб-порты
  ufw allow 80/tcp
  ufw allow 443/tcp

  # На этапе перекладки открываем ОДНОВРЕМЕННО новый порт и 22 (временно)
  ufw limit ${SSH_PORT}/tcp
  ufw limit 22/tcp

  ufw logging low
  yes | ufw enable || true
  ufw status verbose
}

configure_fail2ban(){
  info "Настраиваю Fail2ban..."
  cat >/etc/fail2ban/jail.local <<E
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
banaction = ufw
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${SSH_PORT}
logpath = %(sshd_log)s
E

  systemctl daemon-reload || true
  systemctl enable --now fail2ban

  # Ждём появления сокета fail2ban (до ~10 сек)
  ok=0
  for i in {1..20}; do
    if systemctl is-active --quiet fail2ban && [[ -S /var/run/fail2ban/fail2ban.sock ]]; then
      ok=1; break
    fi
    sleep 0.5
  done
  if [[ $ok -ne 1 ]]; then
    warn "fail2ban не активен, последние логи:"
    journalctl -u fail2ban -n 50 --no-pager || true
    error "Не удалось запустить fail2ban (сокет не появился)."
    exit 1
  fi

  # Инфо-статус (не критично)
  fail2ban-client status sshd || true
}
