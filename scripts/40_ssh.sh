#!/usr/bin/env bash
set -Eeuo pipefail

harden_ssh(){
  info "Ужесточаю SSH и включаю новый порт без обрыва сессии..."
  mkdir -p /etc/ssh/sshd_config.d

  local MAIN=/etc/ssh/sshd_config
  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf

  # Подключим include на случай отсутствия
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$MAIN"; then
    cp "$MAIN" "${MAIN}.bak.$(date +%Y%m%d-%H%M%S)" || true
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN"
    info "Добавил 'Include /etc/ssh/sshd_config.d/*.conf' в $MAIN"
  fi

  # Проверка слушателя
  _listens() { ss -H -tlpn 2>/dev/null | awk -v pat=":${1}$" '$4 ~ pat {f=1} END{exit f?0:1}'; }

  # === Режим socket-активации ===
  if systemctl is-enabled --quiet ssh.socket || systemctl is-active --quiet ssh.socket; then
    info "Обнаружена socket-активация (ssh.socket). Переключаю порты в сокете."
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:22
ListenStream=[::]:22
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket

    # Ждём появления нового порта
    local ok=0; for i in {1..20}; do _listens "${SSH_PORT}" && { ok=1; break; }; sleep 0.5; done
    [[ $ok -eq 1 ]] || { error "Новый порт ${SSH_PORT} не слушается (socket)"; systemctl cat ssh.socket || true; ss -ltnp | sed -n '1,200p'; exit 1; }
    info "Порт ${SSH_PORT} поднят через ssh.socket. 22-й оставлен временно."

    # Жёсткие настройки SSH (Port игнорируется при socket-активации)
    {
      echo "PubkeyAuthentication yes"
      if [[ ${HAS_KEY:-0} -eq 1 ]]; then echo "PasswordAuthentication no"; else echo "PasswordAuthentication yes"; fi
      echo "PermitRootLogin no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
      echo "MaxAuthTries 3"
      echo "UsePAM yes"
    } > "$F_FINAL"
    sshd -t || { error "Конфиг sshd некорректен"; exit 1; }
    systemctl reload ssh.service || true

    # Предложить убрать 22
    if [[ ${SSH_PORT} -ne 22 ]]; then
      read -rp "Проверили вход по новому порту? Убрать 22 из ssh.socket и UFW сейчас? [y/N]: " CLOSE22
      if [[ "${CLOSE22,,}" == "y" ]]; then
        cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket
        ufw delete allow 22/tcp || true
        info "22 удалён из ssh.socket и закрыт в UFW."
      fi
    fi
    return 0
  fi

  # === Классический режим (без socket) ===
  info "Socket-активация не активна. Настраиваю порты через sshd_config.d …"
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
  systemctl reload ssh || systemctl restart ssh

  local ok=0; for i in {1..20}; do _listens "${SSH_PORT}" && { ok=1; break; }; sleep 0.5; done
  [[ $ok -eq 1 ]] || { error "Новый порт ${SSH_PORT} не слушается"; ss -ltnp | sed -n '1,200p'; grep -Hn '^[Pp]ort[[:space:]]' "$MAIN" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true; exit 1; }
  info "Порт ${SSH_PORT} поднят, 22-й оставлен временно."

  {
    echo "Port ${SSH_PORT}"
    echo "PubkeyAuthentication yes"
    if [[ ${HAS_KEY:-0} -eq 1 ]]; then echo "PasswordAuthentication no"; else echo "PasswordAuthentication yes"; fi
    echo "PermitRootLogin no"
    echo "KbdInteractiveAuthentication no"
    echo "ChallengeResponseAuthentication no"
    echo "MaxAuthTries 3"
    echo "UsePAM yes"
  } > "$F_FINAL"

  sshd -t || { error "Конфиг sshd (финал) некорректен"; exit 1; }
  systemctl reload ssh || true

  if [[ ${SSH_PORT} -ne 22 ]]; then
    read -rp "Проверили вход по новому порту? Закрыть 22 сейчас? [y/N]: " CLOSE22
    if [[ "${CLOSE22,,}" == "y" ]]; then
      ufw delete allow 22/tcp || true
      rm -f "$F_STAGE"
      info "Порт 22 закрыт и staging-конфиг удалён."
      systemctl reload ssh || true
    fi
  fi
}
