#!/usr/bin/env bash
# ==============================================================================
# kustomize-apply.sh — kubectl apply -k з підтримкою SOPS-зашифрованих secrets
#
# Використання:
#   ./scripts/maintenance/kustomize-apply.sh OVERLAY_PATH [kubectl flags]
#
# Приклади:
#   ./scripts/maintenance/kustomize-apply.sh k8s-ops/apps/cde/cards/overlays/test
#   ./scripts/maintenance/kustomize-apply.sh k8s-ops/apps/cde/shared-secrets/overlays/test --dry-run=client
#
# Що робить:
#   1. Копіює overlay у тимчасову директорію
#   2. Розшифровує всі secret*.yaml (SOPS) in-place у temp копії
#   3. Запускає kubectl apply -k на temp копії
#   4. Видаляє temp директорію
#
# Вимоги:
#   - SOPS_AGE_KEY_FILE або SOPS_AGE_KEY має бути встановлено
#   - sops, kubectl мають бути в PATH
# ==============================================================================
set -euo pipefail

OVERLAY_PATH="${1:-}"
if [ -z "${OVERLAY_PATH}" ]; then
  echo "Використання: $0 OVERLAY_PATH [kubectl flags]"
  echo ""
  echo "Приклади:"
  echo "  $0 k8s-ops/apps/cde/cards/overlays/test"
  echo "  $0 k8s-ops/apps/cde/shared-secrets/overlays/test --dry-run=client"
  exit 1
fi

shift  # решта аргументів — kubectl flags

OVERLAY_PATH="${OVERLAY_PATH%/}"  # прибрати trailing slash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OVERLAY_ABS="${REPO_ROOT}/${OVERLAY_PATH}"

if [ ! -f "${OVERLAY_ABS}/kustomization.yaml" ]; then
  echo "ERROR: kustomization.yaml не знайдено в ${OVERLAY_ABS}"
  exit 1
fi

# Перевірити наявність age key
if [ -z "${SOPS_AGE_KEY_FILE:-}" ] && [ -z "${SOPS_AGE_KEY:-}" ]; then
  if [ -f "${HOME}/.config/sops/age/keys.txt" ]; then
    export SOPS_AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
  else
    echo "ERROR: встановіть SOPS_AGE_KEY_FILE або SOPS_AGE_KEY"
    echo "  export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt"
    exit 1
  fi
fi

# Визначаємо корінь сервісу (2 рівні вгору від overlays/{env})
# Структура: {service}/overlays/{env} → копіюємо весь {service}
SERVICE_ROOT_ABS="$(cd "${OVERLAY_ABS}/../.." && pwd)"
# Відносний шлях від service root до overlay (напр. overlays/test)
OVERLAY_REL="${OVERLAY_ABS#${SERVICE_ROOT_ABS}/}"

# Тимчасова директорія (автоматично видаляється при виході)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Копіюємо весь сервіс у temp (зберігає структуру base/ + overlays/)
cp -r "${SERVICE_ROOT_ABS}/." "${TMP_DIR}/"

# Розшифровуємо SOPS-файли тільки в overlay директорії temp
DECRYPTED=0
while IFS= read -r -d '' file; do
  if grep -q "^sops:" "${file}" 2>/dev/null; then
    sops --decrypt --in-place "${file}"
    echo "  decrypted: $(basename "${file}")"
    DECRYPTED=$((DECRYPTED + 1))
  fi
done < <(find "${TMP_DIR}/${OVERLAY_REL}" -name "secret*.yaml" -print0)

if [ "${DECRYPTED}" -eq 0 ]; then
  echo "  (no SOPS-encrypted files found)"
fi

echo ""
echo "kubectl apply -k ${OVERLAY_PATH} $*"
echo ""
kubectl apply -k "${TMP_DIR}/${OVERLAY_REL}" "$@"
