#!/usr/bin/env bash
# ==============================================================================
# upgrade-argocd.sh — Оновлення ArgoCD до нової версії
#
# Використання:
#   sudo bash scripts/maintenance/upgrade-argocd.sh
#   sudo ARGOCD_VERSION=v3.5.0 bash scripts/maintenance/upgrade-argocd.sh
#
# Підтримувані версії: https://endoflife.date/argo-cd
# Поточна: v3.4.2 (підтримується до ~лютого 2027)
# ==============================================================================
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
ARGOCD_NAMESPACE="argocd"

echo "=== Оновлення ArgoCD до ${ARGOCD_VERSION} ==="

if [ "$(id -u)" -ne 0 ]; then
  echo "ПОМИЛКА: скрипт потребує root доступу (sudo)"
  exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Крок 1: Apply manifest (server-side щоб уникнути помилки з великими CRD)
echo "--- Застосування manifest ArgoCD ${ARGOCD_VERSION} ---"
kubectl apply --server-side --force-conflicts -n "${ARGOCD_NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Крок 2: Чекати rollout
echo "--- Очікування готовності (може зайняти 2-3 хвилини) ---"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-applicationset-controller --timeout=300s

# Крок 3: Застосувати наш argocd-cm (install.yaml перезаписує дефолтним)
echo "--- Застосування argocd-cm конфігурації ---"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${REPO_ROOT}/k8s-ops/argocd/argocd-cm-patch.yaml"

# Крок 4: Відновити RBAC (install.yaml перезаписує дефолтним)
echo "--- Застосування RBAC конфігурації ---"
kubectl apply -n "${ARGOCD_NAMESPACE}" -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:dev-team, applications, sync, dev-project/*, allow
    p, role:dev-team, applications, sync, test-project/*, allow
    p, role:dev-team, applications, get, */*, allow
    p, role:dev-team, applications, list, */*, allow
    p, role:dev-team, logs, get, */*, allow

    p, role:release-manager, applications, sync, stage-project/*, allow
    p, role:release-manager, applications, get, */*, allow
    p, role:release-manager, applications, list, */*, allow
    p, role:release-manager, logs, get, */*, allow

    p, role:prod-operator, applications, sync, prod-dmz-project/*, allow
    p, role:prod-operator, applications, sync, prod-cde-project/*, allow
    p, role:prod-operator, applications, get, */*, allow
    p, role:prod-operator, logs, get, */*, allow

    g, dev-team, role:dev-team
    g, release-managers, role:release-manager
    g, prod-operators, role:prod-operator
    g, admin, role:admin
EOF

# Крок 5: Перевірка версії
echo ""
echo "=== ArgoCD оновлено успішно ==="
echo ""
echo "Версія:"
kubectl -n "${ARGOCD_NAMESPACE}" get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""
echo ""
echo "Якщо apps показують OutOfSync — це нормально після зміни resource tracking."
echo "Запустіть sync: argocd app list -o name | xargs -I{} argocd app sync {} --async"
