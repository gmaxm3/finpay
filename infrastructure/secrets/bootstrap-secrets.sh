#!/usr/bin/env bash
# ==============================================================================
# bootstrap-secrets.sh — SOPS + age initial setup for FinPayBank GitOps
#
# Що робить:
#   1. Генерує age key pair для оператора (якщо не існує)
#   2. Генерує age key pair для ArgoCD CI/CD
#   3. Оновлює .sops.yaml з реальними публічними ключами
#   4. Створює зашифровані secret.yaml файли для всіх сервісів і середовищ
#   5. Оновлює overlay kustomization.yaml — додає secret.yaml до resources
#   6. Виводить kubectl команди для завантаження ключа в ArgoCD
#
# Використання:
#   ./infrastructure/secrets/bootstrap-secrets.sh
#
# Повторний запуск (якщо ключі вже є):
#   OPERATOR_KEY_FILE=~/.config/sops/age/keys.txt \
#   ARGOCD_KEY_FILE=./argocd-age-key.txt \
#   ./infrastructure/secrets/bootstrap-secrets.sh
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOPS_YAML="${REPO_ROOT}/.sops.yaml"

OPERATOR_KEY_FILE="${OPERATOR_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
ARGOCD_KEY_FILE="${ARGOCD_KEY_FILE:-${REPO_ROOT}/infrastructure/secrets/.argocd-age-key.txt}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ==============================================================================
# Перевірки
# ==============================================================================
check_deps() {
  local missing=()
  for cmd in sops age age-keygen; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    err "Потрібні інструменти не встановлені: ${missing[*]}\n   brew install sops age"
  fi
}

# ==============================================================================
# Генерація ключів
# ==============================================================================
generate_operator_key() {
  if [ -f "${OPERATOR_KEY_FILE}" ]; then
    warn "Operator key вже існує: ${OPERATOR_KEY_FILE}"
    OPERATOR_PUBKEY=$(grep "^# public key:" "${OPERATOR_KEY_FILE}" | awk '{print $NF}')
  else
    log "Генерація operator age key..."
    mkdir -p "$(dirname "${OPERATOR_KEY_FILE}")"
    age-keygen -o "${OPERATOR_KEY_FILE}"
    chmod 600 "${OPERATOR_KEY_FILE}"
    OPERATOR_PUBKEY=$(grep "^# public key:" "${OPERATOR_KEY_FILE}" | awk '{print $NF}')
    log "Operator key збережено: ${OPERATOR_KEY_FILE}"
    warn "ВАЖЛИВО: Збережіть цей ключ у password manager (1Password/Bitwarden)!"
    echo ""
    echo "  Приватний ключ (ЗАХИЩЕНИЙ — не показувати нікому):"
    grep "^AGE-SECRET-KEY" "${OPERATOR_KEY_FILE}"
    echo ""
  fi
}

generate_argocd_key() {
  if [ -f "${ARGOCD_KEY_FILE}" ]; then
    warn "ArgoCD key вже існує: ${ARGOCD_KEY_FILE}"
    ARGOCD_PUBKEY=$(grep "^# public key:" "${ARGOCD_KEY_FILE}" | awk '{print $NF}')
  else
    log "Генерація ArgoCD age key..."
    age-keygen -o "${ARGOCD_KEY_FILE}"
    chmod 600 "${ARGOCD_KEY_FILE}"
    ARGOCD_PUBKEY=$(grep "^# public key:" "${ARGOCD_KEY_FILE}" | awk '{print $NF}')
    log "ArgoCD key збережено: ${ARGOCD_KEY_FILE}"
  fi
}

# ==============================================================================
# Оновлення .sops.yaml
# ==============================================================================
update_sops_yaml() {
  log "Оновлення ${SOPS_YAML}..."
  # awk — портабельно (macOS і Linux)
  awk -v op="${OPERATOR_PUBKEY}" -v cd="${ARGOCD_PUBKEY}" '
    { gsub("AGE_PUBLIC_KEY_OPERATOR", op); gsub("AGE_PUBLIC_KEY_ARGOCD", cd); print }
  ' "${SOPS_YAML}" > "${SOPS_YAML}.tmp"
  mv "${SOPS_YAML}.tmp" "${SOPS_YAML}"
  log ".sops.yaml оновлено з реальними публічними ключами"
}

# ==============================================================================
# Генерація пароля
# ==============================================================================
gen_password() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

gen_cookie() {
  openssl rand -hex 32
}

# ==============================================================================
# Створення та шифрування secret файлу
# ==============================================================================
create_and_encrypt_secret() {
  local file="$1"
  local content="$2"

  if [ -f "${file}" ]; then
    warn "Вже існує (пропускаємо): ${file}"
    return
  fi

  mkdir -p "$(dirname "${file}")"
  echo "${content}" > "${file}"

  SOPS_AGE_KEY_FILE="${OPERATOR_KEY_FILE}" sops --encrypt --in-place "${file}"
  log "Зашифровано: ${file}"
}

# ==============================================================================
# Додавання secret.yaml до overlay kustomization.yaml
# ==============================================================================
add_secret_to_kustomization() {
  local kustomization="$1"
  local secret_name="$2"

  if grep -q "${secret_name}" "${kustomization}" 2>/dev/null; then
    return  # вже є
  fi

  # awk — портабельно (macOS і Linux)
  awk -v entry="  - ${secret_name}" '
    /^resources:/ { print; print entry; next }
    { print }
  ' "${kustomization}" > "${kustomization}.tmp"
  mv "${kustomization}.tmp" "${kustomization}"
}

