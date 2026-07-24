#!/usr/bin/env bash
# ==============================================================================
# 04-add-registry-secrets.sh — Створення imagePullSecret у всіх namespace
#
# Два registry з однаковими credentials:
#   - hub.kapowai.com.ua
#   - finpaybank.kapowai.com.ua
#
# Використання:
#   export REGISTRY_USERNAME="your-username"
#   export REGISTRY_PASSWORD="your-password"
#   ./04-add-registry-secrets.sh
#
# Опціонально — вказати kubeconfig для конкретного кластера:
#   KUBECONFIG=~/.kube/finpaybank-dev ./04-add-registry-secrets.sh
# ==============================================================================
set -euo pipefail

SECRET_NAME="registry-credentials"
REGISTRIES=(
  "hub.kapowai.com.ua"
  "finpaybank.kapowai.com.ua"
)

# Перевірка credentials
if [ -z "${REGISTRY_USERNAME:-}" ] || [ -z "${REGISTRY_PASSWORD:-}" ]; then
  echo "ПОМИЛКА: Встановіть змінні оточення:"
  echo "  export REGISTRY_USERNAME='your-username'"
  echo "  export REGISTRY_PASSWORD='your-password'"
  exit 1
fi

# Namespace де потрібні secrets
# (автоматично визначаємо або беремо з env)
if [ -z "${TARGET_NAMESPACES:-}" ]; then
  # Спробуємо знайти всі наші namespace
  TARGET_NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' \
    | tr ' ' '\n' \
    | grep -E '^(dev|test|stage|prod)' \
    | tr '\n' ' ' \
    || echo "")

  if [ -z "${TARGET_NAMESPACES}" ]; then
    echo "ПОМИЛКА: Не знайдено жодного namespace. Вкажіть вручну:"
    echo "  TARGET_NAMESPACES='dev-dmz dev-cde' ./04-add-registry-secrets.sh"
    exit 1
  fi
fi

echo "=== Створення imagePullSecrets ==="
echo "Secret name: ${SECRET_NAME}"
echo "Namespaces: ${TARGET_NAMESPACES}"
echo "Registries:"
for reg in "${REGISTRIES[@]}"; do
  echo "  - ${reg}"
done
echo ""

# Функція створення docker config для кількох registry
create_docker_config() {
  local username="$1"
  local password="$2"

  # Генеруємо base64 auth для кожного registry
  local auths=""
  for reg in "${REGISTRIES[@]}"; do
    local auth
    auth=$(echo -n "${username}:${password}" | base64)
    if [ -n "${auths}" ]; then
      auths="${auths},"
    fi
    auths="${auths}\"${reg}\":{\"auth\":\"${auth}\",\"username\":\"${username}\",\"password\":\"${password}\"}"
  done

  echo "{\"auths\":{${auths}}}"
}

DOCKER_CONFIG=$(create_docker_config "${REGISTRY_USERNAME}" "${REGISTRY_PASSWORD}")
DOCKER_CONFIG_B64=$(echo -n "${DOCKER_CONFIG}" | base64)

# Створення/оновлення secret в кожному namespace
for ns in ${TARGET_NAMESPACES}; do
  echo "--- Namespace: ${ns} ---"

  # Перевірити чи існує namespace
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    echo "  Створення namespace ${ns}..."
    kubectl create namespace "${ns}"
    # PCI-DSS: додати label для network policies
    kubectl label namespace "${ns}" \
      "security-zone=$(echo ${ns} | grep -q 'cde' && echo 'cde' || echo 'dmz')" \
      "environment=$(echo ${ns} | cut -d'-' -f1)" \
      --overwrite
  fi

  # Створити або оновити secret
  kubectl create secret docker-registry "${SECRET_NAME}" \
    --namespace="${ns}" \
    --docker-server="${REGISTRIES[0]}" \
    --docker-username="${REGISTRY_USERNAME}" \
    --docker-password="${REGISTRY_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Додати другий registry до існуючого secret
  # (patch щоб додати обидва registry в один secret)
  kubectl patch secret "${SECRET_NAME}" \
    --namespace="${ns}" \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/data/.dockerconfigjson\",\"value\":\"${DOCKER_CONFIG_B64}\"}]"

  echo "  ✓ Secret '${SECRET_NAME}' оновлено в namespace '${ns}'"
done

# Також створити secret для Kargo (для доступу до registry при polling)
KARGO_NS="kargo"
if kubectl get namespace "${KARGO_NS}" &>/dev/null; then
  echo ""
  echo "--- Namespace: ${KARGO_NS} (для Kargo warehouse) ---"
  kubectl create secret docker-registry "${SECRET_NAME}" \
    --namespace="${KARGO_NS}" \
    --docker-server="${REGISTRIES[0]}" \
    --docker-username="${REGISTRY_USERNAME}" \
    --docker-password="${REGISTRY_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl patch secret "${SECRET_NAME}" \
    --namespace="${KARGO_NS}" \
    --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/data/.dockerconfigjson\",\"value\":\"${DOCKER_CONFIG_B64}\"}]"

  echo "  ✓ Secret '${SECRET_NAME}' оновлено в namespace '${KARGO_NS}'"
fi

echo ""
echo "=== imagePullSecrets створено в усіх namespace ==="
echo ""
echo "Перевірка:"
for ns in ${TARGET_NAMESPACES}; do
  echo "  kubectl get secret ${SECRET_NAME} -n ${ns}"
done
