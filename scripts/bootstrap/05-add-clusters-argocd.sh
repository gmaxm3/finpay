#!/usr/bin/env bash
# ==============================================================================
# 05-add-clusters-argocd.sh — Реєстрація всіх кластерів в ArgoCD
#
# Виконувати ПІСЛЯ того як:
#   - ArgoCD встановлено (02-install-argocd.sh)
#   - Всі k3s кластери підняті
#   - kubeconfig для кожного кластера збережено локально
#
# Замінити IP адреси на реальні перед запуском!
# ==============================================================================
set -euo pipefail

# ============================================================
# ЗАМІНИТИ НА РЕАЛЬНІ IP АДРЕСИ
# ============================================================
DEV_NODE_IP="${DEV_NODE_IP:-REPLACE_DEV_NODE_IP}"
TEST_NODE_IP="${TEST_NODE_IP:-REPLACE_TEST_NODE_IP}"
STAGE_DMZ_VIP="${STAGE_DMZ_VIP:-10.201.65.10}"                 # IP stage-node-1 (DMZ кластер)
STAGE_CDE_VIP="${STAGE_CDE_VIP:-10.201.66.10}"                 # IP stage-node-2 (CDE кластер)
PROD_DMZ_VIP="${PROD_DMZ_VIP:-REPLACE_PROD_DMZ_VIP}"           # VIP prod-dmz кластера
PROD_CDE_VIP="${PROD_CDE_VIP:-REPLACE_PROD_CDE_VIP}"           # VIP prod-cde кластера

ARGOCD_SERVER="${ARGOCD_SERVER:-localhost:8080}"
# ============================================================

echo "=== Реєстрація кластерів в ArgoCD ==="

# Перевірка логіну в ArgoCD
if ! argocd account get-user-info &>/dev/null; then
  echo "ПОМИЛКА: Не залогінено в ArgoCD."
  echo "Виконайте: argocd login ${ARGOCD_SERVER} --username admin"
  exit 1
fi

# Функція реєстрації кластера
register_cluster() {
  local name="$1"
  local server="$2"
  local kubeconfig="$3"

  echo ""
  echo "--- Реєстрація кластера: ${name} (${server}) ---"

  if argocd cluster list | grep -q "${server}"; then
    echo "  Кластер вже зареєстровано, оновлюємо..."
    argocd cluster rm "${server}" --yes 2>/dev/null || true
  fi

  KUBECONFIG="${kubeconfig}" argocd cluster add \
    --name "${name}" \
    --server "${server}" \
    --kubeconfig "${kubeconfig}" \
    "$(KUBECONFIG=${kubeconfig} kubectl config current-context)" \
    --yes

  echo "  ✓ Кластер '${name}' зареєстровано"
}

# Шляхи до kubeconfig файлів (мають бути підготовлені заздалегідь)
DEV_KUBECONFIG="${HOME}/.kube/finpaybank-dev"
TEST_KUBECONFIG="${HOME}/.kube/finpaybank-test"
STAGE_DMZ_KUBECONFIG="${HOME}/.kube/finpaybank-stage-dmz"
STAGE_CDE_KUBECONFIG="${HOME}/.kube/finpaybank-stage-cde"
PROD_DMZ_KUBECONFIG="${HOME}/.kube/finpaybank-prod-dmz"
PROD_CDE_KUBECONFIG="${HOME}/.kube/finpaybank-prod-cde"

# Перевірка наявності kubeconfig файлів
for kc in "${DEV_KUBECONFIG}" "${TEST_KUBECONFIG}" \
           "${STAGE_DMZ_KUBECONFIG}" "${STAGE_CDE_KUBECONFIG}" \
           "${PROD_DMZ_KUBECONFIG}" "${PROD_CDE_KUBECONFIG}"; do
  if [ ! -f "${kc}" ]; then
    echo "ПОМИЛКА: Kubeconfig не знайдено: ${kc}"
    echo "Отримайте kubeconfig з кожної ноди:"
    echo "  ssh ubuntu@NODE_IP 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed 's/127.0.0.1/NODE_IP/' > ${kc}"
    exit 1
  fi
done

# Реєстрація кластерів
register_cluster "dev"       "https://${DEV_NODE_IP}:6443"   "${DEV_KUBECONFIG}"
register_cluster "test"      "https://${TEST_NODE_IP}:6443"  "${TEST_KUBECONFIG}"
register_cluster "stage-dmz" "https://${STAGE_DMZ_VIP}:6443" "${STAGE_DMZ_KUBECONFIG}"
register_cluster "stage-cde" "https://${STAGE_CDE_VIP}:6443" "${STAGE_CDE_KUBECONFIG}"
register_cluster "prod-dmz"  "https://${PROD_DMZ_VIP}:6443"  "${PROD_DMZ_KUBECONFIG}"
register_cluster "prod-cde"  "https://${PROD_CDE_VIP}:6443"  "${PROD_CDE_KUBECONFIG}"

echo ""
echo "=== Всі кластери зареєстровано ==="
echo ""
argocd cluster list
