#!/usr/bin/env bash
# ==============================================================================
# 02-install-argocd.sh — Встановлення ArgoCD на management node
#
# Виконувати на management node після того як k3s встановлено.
# ArgoCD буде управляти всіма 5 кластерами.
# ==============================================================================
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
ARGOCD_NAMESPACE="argocd"

echo "=== Встановлення ArgoCD ${ARGOCD_VERSION} ==="

# Перевірка root
if [ "$(id -u)" -ne 0 ]; then
  echo "ПОМИЛКА: скрипт потребує root доступу (sudo)"
  exit 1
fi

# Перевірка наявності kubectl
if ! command -v kubectl &>/dev/null; then
  echo "ПОМИЛКА: kubectl не знайдено. Встановіть k3s спочатку."
  exit 1
fi

# Налаштування KUBECONFIG для root (k3s зберігає kubeconfig тут)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Створити namespace
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Встановлення ArgoCD
echo "--- Встановлення ArgoCD manifest ---"
kubectl apply -n "${ARGOCD_NAMESPACE}" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Чекати поки ArgoCD pods піднімуться
echo "--- Очікування готовності ArgoCD (може зайняти 2-3 хвилини) ---"
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment/argocd-applicationset-controller --timeout=300s

# Patch argocd-server для insecure mode (TLS термінується на Ingress/LB)
echo "--- Налаштування ArgoCD server ---"
kubectl -n "${ARGOCD_NAMESPACE}" patch deployment argocd-server \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# RBAC конфігурація
echo "--- Налаштування ArgoCD RBAC ---"
kubectl -n "${ARGOCD_NAMESPACE}" apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    # dev-team: може синхронізувати dev та test (через Kargo)
    p, role:dev-team, applications, sync, dev-project/*, allow
    p, role:dev-team, applications, sync, test-project/*, allow
    p, role:dev-team, applications, get, */*, allow
    p, role:dev-team, applications, list, */*, allow
    p, role:dev-team, logs, get, */*, allow

    # release-manager: може синхронізувати stage та ініціювати prod через Kargo
    p, role:release-manager, applications, sync, stage-project/*, allow
    p, role:release-manager, applications, get, */*, allow
    p, role:release-manager, applications, list, */*, allow
    p, role:release-manager, logs, get, */*, allow

    # prod: тільки читання + manual sync після Kargo approval
    p, role:prod-operator, applications, sync, prod-dmz-project/*, allow
    p, role:prod-operator, applications, sync, prod-cde-project/*, allow
    p, role:prod-operator, applications, get, */*, allow
    p, role:prod-operator, logs, get, */*, allow

    # Маппінг груп на ролі (замінити на реальні SSO групи)
    g, dev-team, role:dev-team
    g, release-managers, role:release-manager
    g, prod-operators, role:prod-operator
    g, admin, role:admin
EOF

# Отримати початковий пароль
echo ""
echo "=== ArgoCD встановлено успішно ==="
echo ""
echo "Початковий пароль admin:"
kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
echo ""
echo "Наступні кроки:"
echo "  1. Налаштувати Ingress або port-forward для ArgoCD UI:"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  2. Змінити пароль admin після першого входу"
echo "  3. Виконати: scripts/bootstrap/05-add-clusters-argocd.sh"
