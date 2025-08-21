#!/usr/bin/env bash
set -Eeuo pipefail

harden_ssh(){
  info "Ужесточаю SSH и включаю новый порт без обрыва сессии..."
  mkdir -p /etc/ssh/sshd_config.d

  local MAIN=/etc/ssh/sshd_config
  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf
  local SOCKET_UNIT=ssh.socket
  local SERVICE_UNIT=ssh.service

  # Гарантируем, что каталог с конфигами подключается и sshd есть в системе
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$MAIN"; then
    cp "$MAIN" "${MAIN}.bak.$(date +%Y%m%d-%H%M%S)" || true
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN"
    info "Добавил 'Include /etc/ssh/sshd_config.d/*.conf' в $MAIN"
  fi

  # Утилита проверки "слушает ли порт" — принимаем и systemd, и sshd
  port_listens() {
    local p="$1"
    ss -H -tlpn 2>/dev/null | awk -v pat=":${p}$" '$4 ~ pat {found=1} END{exit found?0:1}'
  }

  # === Ветка 1: активна socket-активация (ssh.socket) ===
  if systemctl is-enabled --quiet "$SOCKET_UNIT" || systemctl is-active --quiet "$SOCKET_UNIT"; then
    info "Обнаружена socket-активация (ssh.socket). Перекладываю слушающие порты на socket."

    # Убедимся, что сервис тоже доступен (на всякий случай)
    systemctl enable "$SERVICE_UNIT" >/dev/null 2>&1 || true

    # Разрешим оба порта в UFW заранее (22 уже открыт, но повтор идемпотентен)
    ufw limit 22/tcp || true
    ufw limit ${SSH_PORT}/tcp || true

    # Создаём override для ssh.socket: слушать 22 и новый порт
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
# сбросить дефолтные ListenStream и задать свои
ListenStream=
ListenStream=22
ListenStream=${SSH_PORT}
EOF

    systemctl daemon-reload
    systemctl restart "$SOCKET_UNIT"

    # Ждём, пока новый порт реально появится (до 10 сек)
    local ok=0
    for i in {1..20}; do
      if port_listens "${SSH_PORT}"; then ok=1; break; fi
      sleep 0.5
    done
    if [[ $ok -ne 1 ]]; then
      error "Новый порт ${SSH_PORT} не слушается (socket-активация)."
      echo "---- Активные сокеты ----"; ss -ltnp | sed -n '1,200p' || true
      echo "---- override ssh.socket ----"; systemctl cat ssh.socket || true
      exit 1
    fi
    info "Порт ${SSH_PORT} поднят через ssh.socket. 22-й оставлен временно."

    # Жёсткие параметры SSH (кроме Port — он игнорируется при socket-активации)
    {
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
    systemctl reload "$SERVICE_UNIT" || true

    # Предложить убрать 22 из socket + UFW
    if [[ ${SSH_PORT} -ne 22 ]]; then
      echo
      warn "SSH уже доступен на ${SSH_PORT}. 22-й пока открыт для безопасности."
      read -rp "Проверили вход по новому порту? Убрать 22 из ssh.socket и UFW сейчас? [y/N]: " CLOSE22
      if [[ "${CLOSE22,,}" == "y" ]]; then
        # Обновим override: только новый порт
        cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
        systemctl daemon-reload
        systemctl restart "$SOCKET_UNIT"
        ufw delete allow 22/tcp || true
        info "22 удалён из ssh.socket и закрыт в UFW."
      else
        warn "Оставили 22 открытым. Закроете позже:
  - редактировать: /etc/systemd/system/ssh.socket.d/override.conf
  - затем: systemctl daemon-reload && systemctl restart ssh.socket
  - и:    ufw delete allow 22/tcp"
      fi
    fi
    return 0
  fi

  # === Ветка 2: классический режим (ssh.service без socket-активации) ===
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
  systemctl reload "$SERVICE_UNIT" || { warn "reload не удался, пробую restart …"; systemctl restart "$SERVICE_UNIT"; }

  # Ждём появления нового порта (до 10 сек)
  local ok=0
  for i in {1..20}; do
    if port_listens "${SSH_PORT}"; then ok=1; break; fi
    sleep 0.5
  done
  if [[ $ok -ne 1 ]]; then
    error "Новый порт ${SSH_PORT} не слушается."
    echo "---- Активные сокеты ----"; ss -ltnp | sed -n '1,200p' || true
    echo "---- Конфиги Port ----"; grep -Hn '^[Pp]ort[[:space:]]' "$MAIN" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    sshd -t || true
    exit 1
  fi
  info "Порт ${SSH_PORT} поднят, 22-й оставлен временно."

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
  systemctl reload "$SERVICE_UNIT" || true

  if [[ ${SSH_PORT} -ne 22 ]]; then
    echo
    warn "SSH уже переключён на порт ${SSH_PORT}. 22-й пока открыт в UFW."
    read -rp "Проверили вход по новому порту? Закрыть 22 сейчас? [y/N]: " CLOSE22
    if [[ "${CLOSE22,,}" == "y" ]]; then
      ufw delete allow 22/tcp || true
      rm -f "$F_STAGE"
      info "Порт 22 закрыт и staging-конфиг удалён."
      systemctl reload "$SERVICE_UNIT" || true
    else
      warn "Оставили 22 открытым. Закроете позже: ufw delete allow 22/tcp; затем rm -f $F_STAGE && systemctl reload ssh"
    fi
  fi
}
