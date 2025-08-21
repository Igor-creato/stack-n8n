#!/usr/bin/env bash
# secure-ubuntu/run.sh — единая точка запуска
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${BASE_DIR}/scripts"

# Подгружаем модули по порядку
source "${LIB_DIR}/00_common.sh"
source "${LIB_DIR}/10_user.sh"
source "${LIB_DIR}/20_packages.sh"
source "${LIB_DIR}/30_firewall.sh"
source "${LIB_DIR}/40_ssh.sh"
source "${LIB_DIR}/50_sysctl.sh"
source "${LIB_DIR}/60_time_journal.sh"
source "${LIB_DIR}/70_notify.sh"
source "${LIB_DIR}/99_run.sh"

main_run "$@"