#!/usr/bin/env bash
# ==============================================================================
# 06-bootstrap-kargo.sh — Початкове налаштування Kargo
#
# Налаштовує:
#   - Git credentials (SSH key з write access — потрібен окремий від ArgoCD)
#   - Registry credentials для warehouse (через kargo CLI)
#   - ArgoCD integration
#
# Передумови: ArgoCD вже підключений до репо (крок 02/05)
#
# ВАЖЛИВО щодо SSH ключів:
#   ArgoCD SSH key зазвичай READ-ONLY (Deploy Key) → Kargo не може push
#   Kargo потребує ОКРЕМИЙ SSH ключ з write access до Bitbucket репо
#
#   Варіант A (рекомендований): згенерувати новий ключ автоматично
#     export KARGO_SSH_KEY_FILE=""   # залишити порожнім
#     Скрипт згенерує ключ і покаже public key для додавання до Bitbucket
#
#   Варіант B: використати існуючий ключ з write access
#     export KARGO_SSH_KEY_FILE=/path/to/private_key
#
#   Після генерації: Bitbucket → Repo settings → Access keys → Add key
#     Label: kargo-deployment, Permission: WRITE
# ==============================================================================
set -euo pipefail

KARGO_NAMESPACE="kargo"

echo "=== Налаштування Kargo ==="

