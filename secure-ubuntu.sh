#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  secure-ubuntu.sh
#  Базовая защита и стабилизация свежего Ubuntu-сервера.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

# ====== Вспомогательные функции ======
info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*"; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    error "Запустите скрипт от root: sudo ./secure-ubuntu.sh"; exit 1
  fi
}

detect_ubuntu() {
  . /etc/os-release || true
  info "Обнаружена ОС: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "Скрипт тестировался на Ubuntu 20.04/22.04/24.04. Продолжаем на ваш страх и риск."
  fi
  if ! command -v sshd >/dev/null 2>&1; then
    error "sshd не найден. Установите openssh-server: apt-get update && apt-get -y install openssh-server"; exit 1
  fi
}

# ====== Пользователь и ключи ======
prompt_admin_user() {
  read -rp "Имя админ-пользователя (будет создан, если не существует) [deploy]: " USERNAME_RAW
  USERNAME=${USERNAME_RAW:-deploy}
  USERNAME_LOWER=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')
  if [[ "$USERNAME" != "$USERNAME_LOWER" ]]; then
    warn "Имена пользователей в Linux обычно строчные. Преобразую: $USERNAME -> $USERNAME_LOWER"
    USERNAME="$USERNAME_LOWER"
  fi
  if ! [[ "$USERNAME" =~ ^[a-z][-a-z0-9_]{0,31}$ ]]; then
    error "Некорректное имя пользователя: '$USERNAME'. Разрешены: [a-z][a-z0-9_-], длина 1..32."
    exit 1
  fi

  if ! id "$USERNAME" &>/dev/null; then
    info "Создаю пользователя $USERNAME и добавляю в sudo..."
    adduser --disabled-password --gecos "" "$USERNAME"
    usermod -aG sudo "$USERNAME"
  else
    info "Пользователь $USERNAME уже существует. Добавляю в sudo (если ещё нет)..."
    usermod -aG sudo "$USERNAME" || true
  fi

  mkdir -p "/home/$USERNAME/.ssh"
  chmod 700 "/home/$USERNAME/.ssh"
  chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

  HAS_KEY=0
  AUTH_KEYS_FILE="/home/$USERNAME/.ssh/authorized_keys"
  if [[ -s "$AUTH_KEYS_FILE" ]] && grep -E -q '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp256)[[:space:]]' "$AUTH_KEYS_FILE"; then
    info "У пользователя $USERNAME уже есть SSH-ключ."
    HAS_KEY=1
  fi

  # Перенос ключей от root (если есть)
  ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"
  if [[ -s "$ROOT_AUTH_KEYS" ]]; then
    info "Обнаружены ключи у root. Переношу их к $USERNAME и очищаю у root (с бэкапом)..."
    touch "$AUTH_KEYS_FILE"; chmod 600 "$AUTH_KEYS_FILE"; chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"
    while IFS= read -r line; do
      if [[ -n "$line" ]] && ! grep -Fxq "$line" "$AUTH_KEYS_FILE"; then
        echo "$line" >> "$AUTH_KEYS_FILE"
      fi
    done < "$ROOT_AUTH_KEYS"
    chmod 600 "$AUTH_KEYS_FILE"; chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"
    HAS_KEY=1
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p /root/.ssh/backup
    cp "$ROOT_AUTH_KEYS" "/root/.ssh/backup/authorized_keys.$ts.bak" || true
    : > "$ROOT_AUTH_KEYS"
    chmod 600 "$ROOT_AUTH_KEYS"
    info "Ключи перенесены. У root файл authorized_keys очищен (бэкап сохранён)."
  fi

  # Ввод ключа: поддержка OpenSSH 1‑строкой и SSH2 (RFC4716) блоком
  if [[ $HAS_KEY -eq 0 ]]; then
    echo "Вставьте публичный ключ для $USERNAME."
    echo "Можно: одну строку OpenSSH (ssh-ed25519/ssh-rsa/ecdsa-...)"
    echo "или весь блок SSH2 (RFC4716) от строки BEGIN до END."
    echo "Окончание ввода — пустая строка или Ctrl+D."
    PUBKEY_RAW=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && break
      PUBKEY_RAW+="$line"$'\n'
    done || true
    PUBKEY_RAW=$(printf "%b" "$PUBKEY_RAW" | sed 's/\r$//')

    if [[ -n "$PUBKEY_RAW" ]]; then
      TMP_IN=$(mktemp); TMP_OUT=$(mktemp)
      printf "%b" "$PUBKEY_RAW" > "$TMP_IN"
      if grep -q "^---- BEGIN SSH2 PUBLIC KEY ----" "$TMP_IN"; then
        if ssh-keygen -i -m RFC4716 -f "$TMP_IN" > "$TMP_OUT" 2>/dev/null; then
          PUBKEY=$(sed -n '1p' "$TMP_OUT")
        else
          rm -f "$TMP_IN" "$TMP_OUT"
          error "Не удалось конвертировать SSH2 ключ в OpenSSH."; exit 1
        fi
      else
        PUBKEY=$(head -n1 "$TMP_IN")
      fi
      rm -f "$TMP_IN" "$TMP_OUT"

      if [[ ! "$PUBKEY" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp256)[[:space:]]+ ]]; then
        error "Неверный формат ключа. Нужна строка, начинающаяся с ssh-ed25519/ssh-rsa/ecdsa-sha2-nistp256."
        exit 1
      fi

      echo "$PUBKEY" >> "$AUTH_KEYS_FILE"
      chmod 600 "$AUTH_KEYS_FILE"
      chown "$USERNAME:$USERNAME" "$AUTH_KEYS_FILE"
      HAS_KEY=1
      info "SSH-ключ добавлен в $AUTH_KEYS_FILE."
    else
      warn "Ключ не задан и ранее не обнаружен. Чтобы не потерять доступ, вход по паролю останется включён."
    fi
  fi

  read -rp "Разрешить $USERNAME использовать sudo БЕЗ пароля? [y/N]: " NOPASSWD_CHOICE
  if [[ "${NOPASSWD_CHOICE,,}" == "y" ]]; then
    echo "%${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${USERNAME}-nopasswd"
    chmod 440 "/etc/sudoers.d/90-${USERNAME}-nopasswd"
    info "Включён sudo без пароля для $USERNAME."
  else
    info "Sudo будет требовать пароль. Если пароль у пользователя не задан, используйте 'passwd $USERNAME' для его установки."
  fi
}

