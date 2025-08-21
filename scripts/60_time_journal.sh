#!/usr/bin/env bash
set -Eeuo pipefail
enable_time_sync(){
  info "Включаю синхронизацию времени..."
  timedatectl set-ntp true
  systemctl enable systemd-timesyncd.service || true
  systemctl start systemd-timesyncd.service || true
  timedatectl
}
persist_journal(){
  info "Делаю журналы systemd персистентными..."
  install -d -m 755 /var/log/journal
  sed -i 's/^#*Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
  systemd-tmpfiles --create --prefix /var/log/journal || true
  systemctl restart systemd-journald
}