# Перевірка змінних
REQUIRED_VARS=(
  "REGISTRY_USERNAME"        # Credentials для image registry
  "REGISTRY_PASSWORD"
  "ARGOCD_TOKEN"             # ArgoCD token для інтеграції
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ПОМИЛКА: Змінна ${var} не встановлена"
    echo ""
    echo "Необхідні змінні:"
    for v in "${REQUIRED_VARS[@]}"; do
      echo "  export ${v}='...'"
    done
    exit 1
  fi
done

# ==============================================================================
# Git credentials для Kargo (SSH з write access)
#
# ВАЖЛИВО: Kargo v1.x вимагає:
#   1. Secret type: Opaque (НЕ kubernetes.io/ssh-auth)
#   2. Label: kargo.akuity.io/cred-type=git
#   3. Fields: repoURL, sshPrivateKey (або username/password)
#   4. SSH key треба зберігати через --from-file (НЕ --from-literal)
#      щоб зберегти trailing newline — без нього libcrypto fails
#   5. Per-project credentials: secret має бути В КОЖНОМУ project namespace
#      (не тільки в глобальному kargo namespace)
#
# repoURLIsRegex=true + repoURL=bitbucket.org дозволяє матчити будь-який
# репозиторій на bitbucket.org — один secret покриває всі проекти
# ==============================================================================
echo "--- Налаштування Git credentials для Kargo ---"

TMPKEY_WITHLN=$(mktemp)
CLEANUP_TMPKEY=""

if [ -n "${KARGO_SSH_KEY_FILE:-}" ]; then
  if [ ! -f "${KARGO_SSH_KEY_FILE}" ]; then
    echo "ПОМИЛКА: Файл ${KARGO_SSH_KEY_FILE} не знайдено"
    rm -f "${TMPKEY_WITHLN}"
    exit 1
  fi
  cp "${KARGO_SSH_KEY_FILE}" "${TMPKEY_WITHLN}"
  echo "" >> "${TMPKEY_WITHLN}"
  echo "  Використовуємо SSH key з ${KARGO_SSH_KEY_FILE}"
else
  echo "  KARGO_SSH_KEY_FILE не встановлено"
  echo "  Генеруємо новий ED25519 SSH key для Kargo..."
  GENERATED_KEY=$(mktemp /tmp/kargo-ssh-XXXXXX)
  ssh-keygen -t ed25519 -C "kargo@finpaybank-gitops" -f "${GENERATED_KEY}" -N "" -q
  cp "${GENERATED_KEY}" "${TMPKEY_WITHLN}"
  echo "" >> "${TMPKEY_WITHLN}"
  CLEANUP_TMPKEY="${GENERATED_KEY}"

  echo ""
  echo "  =============================================================="
  echo "  ДОДАЙТЕ ЦЕЙ PUBLIC KEY ДО BITBUCKET (потрібен WRITE access):"
  echo "  Bitbucket → finpaybank-gitops → Settings → Access keys → Add"
  echo "  Label: kargo-deployment"
  echo "  Permission: WRITE"
  echo ""
  echo "  Public key:"
  cat "${GENERATED_KEY}.pub"
  rm -f "${GENERATED_KEY}.pub"
  echo "  =============================================================="
  echo ""
  echo "  Збережіть private key для повторного запуску:"
  echo "    cp ${GENERATED_KEY} ~/.kargo-deploy-key"
  echo "    export KARGO_SSH_KEY_FILE=~/.kargo-deploy-key"
  echo ""
fi

# Усі проекти — list з 06-bootstrap-kargo.sh
ALL_PROJECTS="banks banks-worker cards cards-worker check-for-update customer \
  customers-update identity image2text kyc-liveness-service kyc-liveness-web \
  kyc-liveness-worker maintenance nginx notifications notifications-worker \
  onboarding onboarding-web password-recovery payments print-reports push-gateway \
  qr rabbitmq redis sms static transactions transactions-worker ukrcard ukrpost vkursi"

# Global credential в kargo namespace
kubectl create secret generic kargo-git-credentials \
  --namespace="${KARGO_NAMESPACE}" \
  --from-literal=repoURL="git@bitbucket.org:Kapowai/finpaybank-gitops.git" \
  --from-file=sshPrivateKey="${TMPKEY_WITHLN}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label secret kargo-git-credentials -n "${KARGO_NAMESPACE}" \
  "kargo.akuity.io/cred-type=git" --overwrite

# Per-project credentials (ОБОВ'ЯЗКОВО для promotion git clone/push)
# Kargo шукає credentials в namespace поточного project, а не в глобальному kargo
echo "  Створення bitbucket-git secrets в project namespaces..."
for PROJECT in ${ALL_PROJECTS}; do
  kubectl create secret generic bitbucket-git \
    --namespace="${PROJECT}" \
    --from-literal=repoURL="bitbucket.org" \
    --from-literal=repoURLIsRegex="true" \
    --from-file=sshPrivateKey="${TMPKEY_WITHLN}" \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || \
    echo "    (namespace ${PROJECT} ще не існує — запустіть після apply projects)"
  kubectl label secret bitbucket-git -n "${PROJECT}" \
    "kargo.akuity.io/cred-type=git" --overwrite 2>/dev/null || true
done

rm -f "${TMPKEY_WITHLN}"
[ -n "${CLEANUP_TMPKEY:-}" ] && rm -f "${CLEANUP_TMPKEY}"

echo "  ✓ Git SSH credentials створено (kargo namespace + всі project namespaces)"

# ==============================================================================
# ArgoCD integration credentials
# ==============================================================================
echo "--- Налаштування ArgoCD integration ---"
kubectl create secret generic kargo-argocd-token \
  --namespace="${KARGO_NAMESPACE}" \
  --from-literal=token="${ARGOCD_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ ArgoCD credentials створено"

# ==============================================================================
# Registry credentials
#
# ВАЖЛИВО: Kargo v1.x вимагає credentials через `kargo create credentials` CLI
#   - Правильний label: kargo.akuity.io/cred-type=image
#   - dockerconfigjson тип НЕ підтримується для warehouse image discovery
#   - Credentials мають бути в кожному project namespace
#
# Registry routing:
#   Hub (Harbor) → hub.kapowai.com.ua:
#     identity, kyc-liveness-*, maintenance, check-for-update, sms,
#     image2text (image: image2text-service), ukrpost (image: ukrpost-client),
#     vkursi (image: vkursi-client)
#   Nexus → finpaybank.kapowai.com.ua:
#     всі інші CDE сервіси
# ==============================================================================
echo "--- Зберігаємо registry credentials для pod image pull (kubelet) ---"
kubectl create secret docker-registry registry-credentials \
  --namespace="${KARGO_NAMESPACE}" \
  --docker-server="hub.kapowai.com.ua" \
  --docker-username="${REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✓ Registry pull secret збережено (для kubelet)"

echo "--- Створення Kargo warehouse credentials через CLI ---"
# Логін в Kargo обов'язковий перед цим кроком:
#   kargo login https://KARGO_SERVER --admin --insecure-skip-tls-verify

HUB_PROJECTS="identity kyc-liveness-service kyc-liveness-web kyc-liveness-worker maintenance check-for-update sms image2text ukrpost vkursi"
NEXUS_PROJECTS="banks banks-worker cards cards-worker customer customers-update notifications notifications-worker onboarding onboarding-web password-recovery payments print-reports push-gateway qr rabbitmq redis static transactions transactions-worker ukrcard"

for PROJECT in ${HUB_PROJECTS}; do
  kargo create credentials hub-registry \
    --project="${PROJECT}" \
    --image \
    --repo-url="hub.kapowai.com.ua" \
    --regex \
    --username="${REGISTRY_USERNAME}" \
    --password="${REGISTRY_PASSWORD}" 2>/dev/null || \
  echo "  (hub-registry вже існує в ${PROJECT})"
done

for PROJECT in ${NEXUS_PROJECTS}; do
  kargo create credentials nexus-registry \
    --project="${PROJECT}" \
    --image \
    --repo-url="finpaybank.kapowai.com.ua" \
    --regex \
    --username="${REGISTRY_USERNAME}" \
    --password="${REGISTRY_PASSWORD}" 2>/dev/null || \
  echo "  (nexus-registry вже існує в ${PROJECT})"
done

echo "  ✓ Kargo warehouse credentials створено"

# ==============================================================================
# Застосування Kargo projects
# Порядок важливий: спочатку Project (створює namespace), потім решта
# ==============================================================================
echo "--- Застосування Kargo projects ---"
find k8s-ops/kargo -mindepth 2 -name "project.yaml" \
  ! -path "k8s-ops/kargo/_template/*" \
  -exec kubectl apply -f {} \;

echo "  Чекаємо на створення namespace-ів..."
sleep 5

find k8s-ops/kargo -mindepth 2 \( -name "warehouse.yaml" -o -name "stages.yaml" -o -name "project-config.yaml" \) \
  ! -path "k8s-ops/kargo/_template/*" ! -name "kustomization.yaml" \
  -exec kubectl apply -f {} \;

# Повторно створюємо git credentials — namespace-и вже існують
echo "  Повторне створення bitbucket-git після apply projects..."
TMPKEY_WITHLN2=$(mktemp)
if [ -n "${KARGO_SSH_KEY_FILE:-}" ]; then
  cp "${KARGO_SSH_KEY_FILE}" "${TMPKEY_WITHLN2}"
  echo "" >> "${TMPKEY_WITHLN2}"
else
  echo "  УВАГА: KARGO_SSH_KEY_FILE не встановлено, пропускаємо повторне створення"
  rm -f "${TMPKEY_WITHLN2}"
  TMPKEY_WITHLN2=""
fi

if [ -n "${TMPKEY_WITHLN2:-}" ]; then
  for PROJECT in ${ALL_PROJECTS}; do
    kubectl create secret generic bitbucket-git \
      --namespace="${PROJECT}" \
      --from-literal=repoURL="bitbucket.org" \
      --from-literal=repoURLIsRegex="true" \
      --from-file=sshPrivateKey="${TMPKEY_WITHLN2}" \
      --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    kubectl label secret bitbucket-git -n "${PROJECT}" \
      "kargo.akuity.io/cred-type=git" --overwrite 2>/dev/null || true
  done
  rm -f "${TMPKEY_WITHLN2}"
  echo "  ✓ bitbucket-git secrets оновлено"
fi

echo ""
echo "=== Kargo bootstrap завершено ==="
echo ""
echo "Перевірка:"
echo "  kargo login https://KARGO_SERVER --admin"
echo "  kargo get projects"
echo "  kargo get warehouses --project=image2text"
