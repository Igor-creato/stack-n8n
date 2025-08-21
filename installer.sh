#!/usr/bin/env bash
# installer.sh — однофайловый установщик-загрузчик для secure-ubuntu
# Скачивает репозиторий во временную папку, запускает run.sh, по успеху удаляет временные файлы.
set -Eeuo pipefail

# ========== Настройки по умолчанию ==========
GH_USER_DEFAULT="<GH_USER>"        # <-- ЗАМЕНИ на свой GitHub-юзернейм
REPO_DEFAULT="secure-ubuntu"       # имя репозитория
BRANCH_DEFAULT="main"              # ветка/тег
RUN_FILE="run.sh"                  # входная точка в репозитории

# Можно переопределить через переменные окружения:
GH_USER="${GH_USER:-$GH_USER_DEFAULT}"
REPO="${REPO:-$REPO_DEFAULT}"
BRANCH="${BRANCH:-$BRANCH_DEFAULT}"

# ========== Вывод ==========
info(){ echo -e "\e[34m[INFO]\e[0m  $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m  $*"; }
error(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

# ========== Предусловия ==========
need_bin(){ command -v "$1" >/dev/null 2>&1 || { error "Требуется утилита: $1"; exit 1; }; }
need_bin curl
need_bin tar
need_bin bash

# ========== Временная папка и очистка ==========
TMPDIR="$(mktemp -d -t secure-ubuntu.XXXXXX)"
TARBALL="$TMPDIR/src.tar.gz"
EXTRACT_DIR="$TMPDIR/extract"
mkdir -p "$EXTRACT_DIR"

cleanup_success(){
  # Полная очистка при успешной установке
  rm -rf "$TMPDIR" 2>/dev/null || true
}

cleanup_failure(){
  # Оставляем файлы для отладки
  warn "Ошибка установки. Временные файлы сохранены в: $TMPDIR"
}

trap 'cleanup_failure' ERR

# ========== Скачивание архива ==========
TARBALL_URL="https://codeload.github.com/${GH_USER}/${REPO}/tar.gz/${BRANCH}"
info "Скачиваю репозиторий: ${GH_USER}/${REPO}@${BRANCH}"
curl -fsSL "$TARBALL_URL" -o "$TARBALL"

# ========== Распаковка ==========
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
# После распаковки путь вида: $EXTRACT_DIR/<REPO>-<BRANCH>/
# (Например: /tmp/secure-ubuntu.ABC123/extract/secure-ubuntu-main)
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

# ========== Запуск ==========
info "Запускаю ${RUN_FILE} из репозитория..."
# Передаём дальше все аргументы, с которыми вызван installer.sh
set +e
pushd "$ROOT_DIR" >/dev/null
sudo -n true 2>/dev/null || warn "sudo может запросить пароль (это нормально)."
bash "$RUN_FILE" "$@"
RC=$?
popd >/dev/null
set -e

if [[ $RC -ne 0 ]]; then
  error "Скрипт $RUN_FILE завершился с кодом $RC."
  exit $RC
fi

info "Установка завершена успешно."
cleanup_success
