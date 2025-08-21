#!/usr/bin/env bash
set -Eeuo pipefail
harden_ssh(){
  info "Ужесточаю SSH и включаю новый порт без обрыва сессии..."
  mkdir -p /etc/ssh/sshd_config.d
  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf

  # Стадия: 22 + новый порт, пароли временно ON (чтобы не запереть себя)
  {
    echo "Port 22"
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    echo "PasswordAuthentication yes"
    echo "PermitRootLogin prohibit-password"
    echo "KbdInteractiveAuthentication no"
    echo "ChallengeResponseAuthentication no"
    echo "MaxAuthTries 3"
    echo "UsePAM yes"
  } > "$F_STAGE"

  sshd -t || { error "Конфиг sshd (стадия) некорректен"; rm -f "$F_STAGE"; exit 1; }
  systemctl reload ssh || { error "reload ssh не удался (restart НЕ выполняю)"; rm -f "$F_STAGE"; exit 1; }

  sleep 1
  ss -tnlp | grep -q ":${SSH_PORT} " || { error "Порт ${SSH_PORT} не слушается"; rm -f "$F_STAGE"; systemctl reload ssh || true; exit 1; }
  info "Порт ${SSH_PORT} поднят, 22-й оставлен временно."

  # Финальный конфиг: только новый порт; пароли — если ключа нет
  {
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    if [[ ${HAS_KEY:-0} -eq 1 ]]; then
      echo "PasswordAuthentication no"
    else
      echo "PasswordAuthentication yes"
    fi
    echo "PermitRootLogin no"
    echo "KbdInteractiveAuthentication no"
    echo "ChallengeResponseAuthentication no"
    echo "MaxAuthTries 3"
    echo "UsePAM yes"
  } > "$F_FINAL"

  sshd -t || { error "Конфиг sshd (финал) некорректен"; exit 1; }
  systemctl reload ssh || { error "reload ssh не удался"; exit 1; }

  # Предложим закрыть 22 в UFW и убрать staging
  if [[ ${SSH_PORT} -ne 22 ]]; then
    echo
    warn "SSH уже переключён на порт ${SSH_PORT}. 22-й пока открыт в UFW."
    read -rp "Проверили вход по новому порту? Закрыть 22 сейчас? [y/N]: " CLOSE22
    if [[ "${CLOSE22,,}" == "y" ]]; then
      ufw delete allow 22/tcp || true
      rm -f "$F_STAGE"
      info "Порт 22 закрыт, staging удалён."
      systemctl reload ssh || true
    else
      warn "Оставили 22 открытым. Закроете позже: ufw delete allow 22/tcp; затем rm -f $F_STAGE && systemctl reload ssh"
    fi
  fi
}
