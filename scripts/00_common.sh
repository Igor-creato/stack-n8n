#!/usr/bin/env bash
set -Eeuo pipefail
info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*"; }

require_root(){ if [[ ${EUID:-0} -ne 0 ]]; then error "Запустите от root"; exit 1; fi; }

detect_ubuntu(){
  . /etc/os-release || true
  info "Обнаружена ОС: ${PRETTY_NAME:-unknown}"
  [[ "${ID:-}" == "ubuntu" ]] || warn "Скрипт тестировался на Ubuntu 20.04/22.04/24.04."
  command -v sshd >/dev/null || { error "Нет openssh-server. Установите: apt-get update && apt-get -y install openssh-server"; exit 1; }
}
