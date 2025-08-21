#!/usr/bin/env bash
set -Eeuo pipefail

harden_ssh(){
  info "Ужесточаю SSH и переключаю на новый порт без обрыва сессии..."
  mkdir -p /etc/ssh/sshd_config.d

  local MAIN=/etc/ssh/sshd_config
  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf

  # 0) Гарантируем, что include существует И стоит В КОНЦЕ файла (чтобы наши *.conf были приоритетнее)
  if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$MAIN"; then
    # удалим все такие строки
    sed -i '/^\s*Include\s*\/etc\/ssh\/sshd_config\.d\/\*.conf\s*$/d' "$MAIN"
  fi
  printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$MAIN"

  # Утилита: слушает ли указанный порт (любой процесс)
  _listens(){ ss -H -tlpn 2>/dev/null | awk -v pat=":${1}$" '$4 ~ pat {f=1} END{exit f?0:1}'; }

  # === Режим socket-активации (ssh.socket) ===
  if systemctl is-enabled --quiet ssh.socket || systemctl is-active --quiet ssh.socket; then
    info "Обнаружена socket-активация (ssh.socket). Перекладываю порты в ssh.socket."

    # Стадия: слушать 22 и новый порт (IPv4/IPv6)
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

    # Ждём появления нового порта (до ~10 сек)
    local ok=0; for i in {1..20}; do _listens "${SSH_PORT}" && { ok=1; break; }; sleep 0.5; done
    if [[ $ok -ne 1 ]]; then
      error "Новый порт ${SSH_PORT} не слушается (socket)."
      echo "---- systemd cat ssh.socket ----"; systemctl cat ssh.socket || true
      echo "---- ss -ltnp ----"; ss -ltnp | sed -n '1,200p' || true
      exit 1
    fi
    info "Порт ${SSH_PORT} поднят через ssh.socket (22 оставлен временно для безопасной перекладки)."

    # Жёсткие параметры SSH (Port игнорируется при socket-активации)
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

    # --- АВТОУБОРКА: отключаем 22 в сокете и файрволе, удаляем staging ---
    if [[ ${SSH_PORT} -ne 22 ]]; then
      info "Убираю 22-й порт из ssh.socket и закрываю его в UFW (автоматически)..."
      cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF
      systemctl daemon-reload
      systemctl restart ssh.socket
      ufw delete allow 22/tcp || true
      rm -f "$F_STAGE" || true
      info "22-й порт удалён из ssh.socket и закрыт в UFW."
    fi

    return 0
  fi

  # === Классический режим (без socket-активации) ===
  info "Socket-активация не активна. Настраиваю порты через sshd_config.d …"

  # Стадия: слушаем 22 и новый порт, пароли временно ON (чтобы не запереть себя)
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

  # Ждём появления нового порта
  local ok=0; for i in {1..20}; do _listens "${SSH_PORT}" && { ok=1; break; }; sleep 0.5; done
  if [[ $ok -ne 1 ]]; then
    error "Новый порт ${SSH_PORT} не слушается (classic)."
    echo "---- Port в конфигах ----"; grep -Hn '^[Pp]ort[[:space:]]' "$MAIN" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    echo "---- ss -ltnp ----"; ss -ltnp | sed -n '1,200p' || true
    exit 1
  fi
  info "Порт ${SSH_PORT} поднят, 22-й временно оставлен."

  # Финал: только новый порт; пароли — если ключа НЕТ
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

  # --- АВТОУБОРКА: закрываем 22 и удаляем staging ---
  if [[ ${SSH_PORT} -ne 22 ]]; then
    ufw delete allow 22/tcp || true
    rm -f "$F_STAGE" || true
    info "22-й порт закрыт в UFW, staging-конфиг удалён."
    systemctl reload ssh || true
  fi
}
