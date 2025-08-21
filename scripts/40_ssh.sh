#!/usr/bin/env bash
set -Eeuo pipefail

harden_ssh(){
  info "Ужесточаю SSH и включаю новый порт без обрыва сессии..."
  mkdir -p /etc/ssh/sshd_config.d

  local MAIN=/etc/ssh/sshd_config
  local F_STAGE=/etc/ssh/sshd_config.d/10-port-staging.conf
  local F_FINAL=/etc/ssh/sshd_config.d/99-hardening.conf

  # 0) Гарантируем подключение каталога конфигов (иначе наши *.conf не читаются)
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' "$MAIN"; then
    cp "$MAIN" "${MAIN}.bak.$(date +%Y%m%d-%H%M%S)" || true
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN"
    info "Добавил 'Include /etc/ssh/sshd_config.d/*.conf' в $MAIN"
  fi

  # 1) Стадия: 22 + новый порт, пароли временно ON (чтобы не запереть себя)
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
  systemctl reload ssh || { error "reload ssh не удался (restart НЕ выполняю на этом шаге)"; rm -f "$F_STAGE"; exit 1; }

  # 2) Ждём, пока sshd начнёт реально слушать НОВЫЙ порт (до ~10 сек)
  local ok=0
  for i in {1..20}; do
    if ss -H -tlpn 2>/dev/null | awk -v p=":${SSH_PORT}$" '$4 ~ p && /sshd/ {found=1} END{exit found?0:1}'; then
      ok=1; break
    fi
    sleep 0.5
  done

  # 2a) Если reload не помог — пробуем безопасный restart ssh и ждём ещё раз
  if [[ $ok -ne 1 ]]; then
    warn "Reload не открыл порт ${SSH_PORT}. Пробую безопасный restart ssh (активные сессии не оборвутся на Ubuntu/Debian)..."
    systemctl restart ssh

    for i in {1..20}; do
      if ss -H -tlpn 2>/dev/null | awk -v p=":${SSH_PORT}$" '$4 ~ p && /sshd/ {found=1} END{exit found?0:1}'; then
        ok=1; break
      fi
      sleep 0.5
    done
  fi

  if [[ $ok -ne 1 ]]; then
    error "Новый порт ${SSH_PORT} не слушается."
    echo "---- Диагностика: активные сокеты sshd ----"
    ss -ltnp | awk 'NR<200{print}' || true
    echo "---- Конфиги с директивами Port ----"
    grep -Hn '^[Pp]ort[[:space:]]' "$MAIN" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    echo "---- Проверка синтаксиса sshd ----"
    sshd -t || true
    exit 1
  fi
  info "Порт ${SSH_PORT} поднят, 22-й оставлен временно."

  # 3) Финальный конфиг: только новый порт; пароли — если ключа нет
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

  # 4) Предложим закрыть 22 в UFW и убрать staging
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
