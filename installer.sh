#!/usr/bin/env bash
# installer.sh — однофайловый установщик-загрузчик
# По умолчанию: скачивает репозиторий во временную папку, запускает run.sh, по успеху удаляет временные файлы.
# Дополнительно: флаг --telegram запускает только настройку Telegram (70_notify.sh) без полной установки.
set -Eeuo pipefail

# ========== Настройки по умолчанию (можно переопределять через окружение) ==========
GH_USER_DEFAULT="Igor-creato"     # <-- при необходимости замени на свой GitHub-юзернейм
REPO_DEFAULT="stack-n8n"          # имя репозитория
BRANCH_DEFAULT="master"           # ветка/тег
RUN_FILE="run.sh"                 # входная точка в репозитории

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
  --telegram    Выполнить только настройку Telegram-уведомлений (запуск 70_notify.sh из репозитория).
  --help        Показать эту справку.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram) TELEGRAM_ONLY=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *)
      echo "Неизвестный флаг: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# ========== Вывод ==========
info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

# ========== Предусловия ==========
need_bin(){ command -v "$1" >/dev/null 2>&1 || { error "Требуется утилита: $1"; exit 1; }; }
need_bin curl
need_bin bash
need_bin tar

# ========== Временная папка и ловушки ==========
TMPDIR="$(mktemp -d -t stack-n8n.XXXXXX)"
cleanup_success(){ rm -rf "$TMPDIR" 2>/dev/null || true; }
cleanup_failure(){ warn "Ошибка. Временные файлы сохранены в: $TMPDIR"; }
trap 'cleanup_failure' ERR

# ========== Режим только Telegram ==========
run_telegram_only() {
  local RAW_URL="https://raw.githubusercontent.com/${GH_USER}/${REPO}/${BRANCH}/70_notify.sh"
  local DST="${TMPDIR}/70_notify.sh"

  info "Режим: только Telegram-настройка"
  info "Скачиваю 70_notify.sh из ${GH_USER}/${REPO}@${BRANCH}…"
  curl -fsSL "$RAW_URL" -o "$DST"
  chmod +x "$DST"

  sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
  info "Запускаю 70_notify.sh…"
  set +e
  bash "$DST"
  local RC=$?
  set -e

  if [[ $RC -ne 0 ]]; then
    error "70_notify.sh завершился с кодом $RC."
    exit $RC
  fi

  info "Готово: настройка Telegram выполнена."
  cleanup_success
  exit 0
}

if $TELEGRAM_ONLY; then
  run_telegram_only
fi

# ========== Полная установка ==========
TARBALL_URL="https://codeload.github.com/${GH_USER}/${REPO}/tar.gz/${BRANCH}"
TARBALL="$TMPDIR/src.tar.gz"
EXTRACT_DIR="$TMPDIR/extract"
mkdir -p "$EXTRACT_DIR"

info "Скачиваю репозиторий: ${GH_USER}/${REPO}@${BRANCH}"
curl -fsSL "$TARBALL_URL" -o "$TARBALL"

tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
# После распаковки путь вида: $EXTRACT_DIR/<REPO>-<BRANCH>/
ROOT_DIR="$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "${REPO}-*" | head -n1)"
if [[ -z "${ROOT_DIR:-}" || ! -d "$ROOT_DIR" ]]; then
  error "Не удалось найти распакованный каталог репозитория."
  exit 1
fi

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
set +e
pushd "$ROOT_DIR" >/dev/null
sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
bash "$RUN_FILE"
RC=$?
popd >/dev/null
set -e

if [[ $RC -ne 0 ]]; then
  error "Скрипт $RUN_FILE завершился с кодом $RC."
  exit $RC
fi

info "Установка завершена успешно."
cleanup_success
