#!/usr/bin/env bash
# Оновлює bitbucket-git secrets у всіх Kargo project namespaces
# та застосовує оновлені stages.yaml до кластера.
#
# Використання:
#   export BITBUCKET_REPO_TOKEN="<токен з Bitbucket>"
#   bash scripts/maintenance/update-kargo-git-credentials.sh
set -euo pipefail

if [ -z "${BITBUCKET_REPO_TOKEN:-}" ]; then
  echo "ПОМИЛКА: встановіть змінну BITBUCKET_REPO_TOKEN"
  echo "  export BITBUCKET_REPO_TOKEN='<токен>'"
  exit 1
fi

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/finpaybank-management}"
export KUBECONFIG

ALL_PROJECTS="banks banks-worker cards cards-worker check-for-update customer \
  customers-update identity image2text kyc-liveness-service kyc-liveness-web \
  kyc-liveness-worker maintenance nginx notifications notifications-worker \
  onboarding onboarding-web password-recovery payments print-reports push-gateway \
  qr rabbitmq redis sms static transactions transactions-worker ukrcard ukrpost vkursi"

echo "=== Оновлення Kargo git credentials (HTTPS token) ==="
echo ""

for PROJECT in ${ALL_PROJECTS}; do
  kubectl create secret generic bitbucket-git \
    --namespace="${PROJECT}" \
    --from-literal=repoURL="https://bitbucket.org/Kapowai/finpaybank-gitops.git" \
    --from-literal=username="x-token-auth" \
    --from-literal=password="${BITBUCKET_REPO_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl label secret bitbucket-git \
    -n "${PROJECT}" "kargo.akuity.io/cred-type=git" --overwrite

  echo "  ✓ ${PROJECT}"
done

echo ""
echo "=== Застосування оновлених stages.yaml ==="
find k8s-ops/kargo -mindepth 2 -name "stages.yaml" ! -path "*/_template/*" \
  -exec kubectl apply -f {} \;

echo ""
echo "=== Готово. Перевірка: ==="
echo "  kargo promote --project=banks --freight=<ID> --stage=test"
