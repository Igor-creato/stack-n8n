#!/usr/bin/env bash
set -Eeuo pipefail

prompt_admin_user(){
  read -rp "Имя админ-пользователя (будет создан, если не существует) [deploy]: " USERNAME_RAW
  USERNAME=${USERNAME_RAW:-deploy}; USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')
  [[ "$USERNAME" =~ ^[a-z][-a-z0-9_]{0,31}$ ]] || { error "Некорректное имя: $USERNAME"; exit 1; }

  if ! id "$USERNAME" &>/dev/null; then
    info "Создаю пользователя $USERNAME и добавляю в sudo..."
    adduser --disabled-password --gecos "" "$USERNAME"
    usermod -aG sudo "$USERNAME"
  else
    info "Пользователь $USERNAME уже существует; добавляю в sudo (если требуется)..."
    usermod -aG sudo "$USERNAME" || true
  fi

  install -d -m 700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
  AUTH_KEYS_FILE="/home/$USERNAME/.ssh/authorized_keys"; HAS_KEY=0
  [[ -s "$AUTH_KEYS_FILE" ]] && grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp256)[[:space:]]' "$AUTH_KEYS_FILE" && HAS_KEY=1

  # Перенос ключей root → пользователь
  if [[ -s /root/.ssh/authorized_keys ]]; then
    info "Переношу ключи от root к $USERNAME (с бэкапом) и очищаю у root..."
    touch "$AUTH_KEYS_FILE"; chmod 600 "$AUTH_KEYS_FILE"; chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"
    while IFS= read -r line; do [[ -n "$line" ]] && ! grep -Fxq "$line" "$AUTH_KEYS_FILE" && echo "$line" >> "$AUTH_KEYS_FILE"; done < /root/.ssh/authorized_keys
    chmod 600 "$AUTH_KEYS_FILE"; chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"; HAS_KEY=1
    ts=$(date +%Y%m%d-%H%M%S); install -d -m 700 /root/.ssh/backup
    cp /root/.ssh/authorized_keys "/root/.ssh/backup/authorized_keys.$ts.bak" || true
    : > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  fi

  # Приём ключа: OpenSSH одной строкой ИЛИ блок SSH2 (RFC4716) с автоконверсией
  if [[ $HAS_KEY -eq 0 ]]; then
    echo "Вставьте ключ: однострочный OpenSSH (ssh-ed25519/ssh-rsa/ecdsa-...)"
    echo "или блок SSH2 (RFC4716) «BEGIN...END». Завершение ввода — пустая строка или Ctrl+D."
    RAW=""; while IFS= read -r line; do [[ -z "$line" ]] && break; RAW+="$line"$'\n'; done || true
    RAW=$(printf "%b" "$RAW" | sed 's/\r$//')
    if [[ -n "$RAW" ]]; then
      IN=$(mktemp); OUT=$(mktemp); printf "%b" "$RAW" > "$IN"
      if grep -q "^---- BEGIN SSH2 PUBLIC KEY ----" "$IN"; then
        ssh-keygen -i -m RFC4716 -f "$IN" > "$OUT" 2>/dev/null || { rm -f "$IN" "$OUT"; error "Не удалось конвертировать SSH2 ключ"; exit 1; }
        PUB=$(sed -n '1p' "$OUT")
      else
        PUB=$(head -n1 "$IN")
      fi
      rm -f "$IN" "$OUT"
      [[ "$PUB" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp256)[[:space:]]+ ]] || { error "Неверный формат ключа"; exit 1; }
      echo "$PUB" >> "$AUTH_KEYS_FILE"; chmod 600 "$AUTH_KEYS_FILE"; chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"; HAS_KEY=1
      info "SSH-ключ добавлен в $AUTH_KEYS_FILE."
    else
      warn "Ключ не задан — вход по паролю временно останется включён."
    fi
  fi

  read -rp "Разрешить $USERNAME использовать sudo БЕЗ пароля? [y/N]: " NOP
  if [[ "${NOP,,}" == "y" ]]; then
    echo "%${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${USERNAME}-nopasswd"; chmod 440 "/etc/sudoers.d/90-${USERNAME}-nopasswd"
    info "Sudo без пароля включён."
  else
    info "Sudo будет спрашивать пароль (задай: passwd $USERNAME)."
  fi
}

choose_ssh_port(){
  read -rp "Порт SSH (1-65535, не 80/443) [22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}
  if ! [[ $SSH_PORT =~ ^[0-9]+$ ]] || (( SSH_PORT<1 || SSH_PORT>65535 )) || [[ $SSH_PORT == 80 || $SSH_PORT == 443 ]]; then
    error "Некорректный порт: $SSH_PORT"; exit 1; fi
  info "Выбран SSH-порт: $SSH_PORT"
}
