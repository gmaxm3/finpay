# finpaybank-gitops

GitOps репозиторій для інтернет-банкінгу FinPayBank.
Архітектура відповідає вимогам PCI-DSS.

---

## Огляд архітектури

```
┌─────────────────────────────────────────────────────────────────┐
│                        MANAGEMENT NODE                           │
│                   ArgoCD Hub + Kargo                             │
│              (управляє всіма кластерами)                         │
└────────────────────────┬────────────────────────────────────────┘
                         │ kubectl/argocd
          ┌──────────────┼──────────────────┐
          │              │                  │
    ┌─────▼──────┐ ┌─────▼──────┐  ┌───────▼──────┐
    │  dev-node  │ │ test-node  │  │ stage-node-  │
    │  k3s       │ │  k3s       │  │ 1,2 k3s HA   │
    │  dev-dmz   │ │  test-dmz  │  │  stage-dmz   │
    │  dev-cde   │ │  test-cde  │  │  stage-cde   │
    └────────────┘ └────────────┘  └──────────────┘

    ┌──────────────────────────────────────────────┐
    │                   PROD                        │
    │                                               │
    │  ┌─────────────────┐  ┌───────────────────┐  │
    │  │  prod-dmz       │  │   prod-cde        │  │
    │  │  cluster        │  │   cluster         │  │
    │  │  (2 ноди)       │  │   (3 ноди)        │  │
    │  │  internet-      │  │   PCI-DSS scope   │  │
    │  │  facing         │  │   NO internet     │  │
    │  │                 │  │                   │  │
    │  │  namespace:prod │  │  namespace:prod   │  │
    │  └────────┬────────┘  └────────┬──────────┘  │
    └───────────│────────────────────│─────────────┘
                │ RabbitMQ:5672      │
                └────────────────────┘

    ┌──────────────────────────────────────────────┐
    │              OBSERVABILITY NODE               │
    │   Prometheus + Loki + Grafana + Alertmanager  │
    └──────────────────────────────────────────────┘

    ┌──────────────────────────────────────────────┐
    │              POSTGRESQL (bare metal)          │
    │   db-primary + db-replica                     │
    │   Доступ ТІЛЬКИ з CDE namespace               │
    └──────────────────────────────────────────────┘
```

### Зони безпеки

| Зона | Label | Internet | Сервіси |
|------|-------|----------|---------|
| DMZ | `zone: dmz` | ТАК | frontend, nginx, push-gateway, sms |
| CDE | `zone: cde` | НІ | ESB (cards, payments, deposits...), Redis, RabbitMQ |

---

## Prerequisites

Встановити локально:

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"

# ArgoCD CLI
brew install argocd

# Kargo CLI
brew install akuity/tap/kargo

# sops + age (secret management)
brew install sops age

# git diff для SOPS-зашифрованих файлів (показує розшифрований diff)
git config --global diff.sopsdiffer.textconv "sops -d --config /dev/null"

# helm (для infrastructure компонентів)
brew install helm

# kustomize (вбудований в kubectl, але окремо для перевірки)
brew install kustomize
```

---

## Bootstrap (покрокове налаштування)

> **Важливо**: виконувати кроки строго по порядку.
> Кожен скрипт ідемпотентний — можна запускати повторно.

### Крок 1: Встановлення k3s на ноди

```bash
# На кожній ноді (замінити NODE_IP та NODE_ROLE):

# Dev нода:
ssh ubuntu@DEV_NODE_IP "bash -s" < scripts/bootstrap/01-install-k3s.sh

# Test нода:
ssh ubuntu@TEST_NODE_IP "bash -s" < scripts/bootstrap/01-install-k3s.sh

# Stage ноди (HA):
ssh ubuntu@STAGE_NODE_1_IP "bash -s" < scripts/bootstrap/01-install-k3s.sh
ssh ubuntu@STAGE_NODE_2_IP "INSTALL_K3S_EXEC='agent' bash -s" < scripts/bootstrap/01-install-k3s.sh

