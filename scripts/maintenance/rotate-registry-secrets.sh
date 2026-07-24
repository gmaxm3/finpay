#!/usr/bin/env bash
# ==============================================================================
# rotate-registry-secrets.sh — Оновлення registry credentials у всіх namespace
#
# Використання:
#   export REGISTRY_USERNAME="new-username"
#   export REGISTRY_PASSWORD="new-password"
#   ./rotate-registry-secrets.sh
# ==============================================================================
set -euo pipefail

echo "=== Ротація registry credentials ==="

if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
  echo "ПОМИЛКА: Встановіть REGISTRY_USERNAME та REGISTRY_PASSWORD"
  exit 1
fi

# Делегуємо основну логіку до bootstrap скрипту
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../bootstrap/04-add-registry-secrets.sh"
