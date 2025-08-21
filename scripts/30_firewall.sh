#!/usr/bin/env bash
set -Eeuo pipefail
configure_ufw(){
  info "Настраиваю UFW..."
  [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw limit ${SSH_PORT}/tcp
  ufw limit 22/tcp        # оставляем временно для безопасной перекладки
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
  systemctl enable fail2ban
  systemctl restart fail2ban
  fail2ban-client status sshd || true
}