# Prod DMZ ноди:
ssh ubuntu@PROD_DMZ_NODE_1_IP "bash -s" < scripts/bootstrap/01-install-k3s.sh
ssh ubuntu@PROD_DMZ_NODE_2_IP "INSTALL_K3S_EXEC='agent' bash -s" < scripts/bootstrap/01-install-k3s.sh

# Prod CDE ноди:
ssh ubuntu@PROD_CDE_NODE_1_IP "bash -s" < scripts/bootstrap/01-install-k3s.sh
ssh ubuntu@PROD_CDE_NODE_2_IP "INSTALL_K3S_EXEC='agent' bash -s" < scripts/bootstrap/01-install-k3s.sh
ssh ubuntu@PROD_CDE_NODE_3_IP "INSTALL_K3S_EXEC='agent --node-taint dedicated=data:NoSchedule' bash -s" < scripts/bootstrap/01-install-k3s.sh
```

Отримати kubeconfig з кожної ноди та зберегти:
```bash
# Приклад для dev:
ssh ubuntu@DEV_NODE_IP "sudo cat /etc/rancher/k3s/k3s.yaml" | \
  sed 's/127.0.0.1/DEV_NODE_IP/' > ~/.kube/finpaybank-dev
```

### Крок 2: Встановлення ArgoCD на management node

```bash
ssh ubuntu@MANAGEMENT_NODE_IP "bash -s" < scripts/bootstrap/02-install-argocd.sh

# Отримати початковий пароль:
ssh ubuntu@MANAGEMENT_NODE_IP \
  "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

### Крок 3: Реєстрація кластерів в ArgoCD

```bash
# Логін в ArgoCD:
argocd login ARGOCD_EXTERNAL_IP --username admin

# Реєстрація всіх кластерів:
scripts/bootstrap/05-add-clusters-argocd.sh
```

Скрипт реєструє кластери:
- `dev` → `https://DEV_NODE_IP:6443`
- `test` → `https://TEST_NODE_IP:6443`
- `stage` → `https://STAGE_NODE_VIP:6443`
- `prod-dmz` → `https://PROD_DMZ_VIP:6443`
- `prod-cde` → `https://PROD_CDE_VIP:6443`

### Крок 4: Встановлення Kargo

```bash
# Перед встановленням Kargo у management cluster має бути cert-manager:
kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=120s

# Підготувати admin password hash і token signing key:
export KARGO_ADMIN_PASSWORD_HASH="$(htpasswd -bnBC 10 "" 'STRONG_PASSWORD' | tr -d ':\n')"
export KARGO_TOKEN_SIGNING_KEY="$(openssl rand -base64 48 | tr -d '=+/' | head -c 32)"

ssh ubuntu@MANAGEMENT_NODE_IP "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash -s" < scripts/bootstrap/03-install-kargo.sh
```

Налаштування credentials (виконується вручну — деталі в [k8s-ops/kargo/CREDENTIALS.md](k8s-ops/kargo/CREDENTIALS.md)):
```bash
# Git credentials (Bitbucket repo access token)
kubectl create secret generic kargo-git-credentials \
  --namespace kargo \
  --from-literal=type=git \
  --from-literal=url=git@bitbucket.org:Kapowai \
  --from-literal=username=x-token-auth \
  --from-literal=password="BITBUCKET_REPO_ACCESS_TOKEN"
kubectl label secret kargo-git-credentials -n kargo \
  kargo.akuity.io/secret-type=repository

# ArgoCD integration + Registry credentials:
scripts/bootstrap/06-bootstrap-kargo.sh
```

Застосувати Kargo RBAC та конфігурацію:
```bash
kubectl apply -k k8s-ops/kargo/
```

### Крок 5: Додавання registry secrets

```bash
# Встановити credentials у змінні оточення:
export REGISTRY_USERNAME="YOUR_USERNAME"
export REGISTRY_PASSWORD="YOUR_PASSWORD"

# Виконати скрипт (створить imagePullSecret у всіх namespace):
scripts/bootstrap/04-add-registry-secrets.sh
```

