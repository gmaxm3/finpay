#!/usr/bin/env bash
# ==============================================================================
# 03-install-kargo.sh — Встановлення Kargo на management node
#
# Kargo — promotion pipeline: dev → test → stage → prod
# Документація: https://docs.kargo.io
# ==============================================================================
set -euo pipefail

KARGO_VERSION="${KARGO_VERSION:-1.8.4}"
KARGO_NAMESPACE="kargo"
KARGO_CHART="${KARGO_CHART:-oci://ghcr.io/akuity/kargo-charts/kargo}"

echo "=== Встановлення Kargo ${KARGO_VERSION} ==="

# Перевірка наявності helm
if ! command -v helm &>/dev/null; then
  echo "--- Встановлення Helm ---"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Валідація обов'язкових змінних
if [ -z "${KARGO_ADMIN_PASSWORD_HASH:-}" ]; then
  echo "ПОМИЛКА: Змінна KARGO_ADMIN_PASSWORD_HASH не встановлена"
  echo "Приклад:"
  echo "  export KARGO_ADMIN_PASSWORD_HASH=\$(htpasswd -bnBC 10 \"\" 'STRONG_PASSWORD' | tr -d ':\\n')"
  exit 1
fi

if [ -z "${KARGO_TOKEN_SIGNING_KEY:-}" ]; then
  echo "ПОМИЛКА: Змінна KARGO_TOKEN_SIGNING_KEY не встановлена"
  echo "Приклад:"
  echo "  export KARGO_TOKEN_SIGNING_KEY=\$(openssl rand -base64 48 | tr -d '=+/' | head -c 32)"
  exit 1
fi

# Перевірка cert-manager CRDs
if ! kubectl get crd certificates.cert-manager.io issuers.cert-manager.io >/dev/null 2>&1; then
  echo "ПОМИЛКА: cert-manager CRDs не встановлені в management cluster"
  echo "Kargo ${KARGO_VERSION} очікує наявність cert-manager ресурсів (Certificate, Issuer)."
  echo "Спочатку встановіть cert-manager у management cluster, наприклад:"
  echo "  kubectl apply -k infrastructure/cert-manager/"
  echo "  kubectl -n cert-manager rollout status deployment --timeout=120s"
  exit 1
fi

# Встановити Kargo з OCI chart
echo "--- Встановлення Kargo через Helm OCI chart ---"
helm upgrade --install kargo "${KARGO_CHART}" \
  --namespace "${KARGO_NAMESPACE}" \
  --create-namespace \
  --version "${KARGO_VERSION}" \
  --set api.adminAccount.enabled=true \
  --set api.adminAccount.passwordHash="${KARGO_ADMIN_PASSWORD_HASH}" \
  --set api.adminAccount.tokenSigningKey="${KARGO_TOKEN_SIGNING_KEY}" \
  --wait

# Чекати готовності
echo "--- Очікування готовності Kargo ---"
kubectl -n "${KARGO_NAMESPACE}" rollout status deployment/kargo-api --timeout=300s
kubectl -n "${KARGO_NAMESPACE}" rollout status deployment/kargo-controller --timeout=300s

echo ""
echo "=== Kargo встановлено успішно ==="
echo ""
echo "Наступні кроки:"
echo "  1. Виконати: scripts/bootstrap/06-bootstrap-kargo.sh"
echo "  2. Налаштувати git credentials (Bitbucket repo access token)"
echo "  3. Зберегти KARGO_TOKEN_SIGNING_KEY у password manager"
echo ""
echo "  Kargo UI (port-forward):"
echo "  kubectl port-forward svc/kargo-api -n kargo 8081:443"