# ==============================================================================
# Секрети для інфраструктурних сервісів
# ==============================================================================
create_rabbitmq_secrets() {
  log "Створення секретів для RabbitMQ..."
  local base_dir="${REPO_ROOT}/k8s-ops/apps/cde/rabbitmq/overlays"

  for env in dev test stage prod; do
    local ns
    case "${env}" in
      dev)   ns="dev-cde" ;;
      test)  ns="test-cde" ;;
      stage) ns="stage-cde" ;;
      prod)  ns="prod-cde" ;;
    esac

    local secret_file="${base_dir}/${env}/secret-rabbitmq.yaml"
    local password; password=$(gen_password)
    local cookie; cookie=$(gen_cookie)

    create_and_encrypt_secret "${secret_file}" "apiVersion: v1
kind: Secret
metadata:
  name: rabbitmq-admin-credentials
  namespace: ${ns}
type: Opaque
stringData:
  username: finpaybank-admin
  password: ${password}
  erlang-cookie: ${cookie}"

    add_secret_to_kustomization "${base_dir}/${env}/kustomization.yaml" "secret-rabbitmq.yaml"
  done
}

create_redis_secrets() {
  log "Створення секретів для Redis..."
  local base_dir="${REPO_ROOT}/k8s-ops/apps/cde/redis/overlays"

  for env in dev test stage prod; do
    local ns
    case "${env}" in
      dev)   ns="dev-cde" ;;
      test)  ns="test-cde" ;;
      stage) ns="stage-cde" ;;
      prod)  ns="prod-cde" ;;
    esac

    local secret_file="${base_dir}/${env}/secret-redis.yaml"
    local password; password=$(gen_password)

    create_and_encrypt_secret "${secret_file}" "apiVersion: v1
kind: Secret
metadata:
  name: redis-credentials
  namespace: ${ns}
type: Opaque
stringData:
  requirepass: ${password}"

    add_secret_to_kustomization "${base_dir}/${env}/kustomization.yaml" "secret-redis.yaml"
  done
}

create_elasticsearch_secrets() {
  log "Створення секретів для Elasticsearch..."
  local base_dir="${REPO_ROOT}/k8s-ops/apps/cde/elasticsearch/overlays"

  for env in dev test stage prod; do
    local ns
    case "${env}" in
      dev)   ns="dev-cde" ;;
      test)  ns="test-cde" ;;
      stage) ns="stage-cde" ;;
      prod)  ns="prod-cde" ;;
    esac

    local secret_file="${base_dir}/${env}/secret-elasticsearch.yaml"
    local password; password=$(gen_password)
    local seed; seed=$(gen_password)

    create_and_encrypt_secret "${secret_file}" "apiVersion: v1
kind: Secret
metadata:
  name: elasticsearch-credentials
  namespace: ${ns}
type: Opaque
stringData:
  username: elastic
  password: ${password}
  keystore.seed: ${seed}"

    add_secret_to_kustomization "${base_dir}/${env}/kustomization.yaml" "secret-elasticsearch.yaml"
  done
}

# ==============================================================================
# ArgoCD завантаження ключа
# ==============================================================================
print_argocd_instructions() {
  echo ""
  echo "============================================================"
  echo " НАСТУПНІ КРОКИ — завантажити ArgoCD key в кластер"
  echo "============================================================"
  echo ""
  info "1. Завантажити ArgoCD age key в management-node:"
  echo ""
  echo "   kubectl create secret generic sops-age-key \\"
  echo "     --namespace argocd \\"
  echo "     --from-file=key.txt=${ARGOCD_KEY_FILE}"
  echo ""
  info "2. Застосувати ArgoCD SOPS plugin:"
  echo ""
  echo "   kubectl apply -f ${REPO_ROOT}/infrastructure/secrets/sops-argocd-plugin.yaml"
  echo ""
  info "3. Підключити age key до argocd-repo-server:"
  echo ""
  cat <<'EOF'
   kubectl patch deployment argocd-repo-server -n argocd --patch '
   {"spec":{"template":{"spec":{
     "volumes":[{"name":"sops-age-key","secret":{"secretName":"sops-age-key"}}],
     "containers":[{"name":"argocd-repo-server","volumeMounts":[
       {"name":"sops-age-key","mountPath":"/sops-age-key","readOnly":true}
     ],"env":[
       {"name":"SOPS_AGE_KEY_FILE","value":"/sops-age-key/key.txt"}
     ]}]
   }}}}'
EOF
  echo ""
  info "4. Зберегти operator key у password manager:"
  echo "   ${OPERATOR_KEY_FILE}"
  echo ""
  warn "ArgoCD key файл (${ARGOCD_KEY_FILE}) НЕ є у .gitignore — не комітити!"
  echo ""
  echo "============================================================"
  echo " Публічні ключі (безпечно зберігати в .sops.yaml / Git):"
  echo "============================================================"
  echo "  Operator: ${OPERATOR_PUBKEY}"
  echo "  ArgoCD:   ${ARGOCD_PUBKEY}"
  echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  echo ""
  echo "=== FinPayBank SOPS + age Bootstrap ==="
  echo ""

  check_deps
  generate_operator_key
  generate_argocd_key

  # Перевірити чи .sops.yaml ще містить placeholder
  if grep -q "AGE_PUBLIC_KEY_OPERATOR" "${SOPS_YAML}"; then
    update_sops_yaml
  else
    warn ".sops.yaml вже містить реальні ключі — пропускаємо оновлення"
  fi

  export SOPS_AGE_KEY_FILE="${OPERATOR_KEY_FILE}"

  create_rabbitmq_secrets
  create_redis_secrets
  create_elasticsearch_secrets

  echo ""
  log "Всі секрети створено та зашифровано!"
  print_argocd_instructions
}

main "$@"