Скрипт створить secret `registry-credentials` в namespace:
- `dev-dmz`, `dev-cde`
- `test-dmz`, `test-cde`
- `stage-dmz`, `stage-cde`
- `prod` (prod-dmz кластер)
- `prod` (prod-cde кластер)

### Крок 6: Деплой інфраструктурних компонентів

Виконувати строго по порядку (залежності між компонентами):

```bash
# 6.1 cert-manager (має бути готовий перед іншими компонентами)
kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=120s

# 6.2 Secret management — SOPS + age
# Секрети вже зашифровані в Git. Потрібно тільки:
# а) Завантажити ArgoCD age key (один раз після bootstrap-secrets.sh):
kubectl create secret generic sops-age-key \
  --namespace argocd \
  --from-file=key.txt=infrastructure/secrets/.argocd-age-key.txt

# б) Застосувати ArgoCD SOPS plugin:
kubectl apply -f infrastructure/secrets/sops-argocd-plugin.yaml

# Далі ArgoCD сам розшифровує секрети при sync.
# Детально: infrastructure/secrets/README.md

# 6.3 Моніторинг на observability node
# Спочатку Prometheus + Grafana на observability node:
KUBECONFIG=~/.kube/finpaybank-observability \
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version 58.3.1 \
  -f infrastructure/monitoring/values.yaml

# Потім Loki:
KUBECONFIG=~/.kube/finpaybank-observability \
kubectl apply -k infrastructure/monitoring/

# 6.4 Prometheus Agent на кожен workload кластер (через ArgoCD):
kubectl apply -f infrastructure/monitoring/prometheus-agent.yaml -n argocd
```

### Крок 7: Перший ArgoCD sync

```bash
# Застосувати ArgoCD проекти:
kubectl apply -f k8s-ops/argocd/projects/

# Застосувати ApplicationSets:
kubectl apply -f k8s-ops/argocd/applicationsets/

# ArgoCD автоматично почне синхронізацію dev та test середовищ
# Перевірити статус:
argocd app list
```

---

## Сервіси

### DMZ зона (internet-facing)

