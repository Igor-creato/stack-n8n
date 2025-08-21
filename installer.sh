#!/usr/bin/env bash
# installer.sh — однофайловый установщик-загрузчик
# По умолчанию: скачивает репозиторий во временную папку, запускает run.sh, по успеху удаляет временные файлы.
# Флаг --telegram: скачивает архив репозитория, находит 70_notify.sh (в любом подпути) и запускает только телеграм-настройку.
set -Eeuo pipefail

# ========== Настройки по умолчанию (можно переопределять через окружение) ==========
GH_USER_DEFAULT="Igor-creato"     # GitHub user/org
REPO_DEFAULT="stack-n8n"          # Repo name
BRANCH_DEFAULT="master"           # Branch or tag
RUN_FILE="run.sh"                 # Entry point for full install

GH_USER="${GH_USER:-$GH_USER_DEFAULT}"
REPO="${REPO:-$REPO_DEFAULT}"
BRANCH="${BRANCH:-$BRANCH_DEFAULT}"

# ========== Параметры запуска ==========
TELEGRAM_ONLY=false

usage() {
  cat <<'EOF'
Usage:
  installer.sh [--telegram] [--help]

Options:
  --telegram    Выполнить только настройку Telegram-уведомлений:
                * скачать архив репозитория
                * найти 70_notify.sh (в любой подпапке)
                * запустить его
  --help        Показать эту справку.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram) TELEGRAM_ONLY=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *) echo "Неизвестный флаг: $1" >&2; usage; exit 1 ;;
  esac
done

# ========== Вывод ==========
info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

# ========== Предусловия ==========
need_bin(){ command -v "$1" >/dev/null 2>&1 || { error "Требуется утилита: $1"; exit 1; }; }
need_bin curl
need_bin tar
need_bin bash
need_bin find

# ========== Временная папка и ловушки ==========
TMPDIR="$(mktemp -d -t stack-n8n.XXXXXX)"
TARBALL="$TMPDIR/src.tar.gz"
EXTRACT_DIR="$TMPDIR/extract"
mkdir -p "$EXTRACT_DIR"

cleanup_success(){ rm -rf "$TMPDIR" 2>/dev/null || true; }
cleanup_failure(){ warn "Ошибка. Временные файлы сохранены в: $TMPDIR"; }
trap 'cleanup_failure' ERR

# ========== Загрузка архива репозитория ==========
download_repo() {
  local url="https://codeload.github.com/${GH_USER}/${REPO}/tar.gz/${BRANCH}"
  info "Скачиваю репозиторий: ${GH_USER}/${REPO}@${BRANCH}"
  curl -fsSL "$url" -o "$TARBALL"
  tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
  # путь вида: $EXTRACT_DIR/<REPO>-<BRANCH>/
  ROOT_DIR="$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "${REPO}-*" | head -n1)"
  if [[ -z "${ROOT_DIR:-}" || ! -d "$ROOT_DIR" ]]; then
    error "Не удалось найти распакованный каталог репозитория."
    exit 1
  fi
}

# ========== Режим только Telegram ==========
run_telegram_only() {
  info "Режим: только Telegram-настройка"
  download_repo

  # Ищем скрипт(ы) настройки Telegram
  # Наиболее вероятные имена:
  #   70_notify.sh, notify-telegram.sh, reboot-notify-telegram.sh
  local candidate
  candidate="$(find "$ROOT_DIR" -maxdepth 3 -type f \
    \( -name '70_notify.sh' -o -name 'notify-telegram.sh' -o -name 'reboot-notify-telegram.sh' \) \
    | head -n1 || true)"

  if [[ -n "$candidate" ]]; then
    info "Нашёл скрипт Telegram: ${candidate#$ROOT_DIR/}"
    chmod +x "$candidate" || true
    sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
    info "Запускаю $candidate…"
    set +e
    bash "$candidate"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      error "Скрипт завершился с кодом $rc."
      exit $rc
    fi
    info "Готово: настройка Telegram выполнена."
    cleanup_success
    exit 0
  fi

  # Fallback: если run.sh поддерживает --telegram, попробуем через него
  if [[ -f "$ROOT_DIR/$RUN_FILE" ]]; then
    if grep -qE -- '--telegram|TELEGRAM_ONLY' "$ROOT_DIR/$RUN_FILE" 2>/dev/null; then
      info "Не нашёл 70_notify.sh, но run.sh выглядит как поддерживающий --telegram. Пробую через него…"
      chmod +x "$ROOT_DIR/$RUN_FILE" || true
      pushd "$ROOT_DIR" >/dev/null
      sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
      set +e
      bash "$RUN_FILE" --telegram
      local rc=$?
      set -e
      popd >/dev/null
      if [[ $rc -ne 0 ]]; then
        error "run.sh --telegram завершился с кодом $rc."
        exit $rc
      fi
      info "Готово: настройка Telegram выполнена через run.sh."
      cleanup_success
      exit 0
    fi
  fi

  # Если сюда дошли — ни скрипта, ни поддержки в run.sh
  warn "В репозитории не найден 70_notify.sh и нет поддержки --telegram в ${RUN_FILE}."
  warn "Подсказка: вот что удалось найти по маске '*notify*telegram*.sh':"
  find "$ROOT_DIR" -maxdepth 5 -type f -iname '*notify*telegram*.sh' -printf ' - %P\n' || true
  exit 1
}

if $TELEGRAM_ONLY; then
  run_telegram_only
fi

# ========== Полная установка ==========
download_repo

# Проверка наличия run.sh
if [[ ! -x "$ROOT_DIR/$RUN_FILE" ]]; then
  if [[ -f "$ROOT_DIR/$RUN_FILE" ]]; then
    chmod +x "$ROOT_DIR/$RUN_FILE"
  else
    error "В репозитории отсутствует файл $RUN_FILE"
    exit 1
  fi
fi

info "Запускаю ${RUN_FILE} из репозитория..."
# Передаём дальше все аргументы (кроме уже перехваченного --telegram)
set +e
pushd "$ROOT_DIR" >/dev/null
sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
bash "$RUN_FILE" "$@"
rc=$?
popd >/dev/null
set -e

if [[ $rc -ne 0 ]]; then
  error "Скрипт $RUN_FILE завершился с кодом $rc."
  exit $rc
fi

info "Установка завершена успешно."
cleanup_success
