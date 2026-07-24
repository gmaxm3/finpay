#!/usr/bin/env bash
# ==============================================================================
# add-new-service.sh — Автоматичне додавання нового сервісу
#
# Використання:
#   ./add-new-service.sh SERVICE_NAME ZONE [SERVICE_PORT]
#
# Приклад:
#   ./add-new-service.sh payment-service cde 8080
#   ./add-new-service.sh push-gateway dmz 9091
# ==============================================================================
set -euo pipefail

SERVICE_NAME="${1:-}"
ZONE="${2:-}"
SERVICE_PORT="${3:-8080}"

# Валідація аргументів
if [ -z "${SERVICE_NAME}" ] || [ -z "${ZONE}" ]; then
  echo "Використання: $0 SERVICE_NAME ZONE [SERVICE_PORT]"
  echo ""
  echo "  SERVICE_NAME — ім'я сервісу (lowercase-kebab-case)"
  echo "  ZONE         — dmz або cde"
  echo "  SERVICE_PORT — порт контейнера (default: 8080)"
  echo ""
  echo "Приклади:"
  echo "  $0 payment-service cde 8080"
  echo "  $0 push-gateway dmz 9091"
  exit 1
fi

# Валідація зони
if [ "${ZONE}" != "dmz" ] && [ "${ZONE}" != "cde" ]; then
  echo "ПОМИЛКА: ZONE має бути 'dmz' або 'cde'"
  exit 1
fi

# Валідація імені (lowercase-kebab-case)
if ! echo "${SERVICE_NAME}" | grep -qE '^[a-z][a-z0-9-]*$'; then
  echo "ПОМИЛКА: SERVICE_NAME має бути lowercase-kebab-case (наприклад: my-service)"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/k8s-ops/apps/${ZONE}/_template"
TARGET_DIR="${REPO_ROOT}/k8s-ops/apps/${ZONE}/${SERVICE_NAME}"
KARGO_TEMPLATE_DIR="${REPO_ROOT}/k8s-ops/kargo/_template"
KARGO_TARGET_DIR="${REPO_ROOT}/k8s-ops/kargo/${SERVICE_NAME}"

echo "=== Додавання нового сервісу ==="
echo "  Назва:   ${SERVICE_NAME}"
echo "  Зона:    ${ZONE}"
echo "  Порт:    ${SERVICE_PORT}"
echo ""

# Перевірка чи сервіс вже існує
if [ -d "${TARGET_DIR}" ]; then
  echo "ПОМИЛКА: Сервіс '${SERVICE_NAME}' вже існує в ${TARGET_DIR}"
  exit 1
fi

# Копіювати template
echo "--- Копіювання template ---"
cp -r "${TEMPLATE_DIR}" "${TARGET_DIR}"
cp -r "${KARGO_TEMPLATE_DIR}" "${KARGO_TARGET_DIR}"

# Замінити плейсхолдери
echo "--- Заміна плейсхолдерів ---"
find "${TARGET_DIR}" "${KARGO_TARGET_DIR}" -type f | while read -r file; do
  sed -i.bak \
    -e "s/SERVICE_NAME/${SERVICE_NAME}/g" \
    -e "s/SERVICE_PORT/${SERVICE_PORT}/g" \
    "${file}"
  rm -f "${file}.bak"
done

echo "  ✓ Файли сервісу створено в: ${TARGET_DIR}"
echo "  ✓ Kargo pipeline створено в: ${KARGO_TARGET_DIR}"

# Показати що створено
echo ""
echo "--- Структура файлів ---"
find "${TARGET_DIR}" -type f | sort | sed "s|${REPO_ROOT}/||"
echo ""
find "${KARGO_TARGET_DIR}" -type f | sort | sed "s|${REPO_ROOT}/||"

echo ""
echo "=== Наступні кроки ==="
echo ""
echo "1. Налаштувати resources в base/deployment.yaml:"
echo "   ${TARGET_DIR}/base/deployment.yaml"
echo ""
echo "2. Налаштувати NetworkPolicy для ${ZONE} зони:"
echo "   ${TARGET_DIR}/base/networkpolicy.yaml"
echo ""
echo "3. Встановити image в overlays:"
echo "   ${TARGET_DIR}/overlays/dev/kustomization.yaml"
echo ""
echo "4. Перевірити kustomize build:"
echo "   kubectl kustomize ${TARGET_DIR}/overlays/dev"
echo ""
echo "5. Якщо сервіс потребує власних секретів (DB пароль, API ключ тощо):"
echo "   а) Створити secret YAML в overlays/${env}/secret-${SERVICE_NAME}.yaml"
echo "   б) Зашифрувати: sops -e -i overlays/{env}/secret-${SERVICE_NAME}.yaml"
echo "   в) Додати до overlays/{env}/kustomization.yaml: resources: [secret-${SERVICE_NAME}.yaml]"
echo ""
echo "6. Оновити README.md — додати сервіс до таблиці"
echo ""
echo "7. Закомітити та запушити зміни (secret*.yaml зашифровані — безпечно)"