| Сервіс | Директорія | Image | Тип | Internet |
|--------|-----------|-------|-----|---------|
| nginx (balancer) | `k8s-ops/apps/dmz/nginx/` | `nginx:1.27` | Deployment + IngressRoute | — |
| static | `k8s-ops/apps/dmz/static/` | `finpaybank.kapowai.com.ua/finpaybank/static:26.03.1` | Deployment | — |
| onboarding-web | `k8s-ops/apps/dmz/onboarding-web/` | `finpay.kapowai.com.ua/webviews-on-boarding:1.0.0` | Deployment | — |
| push-gateway | `k8s-ops/apps/dmz/push-gateway/` | `finpaybank.kapowai.com.ua/finpaybank/push-gateway:26.01.1` | Deployment | FCM :443 |
| sms | `k8s-ops/apps/dmz/sms/` | `hub.kapowai.com.ua/finpaybank/sms:26.02.1` | Deployment | SMS :443 |
| kyc-liveness-web | `k8s-ops/apps/dmz/kyc-liveness-web/` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-web:25.08.01` | Deployment | — |

### CDE зона — StatefulSets (PCI-DSS scope)

| Сервіс | Директорія | Image | Storage |
|--------|-----------|-------|---------|
| redis | `k8s-ops/apps/cde/redis/` | `redis:8` | 10Gi (prod: 50Gi) |
| rabbitmq | `k8s-ops/apps/cde/rabbitmq/` | `rabbitmq:4-management` | 10Gi (prod: 50Gi) |
| elasticsearch | `k8s-ops/apps/cde/elasticsearch/` | `elasticsearch:7.4.2` | 50Gi (prod: 200Gi) |
| minio | `k8s-ops/apps/cde/minio/` | `minio/minio` | 50Gi |

### CDE зона — ESB Deployments (PCI-DSS scope)

| Сервіс | Директорія | Image | Примітки |
|--------|-----------|-------|---------|
| api-gateway | `k8s-ops/apps/cde/api-gateway/` | `nginx:1.27` | Internal router (cards/identity/customer) |
| identity | `k8s-ops/apps/cde/identity/` | `hub.kapowai.com.ua/finpaybank/identity:25.09.3` | — |
| cards | `k8s-ops/apps/cde/cards/` | `finpaybank.kapowai.com.ua/finpaybank/cards:latest` | PCI certs (SealedSecret) |
| cards-worker | `k8s-ops/apps/cde/cards-worker/` | `finpaybank.kapowai.com.ua/finpaybank/cards-worker:latest` | — |
| customer | `k8s-ops/apps/cde/customer/` | `finpaybank.kapowai.com.ua/finpaybank/customer:latest` | — |
| banks | `k8s-ops/apps/cde/banks/` | `finpaybank.kapowai.com.ua/finpaybank/banks:latest` | → elasticsearch |
| banks-worker | `k8s-ops/apps/cde/banks-worker/` | `finpaybank.kapowai.com.ua/finpaybank/banks-worker:latest` | → elasticsearch |
| ukrcard | `k8s-ops/apps/cde/ukrcard/` | `finpaybank.kapowai.com.ua/finpaybank/ukrcard:latest` | PCI certs (ПЦ/АБС) |
| payments | `k8s-ops/apps/cde/payments/` | `finpaybank.kapowai.com.ua/finpaybank/payments:latest` | 2x approval prod |
| password-recovery | `k8s-ops/apps/cde/password-recovery/` | `finpaybank.kapowai.com.ua/finpaybank/password-recovery:26.03.4` | — |
| customers-update | `k8s-ops/apps/cde/customers-update/` | `finpaybank.kapowai.com.ua/finpaybank/customers-update:26.01.7` | — |
| notifications | `k8s-ops/apps/cde/notifications/` | `finpaybank.kapowai.com.ua/finpaybank/notifications:latest` | — |
| notifications-worker | `k8s-ops/apps/cde/notifications-worker/` | `finpaybank.kapowai.com.ua/finpaybank/notifications-worker:latest` | — |
| qr | `k8s-ops/apps/cde/qr/` | `finpaybank.kapowai.com.ua/finpaybank/finpay-qr:latest` | — |
| print-reports | `k8s-ops/apps/cde/print-reports/` | `finpaybank.kapowai.com.ua/finpaybank/finpay-print:latest` | — |
| ukrpost | `k8s-ops/apps/cde/ukrpost/` | `hub.kapowai.com.ua/finpaybank/ukrpost-client:26.02.3` | External API |
| onboarding | `k8s-ops/apps/cde/onboarding/` | `finpaybank.kapowai.com.ua/finpaybank/onboarding:26.03.11` | ESB onboarding flow |
| vkursi | `k8s-ops/apps/cde/vkursi/` | `hub.kapowai.com.ua/finpaybank/vkursi-client:26.02.4` | External API |
| transactions | `k8s-ops/apps/cde/transactions/` | `finpaybank.kapowai.com.ua/finpaybank/transactions:latest` | — |
| transactions-worker | `k8s-ops/apps/cde/transactions-worker/` | `finpaybank.kapowai.com.ua/finpaybank/transactions-worker:latest` | — |
| image2text | `k8s-ops/apps/cde/image2text/` | `hub.kapowai.com.ua/finpaybank/image2text-service:1.0.0` | — |
| check-for-update | `k8s-ops/apps/cde/check-for-update/` | `hub.kapowai.com.ua/finpaybank/check-for-update:latest` | — |
| maintenance | `k8s-ops/apps/cde/maintenance/` | `hub.kapowai.com.ua/finpaybank/maintenance:21.2.1` | — |
| kyc-liveness-service | `k8s-ops/apps/cde/kyc-liveness-service/` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-service:25.08.01` | → minio, postgres |
| kyc-liveness-worker | `k8s-ops/apps/cde/kyc-liveness-worker/` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-service:25.09.01` | → minio |

---

## Додавання нового сервісу

Детальна процедура в [AGENT.md](AGENT.md) (розділ 3).

Коротко:
```bash
# 1. Скопіювати template (dmz або cde)
cp -r k8s-ops/apps/dmz/_template k8s-ops/apps/dmz/my-service

