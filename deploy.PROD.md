# Deploy PROD Environment

Цей файл описує розгортання `prod` середовища, яке складається з **двох окремих k3s кластерів**:

- **prod-dmz** — інтернет-facing кластер, namespace `prod-dmz` (cde-proxy, push-gateway, sms, static)
- **prod-cde** — PCI-DSS кластер, без інтернету, namespace `prod-cde` (ESB сервіси, Redis, RabbitMQ, PostgreSQL access)

Prod **повністю керується ArgoCD** — sync тільки вручну через UI або Kargo після human approval (вимога PCI-DSS). Automated sync вимкнено.

Управляючий кластер (ArgoCD + Kargo) описаний в [deploy.MGMT.md](deploy.MGMT.md) і має бути запущений до початку розгортання prod.

---

## 1. Що потрібно до старту

**Інфраструктура:**

- Два сервери для prod кластерів:
  - `prod-node-dmz` — DMZ кластер (`10.201.97.10`): інтернет-facing
  - `prod-node-cde` — CDE кластер (`10.201.98.10`): без інтернету
- `sudo` права для користувача `ubuntu` на обох нодах

**Мережа:**

- `prod-node-dmz` (`10.201.97.10`) — має доступ до інтернету (Let's Encrypt, FCM, SMS)
- `prod-node-cde` (`10.201.98.10`) — **не має** доступу до інтернету; PostgreSQL доступний за `10.201.99.10`
- Між кластерами:
  - prod-dmz → prod-cde **порт 5672** (RabbitMQ)
  - prod-dmz → prod-cde **порт 30443** (CDE Traefik NodePort — HTTPS, через IngressRoute + ServersTransport)

**Management кластер:**
- ArgoCD запущений і доступний (`argocd login` проходить)
- Kargo запущений і доступний
- SOPS age key завантажено в ArgoCD namespace (крок 4а в `deploy.MGMT.md`)

**Доступи:**
- Docker registry (`hub.kapowai.com.ua`, `finpaybank.kapowai.com.ua`)
- Bitbucket (SSH ключ для ArgoCD вже в Bitbucket)
- PostgreSQL для prod

**Локально на адміністративній машині:**

```bash
brew install kubectl helm kustomize sops age argocd
mkdir -p ~/.kube
cd /Users/xeon/work/kapowai/finpaybank/finpaybank-gitops
```

---

## 2. Визначити змінні

Створити `environments/prod.env` на основі `environments/stage.env`:

```bash
cp environments/stage.env environments/prod.env
```

Заповнити значення:

```bash
# environments/prod.env

export PROD_DMZ_HOST="10.201.97.10"
export PROD_CDE_HOST="10.201.98.10"

export PROD_DMZ_VIP="10.201.97.10"
export PROD_CDE_VIP="10.201.98.10"

export PROD_POSTGRES_PRIMARY_IP="10.201.99.10"
export PROD_POSTGRES_REPLICA_IP="<REPLACE_PROD_POSTGRES_REPLICA_IP>"  # заповнити коли буде replica

export PROD_PUBLIC_DOMAIN="online.finpay.com.ua"
export ACME_EMAIL="vladimir.fesik@kapowai.online"
```

Завантажити в shell:

```bash
set -a
source environments/prod.env
set +a

export PROD_DMZ_SSH="ssh ${PROD_DMZ_HOST} -l ubuntu"
export PROD_CDE_SSH="ssh ${PROD_CDE_HOST} -l ubuntu"
```

---

## 3. Замінити prod-плейсхолдери в repo

Перед першим деплоєм замінити всі плейсхолдери:

```bash
rg -n "PROD_DMZ_VIP\|PROD_CDE_VIP\|REPLACE_PROD" \
  k8s-ops infrastructure scripts/bootstrap
```

Критичні файли для prod:

```text
PROD_DMZ_VIP → 10.201.97.10
  k8s-ops/argocd/projects/prod-dmz-project.yaml
  k8s-ops/argocd/projects/logging-project.yaml
  k8s-ops/argocd/applicationsets/prod-dmz-appset.yaml
  k8s-ops/argocd/applicationsets/logging-appset.yaml
  infrastructure/reloader/applicationset.yaml
  infrastructure/monitoring/prometheus-agent.yaml

PROD_CDE_VIP → 10.201.98.10
  k8s-ops/argocd/projects/prod-cde-project.yaml
  k8s-ops/argocd/projects/logging-project.yaml
  k8s-ops/argocd/applicationsets/prod-cde-appset.yaml
  k8s-ops/argocd/applicationsets/logging-appset.yaml
  infrastructure/reloader/applicationset.yaml
  infrastructure/monitoring/prometheus-agent.yaml

REPLACE_PROD_POSTGRES_IP → 10.201.99.10
  k8s-ops/apps/cde/shared-network/overlays/prod/kustomization.yaml

0.0.0.1/32 # TODO webplatform
  k8s-ops/apps/cde/shared-network/overlays/prod/kustomization.yaml
  (замінити на реальний IP webplatform для prod — REPLACE_PROD_WEBPLATFORM_IP)
```

> **Примітка:** DMZ NetworkPolicy для порту 30443 вже містить `10.201.98.10/32` —
> `k8s-ops/apps/dmz/shared-network/overlays/prod/kustomization.yaml`. Це правильний CDE VIP.

> **Hostname API (`online.finpay.com.ua`) вже вшитий** в kustomize overlay-патчах
> (`overlays/prod/kustomization.yaml` кожного CDE сервісу та `cde-proxy/overlays/prod/ingressroute.yaml`).
> Ручна заміна не потрібна.

Перевірити після змін:

```bash
git diff -- k8s-ops infrastructure scripts/bootstrap
```

---

## 4. Встановити k3s на DMZ кластер (prod-node-dmz)

```bash
ssh ${PROD_DMZ_HOST} -l ubuntu "sudo bash -s" \
  < scripts/bootstrap/01-install-k3s.sh
```

Перевірка:

```bash
ssh ${PROD_DMZ_HOST} -l ubuntu "sudo systemctl status k3s --no-pager"
```

---

## 5. Встановити k3s на CDE кластер (prod-node-cde)

CDE кластер — окремий одновузловий k3s. Встановлення аналогічне:

```bash
ssh ${PROD_CDE_HOST} -l ubuntu "sudo bash -s" \
  < scripts/bootstrap/01-install-k3s.sh
```

Перевірка:

```bash
ssh ${PROD_CDE_HOST} -l ubuntu "sudo systemctl status k3s --no-pager"
```

> **CDE мережеві вимоги:** на рівні firewall/cloud security group переконатися,
> що prod-node-cde **не має** egress до інтернету (заборонити порти 80/443 назовні).
> NetworkPolicy в Kubernetes — додатковий рівень, але захист на рівні мережі обов'язковий.

---

## 6. Забрати kubeconfig для обох кластерів

### 6.1 DMZ kubeconfig

```bash
ssh ${PROD_DMZ_HOST} -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${PROD_DMZ_VIP}/" > ~/.kube/finpaybank-prod-dmz

chmod 600 ~/.kube/finpaybank-prod-dmz
```

### 6.2 CDE kubeconfig

```bash
ssh ${PROD_CDE_HOST} -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${PROD_CDE_VIP}/" > ~/.kube/finpaybank-prod-cde

chmod 600 ~/.kube/finpaybank-prod-cde
```

### 6.3 Перевірка обох кластерів

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl get nodes -o wide
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get nodes -o wide
```

---

## 7. Встановити cert-manager

### 7.1 DMZ кластер (Let's Encrypt)

DMZ має публічний IP — використовуємо Let's Encrypt ACME HTTP-01:

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-dmz

kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=180s
kubectl get crd certificates.cert-manager.io issuers.cert-manager.io

# Повторний apply після готовності webhook:
kubectl apply -k infrastructure/cert-manager/
kubectl get clusterissuer
```

### 7.2 CDE кластер (Internal CA)

CDE не має доступу до ACME — використовуємо internal CA:

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-cde

kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=180s

# Генеруємо CA key та cert
openssl genrsa -out prod-cde-ca.key 4096
openssl req -new -x509 -key prod-cde-ca.key -out prod-cde-ca.crt \
  -days 3650 -subj "/CN=FinPayBank Prod CDE CA/O=FinPayBank"

kubectl create secret tls internal-ca-secret \
  --cert=prod-cde-ca.crt \
  --key=prod-cde-ca.key \
  -n cert-manager

# Зберегти private key в password manager, видалити локально
rm prod-cde-ca.key prod-cde-ca.crt

kubectl apply -k infrastructure/cert-manager/
kubectl get clusterissuer
```

---

## 7б. Налаштувати Traefik на обох кластерах + TLS сертифікат

### Wildcard сертифікат

Той самий `*.finpay.com.ua` сертифікат від GoDaddy потрібен на **обох** кластерах — DMZ (для TLS на вхідному трафіку) і CDE (для TLS на порту 30443).

Якщо `infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml` вже зашифрований — пропустити генерацію:

```bash
# Якщо потрібно (пере)зашифрувати:
kubectl create secret tls finpay-wildcard-tls \
  --cert=/path/to/wildcard.crt \
  --key=/path/to/wildcard.key \
  --namespace kube-system \
  --dry-run=client -o yaml > infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml

sops -e -i infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml
```

### Застосувати на DMZ кластері

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-dmz

# TLS секрет вручну (SOPS-encrypted файл — kustomize не може застосувати напряму)
sops -d infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# HelmChartConfig (additionalArguments: allowExternalNameServices) + TLSStore
kubectl apply -k infrastructure/traefik/overlays/prod
```

### Застосувати на CDE кластері

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-cde

# Той самий wildcard сертифікат потрібен і на CDE
sops -d infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# HelmChartConfig (NodePort 30443) + TLSStore
kubectl apply -k infrastructure/traefik/overlays/prod-cde
```

Перевірка:

```bash
# CDE NodePort 30443
KUBECONFIG=~/.kube/finpaybank-prod-cde \
  kubectl -n kube-system get svc traefik \
  -o jsonpath='{.spec.ports[?(@.name=="websecure")].nodePort}'
# Очікується: 30443

# DMZ — wildcard cert завантажений
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
  kubectl -n kube-system get secret finpay-wildcard-tls
```

> **Firewall:** порт 30443 на prod-node-cde (`10.201.98.10`) — відкритий **тільки для prod-node-dmz (`10.201.97.10`)**.
> Інтернет до CDE:30443 має бути заблокований на рівні cloud security group / firewall.

> **Архітектура маршрутизації API:** DMZ Traefik → `cde-proxy` IngressRoute (HTTPS, `serversTransport: serverName=online.finpay.com.ua`) → CDE Traefik:30443 → ESB сервіси.

---

## 8. Підготувати SOPS age key

### 8.1 Перевірити наявність operator key

```bash
ls ~/.config/sops/age/keys.txt
# Якщо відсутній — запустити: infrastructure/secrets/bootstrap-secrets.sh
```

### 8.2 Перевірити зашифровані секрети для prod

```bash
# Інфраструктурні секрети
ls k8s-ops/apps/cde/rabbitmq/overlays/prod/secret-rabbitmq.yaml
ls k8s-ops/apps/cde/redis/overlays/prod/secret-redis.yaml

# Shared secrets (спільні ENV для всіх CDE сервісів)
ls k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-shared.yaml
ls k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-webplatform.yaml

# Сервіс-специфічні секрети
ls k8s-ops/apps/cde/cards/overlays/prod/secret-cards.yaml
ls k8s-ops/apps/cde/transactions/overlays/prod/secret-transactions.yaml
ls k8s-ops/apps/cde/transactions-worker/overlays/prod/secret-transactions-worker.yaml
ls k8s-ops/apps/cde/ukrcard/overlays/prod/secret-ukrcard.yaml
ls k8s-ops/apps/cde/ukrcard/overlays/prod/secret-ukrcard-certs.yaml
# Всі мають містити блок sops:
```

Переглянути розшифрований вміст (перевірка):

```bash
sops -d k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-shared.yaml
```

---

## 9. Зареєструвати обидва кластери в ArgoCD

Виконується з management кластера:

```bash
export KUBECONFIG=~/.kube/finpaybank-management

# Логін в ArgoCD
argocd login localhost:30080 --username admin --insecure
```

### 9.1 Реєстрація DMZ кластера

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz argocd cluster add \
  --name prod-dmz \
  "$(KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl config current-context)" \
  --yes
```

### 9.2 Реєстрація CDE кластера

```bash
KUBECONFIG=~/.kube/finpaybank-prod-cde argocd cluster add \
  --name prod-cde \
  "$(KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl config current-context)" \
  --yes
```

### 9.3 Перевірка

```bash
argocd cluster list
# Мають бути присутні: prod-dmz та prod-cde
```

---

## 10. Створити registry secrets

### 10.1 DMZ namespace

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-dmz
export REGISTRY_USERNAME='<REGISTRY_USERNAME>'
export REGISTRY_PASSWORD='<REGISTRY_PASSWORD>'

TARGET_NAMESPACES='prod-dmz' scripts/bootstrap/04-add-registry-secrets.sh
```

### 10.2 CDE namespace

```bash
export KUBECONFIG=~/.kube/finpaybank-prod-cde

TARGET_NAMESPACES='prod-cde' scripts/bootstrap/04-add-registry-secrets.sh
```

Перевірка:

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl get secret registry-credentials -n prod-dmz
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get secret registry-credentials -n prod-cde
```

---

## 11. Застосувати secrets (перший раз — до ArgoCD sync)

Секрети зашифровані SOPS в Git. ArgoCD розшифровує їх автоматично через sops-argocd-plugin
(якщо SOPS age key завантажено в ArgoCD — крок 4а `deploy.MGMT.md`).

Якщо потрібен ручний apply до першого sync ArgoCD:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
export KUBECONFIG=~/.kube/finpaybank-prod-cde

# Shared secrets — спільні ENV змінні для всіх CDE сервісів
sops -d k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-shared.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-webplatform.yaml | kubectl apply -f -

# Infrastructure secrets
sops -d k8s-ops/apps/cde/rabbitmq/overlays/prod/secret-rabbitmq.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/redis/overlays/prod/secret-redis.yaml | kubectl apply -f -

# Service-specific secrets
sops -d k8s-ops/apps/cde/cards/overlays/prod/secret-cards.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/transactions/overlays/prod/secret-transactions.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/transactions-worker/overlays/prod/secret-transactions-worker.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/ukrcard/overlays/prod/secret-ukrcard.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/ukrcard/overlays/prod/secret-ukrcard-certs.yaml | kubectl apply -f -
```

Secrets, яких **немає в Git** (створюються вручну):

```bash
# MinIO credentials (CDE)
KUBECONFIG=~/.kube/finpaybank-prod-cde \
kubectl create secret generic minio-credentials \
  -n prod-cde \
  --from-literal=accesskey='<ACCESS_KEY>' \
  --from-literal=secretkey='<SECRET_KEY>'

# Push Gateway Google credentials / FCM service account JSON (DMZ)
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
kubectl create secret generic push-gateway-google-credentials \
  -n prod-dmz \
  --from-file=credentials.json=/path/to/google-credentials.json

# Kargo git credentials — виконується ОДИН РАЗ на management кластер (не per-environment)
# Якщо вже робили при deploy stage — пропустити
# export BITBUCKET_REPO_TOKEN='<BITBUCKET_REPO_TOKEN>'
# scripts/maintenance/update-kargo-git-credentials.sh
```

---

## 12. Встановити Reloader

Reloader деплоїться через ArgoCD з management кластера — не потрібно застосовувати вручну на prod.
ApplicationSet вже описаний в `infrastructure/reloader/applicationset.yaml` і охоплює всі кластери включно з prod-dmz та prod-cde.

Якщо ApplicationSet ще не застосований (перший раз):

```bash
KUBECONFIG=~/.kube/finpaybank-management \
  kubectl apply -f infrastructure/reloader/applicationset.yaml
```

ArgoCD автоматично задеплоїть Reloader на prod-dmz та prod-cde. Перевірка:

```bash
argocd app list | grep reloader
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl -n reloader get pods
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl -n reloader get pods
```

---

## 13. Увімкнути GitOps (ArgoCD AppProject + ApplicationSet)

Prod має **два окремих** AppProject і ApplicationSet — по одному на кожну зону:

```bash
export KUBECONFIG=~/.kube/finpaybank-management

# CDE зона
kubectl apply -f k8s-ops/argocd/projects/prod-cde-project.yaml
kubectl apply -f k8s-ops/argocd/applicationsets/prod-cde-appset.yaml

# DMZ зона
kubectl apply -f k8s-ops/argocd/projects/prod-dmz-project.yaml
kubectl apply -f k8s-ops/argocd/applicationsets/prod-dmz-appset.yaml

# Перевірити що ApplicationSets видно
kubectl -n argocd get applicationsets
argocd app list | grep prod
```

Після цього ArgoCD виявить overlays в `k8s-ops/apps/dmz/*/overlays/prod` та
`k8s-ops/apps/cde/*/overlays/prod` і підготує застосунки для sync.

> **Важливо:** prod має `syncPolicy: automated: null` — ArgoCD **не синхронізує автоматично**.
> Sync ініціює Kargo (після ручного підтвердження) або вручну через UI/CLI.
> Це критична вимога PCI-DSS: всі prod зміни мають human approval.

---

## 14. Перший ручний sync (bootstrap)

Для першого підняття середовища зробити початковий sync вручну:

```bash
export KUBECONFIG=~/.kube/finpaybank-management

# Спершу CDE інфраструктура
argocd app sync shared-secrets-cde-prod
argocd app sync rabbitmq-cde-prod
argocd app sync redis-cde-prod
argocd app sync elasticsearch-cde-prod
argocd app sync minio-cde-prod
argocd app sync shared-network-cde-prod

# Потім DMZ
argocd app sync shared-network-dmz-prod
argocd app sync cde-proxy-dmz-prod
argocd app sync static-dmz-prod

# ESB сервіси (CDE)
argocd app sync identity-cde-prod
argocd app sync customer-cde-prod
argocd app sync cards-cde-prod
argocd app sync cards-worker-cde-prod
argocd app sync payments-cde-prod
argocd app sync transactions-cde-prod
argocd app sync transactions-worker-cde-prod
argocd app sync ukrcard-cde-prod
argocd app sync banks-cde-prod
argocd app sync banks-worker-cde-prod
argocd app sync notifications-cde-prod
argocd app sync notifications-worker-cde-prod
argocd app sync qr-cde-prod
argocd app sync check-for-update-cde-prod
argocd app sync image2text-cde-prod
argocd app sync maintenance-cde-prod

# DMZ сервіси
argocd app sync push-gateway-dmz-prod
argocd app sync sms-dmz-prod
```

Перевірити статус:

```bash
argocd app list | grep prod
```

---

## 15. Kargo — налаштування prod

Kargo управляє просуванням між stage та prod. Prod-кроки потребують **ручного підтвердження**.

> **ВАЖЛИВО:** сервіс `payments` потребує **2 підтвердження** в Kargo для prod.

### 15.1 Перевірити що prod registered в Kargo

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kargo get stages --project identity  # приклад для identity сервісу
```

### 15.2 Переглянути freights в черзі на promotion

```bash
kargo get freights --project identity
```

### 15.3 Підтвердити promotion на prod

```bash
kargo promote \
  --project identity \
  --freight <FREIGHT_ID> \
  --stage prod
```

### 15.4 Перевірити статус промоції

```bash
kargo get promotions --project identity
```

---

## 16. Базова перевірка

### 16.1 Поди запущені

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl get pods -n prod-dmz
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get pods -n prod-cde
```

### 16.2 NetworkPolicy — CDE internet (НЕ має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-prod-cde \
kubectl run tmp -it --rm --image=busybox -n prod-cde \
  -- nc -zv 8.8.8.8 443
# Очікується: timeout або connection refused
```

### 16.3 NetworkPolicy — DMZ → CDE RabbitMQ (має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
kubectl run tmp -it --rm --image=busybox -n prod-dmz \
  -- nc -zv ${PROD_CDE_VIP} 5672
```

### 16.4 DMZ → CDE Traefik NodePort (має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
kubectl run tmp -it --rm --image=busybox -n prod-dmz \
  -- nc -zv ${PROD_CDE_VIP} 30443
# Очікується: open — CDE Traefik доступний з DMZ
```

### 16.5 API маршрутизація end-to-end

```bash
# Має відповісти 401 (auth required) — означає що запит пройшов весь ланцюг до CDE сервісу
curl -s https://online.finpay.com.ua/api/v1/banks/search -o /dev/null -w "%{http_code}\n"
# Очікується: 401
```

### 16.6 RabbitMQ per-service users

Після першого запуску RabbitMQ — налаштувати окремих user-ів для сервісів:

```bash
KUBECONFIG=~/.kube/finpaybank-prod-cde \
kubectl port-forward svc/rabbitmq-management 15672:15672 -n prod-cde &

KUBECONFIG=~/.kube/finpaybank-prod-cde \
kubectl exec -it rabbitmq-0 -n prod-cde -- \
  rabbitmqctl add_user push-gateway '<STRONG_PASS>'

KUBECONFIG=~/.kube/finpaybank-prod-cde \
kubectl exec -it rabbitmq-0 -n prod-cde -- \
  rabbitmqctl set_permissions push-gateway / "" "" "push-notifications"
# Аналогічно: sms, notifications, cards, payments, transactions, ...
```

### 16.7 ArgoCD статус

```bash
export KUBECONFIG=~/.kube/finpaybank-management
argocd app list | grep prod
```

---

## 17. Різниця між stage і prod

| | stage | prod |
|---|---|---|
| Топологія | 2 окремих k3s (1 нода кожен) | 2 окремих k3s (1 нода кожен) |
| Namespace DMZ | `stage-dmz` | `prod-dmz` |
| Namespace CDE | `stage-cde` | `prod-cde` |
| AppProject/AppSet | 1 спільний stage | 2 окремих: prod-cde + prod-dmz |
| Sync | Kargo ручне підтвердження | Kargo ручне підтвердження, НЕ automated |
| Image tags | конкретний тег | digest-based (`sha256:...`) |
| PagerDuty | ні | так (on-sync-failed, on-health-degraded) |
| Kargo payments | 1 підтвердження | **2 підтвердження** |
| kubeconfig | `finpaybank-stage-dmz` + `finpaybank-stage-cde` | `finpaybank-prod-dmz` + `finpaybank-prod-cde` |

---

## 18. Troubleshooting

### cert-manager webhook x509 error

```bash
kubectl get validatingwebhookconfiguration cert-manager-webhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}'

kubectl -n cert-manager rollout restart \
  deployment/cert-manager-webhook \
  deployment/cert-manager-cainjector

kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
```

Якщо `caBundle` порожній:

```bash
CA_BUNDLE="$(kubectl -n cert-manager get secret cert-manager-webhook-ca \
  -o jsonpath='{.data.ca\.crt}')"
kubectl patch validatingwebhookconfiguration cert-manager-webhook \
  --type='json' \
  -p='[{"op":"add","path":"/webhooks/0/clientConfig/caBundle","value":"'"${CA_BUNDLE}"'"}]'
```

### ArgoCD не синхронізує (Unknown cluster)

```bash
export KUBECONFIG=~/.kube/finpaybank-management
argocd cluster list
# Якщо кластер відсутній — повторити крок 9 (реєстрація кластерів)
```

### SOPS decrypt помилка

```bash
ls ~/.config/sops/age/keys.txt
cat .sops.yaml | grep "age:"

# Відновити з ArgoCD якщо ключ загублено
kubectl -n argocd get secret sops-age-key \
  -o jsonpath='{.data.key\.txt}' | base64 -d > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

### Pod не стартує

```bash
kubectl describe pod <POD_NAME> -n prod-cde
kubectl logs <POD_NAME> -n prod-cde --previous
```

### ImagePullBackOff

```bash
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get secret registry-credentials -n prod-cde
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl get secret registry-credentials -n prod-dmz
```

### cde-proxy: API повертає 404

Ланцюг: nginx WAF → DMZ Traefik → cde-proxy IngressRoute → CDE Traefik:30443 → ESB pod.

```bash
# 1. Перевірити чи CDE Traefik доступний з DMZ і повертає правильний код
curl -s --resolve "online.finpay.com.ua:30443:${PROD_CDE_VIP}" \
  https://online.finpay.com.ua:30443/api/v1/banks/search \
  -o /dev/null -w "%{http_code}\n"
# Очікується: 401

# 2. Перевірити чи IngressRoute і ServersTransport задеплоєні
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
  kubectl -n prod-dmz get ingressroute,serverstransport

# 3. Перевірити EndpointSlice (має мати PROD_CDE_VIP — 10.201.98.10)
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
  kubectl -n prod-dmz get endpointslice cde-traefik -o yaml | grep -A3 "endpoints:"

# 4. Traefik logs
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
  kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=50 | grep -i "cde\|route\|error"
```

### Загальна діагностика

```bash
KUBECONFIG=~/.kube/finpaybank-prod-dmz kubectl get pods -A
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get pods -A
KUBECONFIG=~/.kube/finpaybank-prod-cde kubectl get events -A \
  --sort-by=.metadata.creationTimestamp | tail -30
```
