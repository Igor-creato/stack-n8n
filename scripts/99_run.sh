#!/usr/bin/env bash
set -Eeuo pipefail

summary(){
  echo
  info "ГОТОВО. Краткий статус:"
  echo "---- UFW ----"; ufw status verbose || true
  echo "---- Fail2ban (sshd) ----"; fail2ban-client status sshd || true
  echo "---- Важные заметки ----"
  if [[ ${HAS_KEY:-0} -eq 1 ]]; then
    echo "• Вход по паролю ОТКЛЮЧЁН (есть ключ). Пользователь: $USERNAME."
  else
    echo "• Вход по паролю ОСТАВЛЕН ВКЛЮЧЁННЫМ (ключ не задан/не найден)."
  fi
  echo "• SSH-порт: ${SSH_PORT}."
  echo "• Открыто: ${SSH_PORT}/tcp (limit), 22/tcp (временно), 80/tcp, 443/tcp."
  echo "• Автообновления включены; авто-перезагрузка ОТКЛЮЧЕНА."
}

main_run(){
  require_root
  detect_ubuntu
  prompt_admin_user
  choose_ssh_port
  apt_update_upgrade
  install_packages
  configure_unattended_upgrades
  configure_ufw
  configure_fail2ban
  harden_ssh
  harden_sysctl
  enable_time_sync
  persist_journal
  setup_reboot_notify_telegram
  summary
}

