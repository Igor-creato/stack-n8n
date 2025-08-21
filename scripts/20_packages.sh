#!/usr/bin/env bash
set -Eeuo pipefail
apt_update_upgrade(){
  info "Обновляю индекс пакетов и систему..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  apt-get -y full-upgrade
  apt-get -y autoremove --purge
  apt-get -y autoclean
}
install_packages(){
  info "Устанавливаю пакеты: ufw, fail2ban, unattended-upgrades, openssh-server..."
  apt-get -y install ufw fail2ban unattended-upgrades ca-certificates curl vim openssh-server || true
}
configure_unattended_upgrades(){
  info "Включаю автоматические обновления (без авто-перезагрузки)..."
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'E'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Verbose "1";
E
  cat >/etc/apt/apt.conf.d/51unattended-upgrades-local <<'E'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
E
  systemctl enable unattended-upgrades
  systemctl restart unattended-upgrades
}