choose_ssh_port() {
  read -rp "Порт SSH (1-65535, не 80/443) [22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}
  if ! [[ $SSH_PORT =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    error "Некорректный порт: $SSH_PORT"; exit 1
  fi
  if [[ $SSH_PORT == 80 || $SSH_PORT == 443 ]]; then
    error "Порты 80 и 443 заняты веб-трафиком. Выберите другой порт."; exit 1
  fi
  info "Выбран SSH-порт: $SSH_PORT"
}

# ====== Пакеты и обновления ======
apt_update_upgrade() {
  info "Обновляю индекс пакетов и систему..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  apt-get -y full-upgrade
  apt-get -y autoremove --purge
  apt-get -y autoclean
}

install_packages() {
  info "Устанавливаю пакеты: ufw, fail2ban, unattended-upgrades..."
  apt-get -y install ufw fail2ban unattended-upgrades ca-certificates curl vim openssh-server || true
}

configure_unattended_upgrades() {
  info "Включаю автоматические обновления (без авто-перезагрузки)..."
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Verbose "1";
EOF

  cat >/etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  systemctl enable unattended-upgrades
  systemctl restart unattended-upgrades
}

# ====== UFW / Fail2ban ======
configure_ufw() {
  info "Настраиваю UFW..."
  [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing

  # Открываем веб-порты
  ufw allow 80/tcp
  ufw allow 443/tcp

  # Всегда заранее открыть и новый порт, и 22 (стадия безопасного переключения)
  ufw limit ${SSH_PORT}/tcp
  ufw limit 22/tcp

  ufw logging low
  yes | ufw enable || true
  ufw status verbose
}

configure_fail2ban() {
  info "Настраиваю Fail2ban..."
  cat >/etc/fail2ban/jail.local <<EOF
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
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  fail2ban-client status sshd || true
}

# ====== SSH: безопасное переключение порта, без рестартов ======
harden_ssh() {
  info "Ужесточаю SSH и включаю новый порт без обрыва сессии..."

  mkdir -p /etc/ssh/sshd_config.d

  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf

  # 1) Стадия: слушаем ДВА порта (22 и новый), пароли временно включены
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

  if ! sshd -t; then
    error "Неверная конфигурация sshd (стадия). Откатываю."; rm -f "$F_STAGE"; exit 1
  fi
  if ! systemctl reload ssh; then
    error "sshd reload не удался. Рестарт НЕ выполняю, чтобы не оборвать сессию."; rm -f "$F_STAGE"; exit 1
  fi

  sleep 1
  if ! ss -tnlp | grep -q ":${SSH_PORT} "; then
    error "Новый порт ${SSH_PORT} не слушается. Откатываю staging."; rm -f "$F_STAGE"; systemctl reload ssh || true; exit 1
  fi
  info "Новый порт ${SSH_PORT} поднят. 22-й оставлен временно для безопасной проверки входа."

  # 2) Финальный жёсткий конфиг (только новый порт; пароли по наличию ключа)
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

  if ! sshd -t; then
    error "Неверная конфигурация sshd (финал). Оставляю двухпортовую стадию."; exit 1
  fi
  if ! systemctl reload ssh; then
    error "reload не удался. Оставляю двухпортовую стадию."; exit 1
  fi

  # 3) Спросить о закрытии 22 в UFW и убрать staging при подтверждении
  if [[ ${SSH_PORT} -ne 22 ]]; then
    echo
    warn "SSH уже переключён на порт ${SSH_PORT}. 22-й пока открыт в UFW для безопасности."
    read -rp "Проверили вход по новому порту (ssh -p ${SSH_PORT} ${USERNAME}@IP)? Закрыть 22 сейчас? [y/N]: " CLOSE22
    if [[ "${CLOSE22,,}" == "y" ]]; then
      ufw delete allow 22/tcp || true
      rm -f "$F_STAGE"
      info "Порт 22 закрыт и staging-конфиг удалён."
      systemctl reload ssh || true
    else
      warn "Оставили 22 открытым. Закроете позже: ufw delete allow 22/tcp; затем rm -f $F_STAGE && systemctl reload ssh"
    fi
  fi
}

# ====== Система: sysctl, время, журнал ======
harden_sysctl() {
  info "Применяю sysctl-харднинг..."
  cat >/etc/sysctl.d/99-hardening.conf <<'EOF'
# IPv4
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# IPv6
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Kernel / FS
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
  sysctl --system
}

enable_time_sync() {
  info "Включаю синхронизацию времени..."
  timedatectl set-ntp true
  systemctl enable systemd-timesyncd.service || true
  systemctl start systemd-timesyncd.service || true
  timedatectl
}

persist_journal() {
  info "Делаю журналы systemd персистентными..."
  mkdir -p /var/log/journal
  sed -i 's/^#*Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
  systemd-tmpfiles --create --prefix /var/log/journal || true
  systemctl restart systemd-journald
}

# ====== Telegram-уведомления о требуемой перезагрузке (опция) ======
setup_reboot_notify_telegram() {
  info "Настраиваю уведомления в Telegram о необходимости перезагрузки (по желанию)..."
  read -rp "Включить Telegram-уведомления при требуемой перезагрузке? [y/N]: " TG_CHOICE
  if [[ "${TG_CHOICE,,}" != "y" ]]; then
    info "Telegram-уведомления пропущены."
    return 0
  fi
  read -rp "Укажи Telegram BOT TOKEN (например, 123456:ABC...): " TG_BOT_TOKEN
  read -rp "Укажи chat_id (число или @username; лучше числовой ID): " TG_CHAT_ID

  cat >/etc/secure-bootstrap.conf <<EOF
TG_BOT_TOKEN='${TG_BOT_TOKEN}'
TG_CHAT_ID='${TG_CHAT_ID}'
EOF
  chmod 600 /etc/secure-bootstrap.conf

  cat >/usr/local/sbin/reboot-notify-telegram <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/secure-bootstrap.conf
STAMP_DIR=/var/lib/reboot-notify-telegram
STAMP_FILE="$STAMP_DIR/sent"
mkdir -p "$STAMP_DIR"

if [[ -f /var/run/reboot-required ]]; then
  HOST=$(hostname -f 2>/dev/null || hostname)
  PKG_COUNT=$(wc -l </var/run/reboot-required.pkgs 2>/dev/null || echo 0)
  TEXT="⚠️ Сервер ${HOST}: требуется перезагрузка после обновлений. Пакетов: ${PKG_COUNT}.
Команда для админа: sudo reboot (в удобное время)."
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
       -d chat_id="${TG_CHAT_ID}" -d text="${TEXT}" >/dev/null || true
  date > "$STAMP_FILE"
fi
EOS
  chmod +x /usr/local/sbin/reboot-notify-telegram

  cat >/etc/systemd/system/reboot-notify.service <<'EOS'
[Unit]
Description=Notify via Telegram when reboot is required
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reboot-notify-telegram
EOS

  cat >/etc/systemd/system/reboot-notify.path <<'EOS'
[Unit]
Description=Watch /var/run/reboot-required and trigger telegram notify
[Path]
PathExists=/var/run/reboot-required
[Install]
WantedBy=multi-user.target
EOS

  systemctl daemon-reload
  systemctl enable --now reboot-notify.path
  [[ -f /var/run/reboot-required ]] && systemctl start reboot-notify.service || true
}

summary() {
  echo
  info "ГОТОВО. Краткий статус:"
  echo "---- UFW ----"; ufw status verbose || true
  echo "---- Fail2ban (sshd) ----"; fail2ban-client status sshd || true
  echo "---- Важные заметки ----"
  if [[ ${HAS_KEY:-0} -eq 1 ]]; then
    echo "• Вход по паролю ОТКЛЮЧЁН (есть ключ). Пользователь: $USERNAME."
  else
    echo "• Вход по паролю ОСТАВЛЕН ВКЛЮЧЁННЫМ (ключ не был задан/обнаружен)."
  fi
  echo "• SSH-порт: ${SSH_PORT}."
  echo "• Открытые порты: ${SSH_PORT}/tcp (limit), 22/tcp (временно), 80/tcp, 443/tcp."
  echo "• Автообновления включены; авто-перезагрузка ОТКЛЮЧЕНА."
  echo "• После проверки входа по новому порту можно закрыть 22: ufw delete allow 22/tcp"
}

main() {
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

main "$@"