# 2. Замінити плейсхолдери
find k8s-ops/apps/dmz/my-service -type f -exec \
  sed -i 's/SERVICE_NAME/my-service/g' {} \;

# 3. Налаштувати Kargo pipeline
cp -r k8s-ops/kargo/_template k8s-ops/kargo/my-service
find k8s-ops/kargo/my-service -type f -exec \
  sed -i 's/SERVICE_NAME/my-service/g' {} \;

# 4. Скрипт для автоматизації:
scripts/maintenance/add-new-service.sh my-service dmz
```

---

## Promotion workflow (Kargo)

```
┌─────────┐    auto     ┌─────────┐    auto     ┌──────────────┐
│   dev   │ ──────────► │  test   │ ──────────► │    stage     │
│  (CI    │             │         │  (manual    │  (manual     │
│  push)  │             │         │   approval) │   approval)  │
└─────────┘             └─────────┘             └──────┬───────┘
                                                        │
                                              manual approval
                                              (2x для payments)
                                                        │
                                                ┌───────▼──────┐
                                                │     prod     │
                                                │  (ArgoCD UI) │
                                                └──────────────┘
```

### Команди Kargo:
```bash
# Переглянути статус promotion:
kargo get freights --project my-service

# Запросити promotion на stage:
kargo promote --project my-service --freight FREIGHT_ID --stage stage

# Переглянути pending approvals:
kargo get promotions --project my-service
```

---

## Troubleshooting

### Pod не стартує
```bash
kubectl describe pod POD_NAME -n NAMESPACE
kubectl logs POD_NAME -n NAMESPACE --previous
```

### ImagePullBackOff
```bash
# Перевірити що imagePullSecret існує:
kubectl get secret registry-credentials -n NAMESPACE

# Оновити credentials:
scripts/maintenance/rotate-registry-secrets.sh
```

### ArgoCD OutOfSync
```bash
# Перевірити diff:
argocd app diff APP_NAME

# Примусова синхронізація (тільки dev/test):
argocd app sync APP_NAME
```

### NetworkPolicy блокує трафік
```bash
# Перевірити NetworkPolicy:
kubectl get networkpolicy -n NAMESPACE
kubectl describe networkpolicy POLICY_NAME -n NAMESPACE

# Тест з'єднання (debug pod):
kubectl run tmp-debug --image=busybox -it --rm -n NAMESPACE -- sh
# Всередині: nc -zv TARGET_SERVICE PORT
```

### Kargo warehouse не бачить нові images
```bash
# Перевірити статус warehouse:
kargo get warehouse SERVICE_NAME -n kargo

# Перевірити credentials до registry:
kubectl get secret registry-credentials -n kargo
```

---

## Оновлення registry credentials

```bash
# Встановити нові credentials:
export REGISTRY_USERNAME="NEW_USERNAME"
export REGISTRY_PASSWORD="NEW_PASSWORD"

# Оновити у всіх namespace:
scripts/maintenance/rotate-registry-secrets.sh
```

> Скрипт оновлює secret `registry-credentials` у всіх namespace без downtime.

---

## Додаткові ресурси

- [AGENT.md](AGENT.md) — інструкції для автоматизації та AI-асистентів
- [infrastructure/secrets/README.md](infrastructure/secrets/README.md) — управління секретами
- [ArgoCD UI](https://ARGOCD_EXTERNAL_IP) — інтерфейс ArgoCD
- [Kargo UI](https://KARGO_EXTERNAL_IP) — інтерфейс Kargo
