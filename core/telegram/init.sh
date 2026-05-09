#!/bin/bash
# core/telegram/init.sh - Module loader

TG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${TG_DIR}/api.sh"
source "${TG_DIR}/media.sh"
source "${TG_DIR}/formatter.sh"
source "${TG_DIR}/polling.sh"
source "${TG_DIR}/router.sh"
