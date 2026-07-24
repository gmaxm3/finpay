# Deploy STAGE Environment

Цей файл описує розгортання `stage` середовища, яке складається з **двох окремих k3s кластерів**:

- **stage-dmz** — інтернет-facing кластер, namespace `stage-dmz` (cde-proxy, push-gateway, sms, static)
- **stage-cde** — PCI-DSS кластер, без інтернету, namespace `stage-cde` (ESB сервіси, Redis, RabbitMQ, PostgreSQL access)

На відміну від `test`, де сервіси деплояться напряму через `kubectl apply`, stage **повністю керується ArgoCD** — зміни в Git автоматично підхоплює ArgoCD, а просування між stage та prod вимагає ручного підтвердження в Kargo.

Управляючий кластер (ArgoCD + Kargo) описаний в [deploy.MGMT.md](deploy.MGMT.md) і має бути запущений до початку розгортання stage.

---

## 1. Що потрібно до старту

**Інфраструктура:**

- Два сервери для stage кластерів:
  - `stage-node-1` — DMZ кластер (`STAGE_DMZ_HOST`): інтернет-facing
  - `stage-node-2` — CDE кластер (`STAGE_CDE_HOST`): без інтернету
- `sudo` права для користувача `ubuntu` на обох нодах

**Мережа:**

- `stage-node-1` (DMZ) — має доступ до інтернету (Let's Encrypt, FCM, SMS)
- `stage-node-2` (CDE) — **не має** доступу до інтернету; PostgreSQL доступний за `STAGE_POSTGRES_PRIMARY_IP`
- Між кластерами:
  - stage-dmz → stage-cde **порт 5672** (RabbitMQ)
  - stage-dmz → stage-cde **порт 30443** (CDE Traefik NodePort — HTTPS, через IngressRoute + ServersTransport)

**Management кластер:**
- ArgoCD запущений і доступний (`argocd login` проходить)
- Kargo запущений і доступний
- SOPS age key завантажено в ArgoCD namespace (крок 4а в `deploy.MGMT.md`)

**Доступи:**
- Docker registry (`hub.kapowai.com.ua`, `finpaybank.kapowai.com.ua`)
- Bitbucket (SSH ключ для ArgoCD вже в Bitbucket)
- PostgreSQL для stage

**Локально на адміністративній машині:**

```bash
brew install kubectl helm kustomize sops age argocd
mkdir -p ~/.kube
cd /Users/xeon/work/kapowai/finpaybank/finpaybank-gitops
```

---

## 2. Визначити змінні

Створити `environments/stage.env` на основі `environments/test.env`:

```bash
cp environments/test.env environments/stage.env
```

Заповнити значення:

```bash
# environments/stage.env

export STAGE_DMZ_HOST="<STAGE_DMZ_HOST>"     # hostname або IP stage-node-1
export STAGE_CDE_HOST="<STAGE_CDE_HOST>"     # hostname або IP stage-node-2

export STAGE_DMZ_VIP="<STAGE_DMZ_VIP>"       # IP (або VIP) stage-node-1
export STAGE_CDE_VIP="<STAGE_CDE_VIP>"       # IP (або VIP) stage-node-2

export STAGE_POSTGRES_PRIMARY_IP="<POSTGRES_PRIMARY_IP>"
export STAGE_POSTGRES_REPLICA_IP="<POSTGRES_REPLICA_IP>"  # якщо replica є; якщо ні — = primary

export STAGE_PUBLIC_DOMAIN="online-stage.finpay.com.ua"
export ACME_EMAIL="vladimir.fesik@kapowai.online"
```

Завантажити в shell:

```bash
set -a
source environments/stage.env
set +a

export STAGE_DMZ_SSH="ssh ${STAGE_DMZ_HOST} -l ubuntu"
export STAGE_CDE_SSH="ssh ${STAGE_CDE_HOST} -l ubuntu"
```

---

## 3. Замінити stage-плейсхолдери в repo

Перед першим деплоєм замінити всі плейсхолдери:

```bash
rg -n "REPLACE_|STAGE_DMZ_VIP|STAGE_CDE_VIP|REPLACE_STAGE_POSTGRES" \
  k8s-ops infrastructure scripts/bootstrap
```

Критичні файли для stage:

```text
STAGE_DMZ_VIP              → scripts/bootstrap/05-add-clusters-argocd.sh
                             k8s-ops/argocd/projects/stage-project.yaml
                             k8s-ops/argocd/applicationsets/stage-appset.yaml

STAGE_CDE_VIP              → scripts/bootstrap/05-add-clusters-argocd.sh
                             k8s-ops/argocd/projects/stage-project.yaml
                             k8s-ops/argocd/applicationsets/stage-appset.yaml

REPLACE_STAGE_POSTGRES_IP  → k8s-ops/apps/cde/shared-network/overlays/stage/kustomization.yaml

0.0.0.1/32 # TODO webplatform
                           → k8s-ops/apps/cde/shared-network/overlays/stage/kustomization.yaml
                             (замінити на реальний IP webplatform для stage)

ACME email                 → infrastructure/cert-manager/cluster-issuer.yaml
```

> **Hostname API (`online-stage.finpay.com.ua`) вже вшитий** в kustomize overlay-патчах
> (`overlays/stage/kustomization.yaml` кожного CDE сервісу та `cde-proxy/overlays/stage/ingressroute.yaml`).
> Ручна заміна не потрібна.

Перевірити після змін:

```bash
git diff -- k8s-ops infrastructure scripts/bootstrap
```

---

## 4. Встановити k3s на DMZ кластер (stage-node-1)

```bash
ssh ${STAGE_DMZ_HOST} -l ubuntu "sudo bash -s" \
  < scripts/bootstrap/01-install-k3s.sh
```

Перевірка:

```bash
ssh ${STAGE_DMZ_HOST} -l ubuntu "sudo systemctl status k3s --no-pager"
```

---

## 5. Встановити k3s на CDE кластер (stage-node-2)

CDE кластер — окремий одновузловий k3s. Встановлення аналогічне:

```bash
ssh ${STAGE_CDE_HOST} -l ubuntu "sudo bash -s" \
  < scripts/bootstrap/01-install-k3s.sh
```

Перевірка:

```bash
ssh ${STAGE_CDE_HOST} -l ubuntu "sudo systemctl status k3s --no-pager"
```

> **CDE мережеві вимоги:** на рівні firewall/cloud security group переконатися,
> що stage-node-2 **не має** egress до інтернету (заборонити порти 80/443 назовні).
> NetworkPolicy в Kubernetes — додатковий рівень, але захист на рівні мережі обов'язковий.

---

## 6. Забрати kubeconfig для обох кластерів

### 6.1 DMZ kubeconfig

```bash
ssh ${STAGE_DMZ_HOST} -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${STAGE_DMZ_VIP}/" > ~/.kube/finpaybank-stage-dmz

chmod 600 ~/.kube/finpaybank-stage-dmz
```

### 6.2 CDE kubeconfig

```bash
ssh ${STAGE_CDE_HOST} -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${STAGE_CDE_VIP}/" > ~/.kube/finpaybank-stage-cde

chmod 600 ~/.kube/finpaybank-stage-cde
```

### 6.3 Перевірка обох кластерів

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl get nodes -o wide
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get nodes -o wide
```

---

## 7. Встановити cert-manager

### 7.1 DMZ кластер (Let's Encrypt)

DMZ має публічний IP — використовуємо Let's Encrypt ACME HTTP-01:

```bash
export KUBECONFIG=~/.kube/finpaybank-stage-dmz

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
export KUBECONFIG=~/.kube/finpaybank-stage-cde

kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=180s

# Генеруємо CA key та cert
openssl genrsa -out stage-cde-ca.key 4096
openssl req -new -x509 -key stage-cde-ca.key -out stage-cde-ca.crt \
  -days 3650 -subj "/CN=FinPayBank Stage CDE CA/O=FinPayBank"

kubectl create secret tls internal-ca-secret \
  --cert=stage-cde-ca.crt \
  --key=stage-cde-ca.key \
  -n cert-manager

# Зберегти private key в password manager, видалити локально
rm stage-cde-ca.key stage-cde-ca.crt

kubectl apply -k infrastructure/cert-manager/
kubectl get clusterissuer
```

---

## 7б. Налаштувати Traefik на обох кластерах + TLS сертифікат

### Wildcard сертифікат

Той самий `*.finpay.com.ua` сертифікат від GoDaddy потрібен на **обох** кластерах — DMZ (для TLS на вхідному трафіку) і CDE (для TLS на порту 30443, щоб DMZ→CDE верифікація проходила).

Якщо файл ще не існує — зашифрувати сертифікат:

```bash
kubectl create secret tls finpay-wildcard-tls \
  --cert=/path/to/wildcard.crt \
  --key=/path/to/wildcard.key \
  --namespace kube-system \
  --dry-run=client -o yaml > infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml

sops -e -i infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml
```

### Застосувати на DMZ кластері

```bash
export KUBECONFIG=~/.kube/finpaybank-stage-dmz

# TLS секрет вручну (SOPS-encrypted файл — kustomize не може застосувати напряму)
sops -d infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# HelmChartConfig (additionalArguments: allowExternalNameServices) + TLSStore
kubectl apply -k infrastructure/traefik/overlays/stage
```

### Застосувати на CDE кластері

```bash
export KUBECONFIG=~/.kube/finpaybank-stage-cde

# Той самий wildcard сертифікат потрібен і на CDE
sops -d infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# HelmChartConfig (NodePort 30443) + TLSStore
kubectl apply -k infrastructure/traefik/overlays/stage-cde
```

Перевірка:

```bash
# CDE NodePort 30443
KUBECONFIG=~/.kube/finpaybank-stage-cde \
  kubectl -n kube-system get svc traefik \
  -o jsonpath='{.spec.ports[?(@.name=="websecure")].nodePort}'
# Очікується: 30443

# DMZ — wildcard cert завантажений
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
  kubectl -n kube-system get secret finpay-wildcard-tls
```

> **Firewall:** порт 30443 на stage-node-2 (CDE) — відкритий **тільки для stage-node-1 (DMZ)**.
> Інтернет до CDE:30443 має бути заблокований на рівні cloud security group / firewall.

> **Архітектура маршрутизації API:** DMZ Traefik → `cde-proxy` IngressRoute (HTTPS, `serversTransport: serverName=online-stage.finpay.com.ua`) → CDE Traefik:30443 → ESB сервіси. Використовується `IngressRoute` CRD (не стандартний Kubernetes Ingress) — Traefik v3 ігнорує анотацію `service.serversscheme` для ClusterIP бекендів.

---

## 8. Підготувати SOPS age key

### 8.1 Перевірити наявність operator key

```bash
ls ~/.config/sops/age/keys.txt
# Якщо відсутній — запустити: infrastructure/secrets/bootstrap-secrets.sh
```

### 8.2 Перевірити зашифровані секрети для stage

```bash
# Інфраструктурні секрети
ls k8s-ops/apps/cde/rabbitmq/overlays/stage/secret-rabbitmq.yaml
ls k8s-ops/apps/cde/redis/overlays/stage/secret-redis.yaml

# Shared secrets (спільні ENV для всіх CDE сервісів)
ls k8s-ops/apps/cde/shared-secrets/overlays/stage/secret-shared.yaml
ls k8s-ops/apps/cde/shared-secrets/overlays/stage/secret-webplatform.yaml

# Сервіс-специфічні секрети
ls k8s-ops/apps/cde/cards/overlays/stage/secret-cards.yaml
ls k8s-ops/apps/cde/transactions/overlays/stage/secret-transactions.yaml
ls k8s-ops/apps/cde/transactions-worker/overlays/stage/secret-transactions-worker.yaml
ls k8s-ops/apps/cde/ukrcard/overlays/stage/secret-ukrcard.yaml
ls k8s-ops/apps/cde/ukrcard/overlays/stage/secret-ukrcard-certs.yaml
# Всі мають містити блок sops:
```

Переглянути розшифрований вміст (перевірка):

```bash
sops -d k8s-ops/apps/cde/shared-secrets/overlays/stage/secret-shared.yaml
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
KUBECONFIG=~/.kube/finpaybank-stage-dmz argocd cluster add \
  --name stage-dmz \
  "$(KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl config current-context)" \
  --yes
```

### 9.2 Реєстрація CDE кластера

```bash
KUBECONFIG=~/.kube/finpaybank-stage-cde argocd cluster add \
  --name stage-cde \
  "$(KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl config current-context)" \
  --yes
```

### 9.3 Перевірка

```bash
argocd cluster list
# Мають бути присутні: stage-dmz та stage-cde
```

---

## 10. Створити registry secrets

### 10.1 DMZ namespace

```bash
export KUBECONFIG=~/.kube/finpaybank-stage-dmz
export REGISTRY_USERNAME='<REGISTRY_USERNAME>'
export REGISTRY_PASSWORD='<REGISTRY_PASSWORD>'

TARGET_NAMESPACES='stage-dmz' scripts/bootstrap/04-add-registry-secrets.sh
```

### 10.2 CDE namespace

```bash
export KUBECONFIG=~/.kube/finpaybank-stage-cde

TARGET_NAMESPACES='stage-cde' scripts/bootstrap/04-add-registry-secrets.sh
```

Перевірка:

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl get secret registry-credentials -n stage-dmz
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get secret registry-credentials -n stage-cde
```

---

## 11. Застосувати secrets (перший раз — до ArgoCD sync)

Секрети зашифровані SOPS в Git. ArgoCD розшифровує їх автоматично через sops-argocd-plugin
(якщо SOPS age key завантажено в ArgoCD — крок 4а `deploy.MGMT.md`).

Якщо потрібен ручний apply до першого sync ArgoCD:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
export KUBECONFIG=~/.kube/finpaybank-stage-cde

# Shared secrets — спільні ENV змінні для всіх CDE сервісів
sops -d k8s-ops/apps/cde/shared-secrets/overlays/stage/secret-shared.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/shared-secrets/overlays/stage/secret-webplatform.yaml | kubectl apply -f -

# Infrastructure secrets
sops -d k8s-ops/apps/cde/rabbitmq/overlays/stage/secret-rabbitmq.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/redis/overlays/stage/secret-redis.yaml | kubectl apply -f -

# Service-specific secrets
sops -d k8s-ops/apps/cde/cards/overlays/stage/secret-cards.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/transactions/overlays/stage/secret-transactions.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/transactions-worker/overlays/stage/secret-transactions-worker.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/ukrcard/overlays/stage/secret-ukrcard.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/ukrcard/overlays/stage/secret-ukrcard-certs.yaml | kubectl apply -f -
```

Secrets, яких **немає в Git** (створюються вручну):

```bash
# MinIO credentials (CDE)
KUBECONFIG=~/.kube/finpaybank-stage-cde \
kubectl create secret generic minio-credentials \
  -n stage-cde \
  --from-literal=accesskey='<ACCESS_KEY>' \
  --from-literal=secretkey='<SECRET_KEY>'

# Push Gateway Google credentials / FCM service account JSON (DMZ)
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
kubectl create secret generic push-gateway-google-credentials \
  -n stage-dmz \
  --from-file=credentials.json=/path/to/google-credentials.json

# Kargo git credentials — виконується ОДИН РАЗ на management кластер (не per-environment)
# Якщо вже робили при deploy test/dev — пропустити
# export BITBUCKET_REPO_TOKEN='<BITBUCKET_REPO_TOKEN>'
# scripts/maintenance/update-kargo-git-credentials.sh
```

---

## 12. Встановити Reloader

Reloader деплоїться через ArgoCD з management кластера — не потрібно застосовувати вручну на stage.
ApplicationSet вже описаний в `infrastructure/reloader/applicationset.yaml` і охоплює всі кластери включно зі stage-dmz та stage-cde.

Якщо ApplicationSet ще не застосований (перший раз):

```bash
KUBECONFIG=~/.kube/finpaybank-management \
  kubectl apply -f infrastructure/reloader/applicationset.yaml
```

ArgoCD автоматично задеплоїть Reloader на stage-dmz та stage-cde. Перевірка:

```bash
argocd app list | grep reloader
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl -n reloader get pods
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl -n reloader get pods
```

Після цього будь-яка зміна `shared-secrets` або `*-config` автоматично ініціює rolling restart.

---

## 13. Увімкнути GitOps (ArgoCD AppProject + ApplicationSet)

```bash
export KUBECONFIG=~/.kube/finpaybank-management

kubectl apply -f k8s-ops/argocd/projects/stage-project.yaml
kubectl apply -f k8s-ops/argocd/applicationsets/stage-appset.yaml

# Перевірити що ApplicationSet видно
kubectl -n argocd get applicationsets
argocd app list | grep stage
```

Після цього ArgoCD виявить overlays в `k8s-ops/apps/dmz/*/overlays/stage` та
`k8s-ops/apps/cde/*/overlays/stage` і підготує застосунки для sync.

> **Увага:** stage має `syncPolicy: automated: null` — ArgoCD **не синхронізує автоматично**.
> Sync ініціює Kargo (після ручного підтвердження) або вручну через UI/CLI.

---

## 14. Перший ручний sync (bootstrap)

Для першого підняття середовища зробити початковий sync вручну:

```bash
export KUBECONFIG=~/.kube/finpaybank-management

# Спершу CDE інфраструктура
argocd app sync shared-secrets-cde-stage
argocd app sync rabbitmq-cde-stage
argocd app sync redis-cde-stage
argocd app sync elasticsearch-cde-stage
argocd app sync minio-cde-stage
argocd app sync shared-network-cde-stage

# Потім DMZ
argocd app sync shared-network-dmz-stage
argocd app sync cde-proxy-dmz-stage
argocd app sync static-dmz-stage

# ESB сервіси (CDE)
argocd app sync identity-cde-stage
argocd app sync customer-cde-stage
argocd app sync cards-cde-stage
argocd app sync cards-worker-cde-stage
argocd app sync payments-cde-stage
argocd app sync transactions-cde-stage
argocd app sync transactions-worker-cde-stage
argocd app sync ukrcard-cde-stage
argocd app sync banks-cde-stage
argocd app sync banks-worker-cde-stage
argocd app sync notifications-cde-stage
argocd app sync notifications-worker-cde-stage
argocd app sync qr-cde-stage
argocd app sync check-for-update-cde-stage
argocd app sync image2text-cde-stage
argocd app sync maintenance-cde-stage

# DMZ сервіси
argocd app sync push-gateway-dmz-stage
argocd app sync sms-dmz-stage
```

Перевірити статус:

```bash
argocd app list | grep stage
```

---

## 15. Kargo — налаштування stage

Kargo управляє просуванням між stage та prod. Stage-кроки потребують **ручного підтвердження**.

### 15.1 Перевірити що stage registered в Kargo

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kargo get stages --project identity  # приклад для identity сервісу
```

### 15.2 Переглянути freights в черзі на promotion

```bash
kargo get freights --project identity
```

### 15.3 Підтвердити promotion на stage

```bash
kargo promote \
  --project identity \
  --freight <FREIGHT_ID> \
  --stage stage
```

### 15.4 Перевірити статус промоції

```bash
kargo get promotions --project identity
```

> Prod вимагає повторного підтвердження після stage. Для `payments` prod потребує 2 підтверджень.

---

## 16. Базова перевірка

### 16.1 Поди запущені

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl get pods -n stage-dmz
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get pods -n stage-cde
```

### 16.2 NetworkPolicy — CDE internet (НЕ має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-stage-cde \
kubectl run tmp -it --rm --image=busybox -n stage-cde \
  -- nc -zv 8.8.8.8 443
# Очікується: timeout або connection refused
```

### 16.3 NetworkPolicy — DMZ → CDE RabbitMQ (має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
kubectl run tmp -it --rm --image=busybox -n stage-dmz \
  -- nc -zv ${STAGE_CDE_VIP} 5672
# RabbitMQ доступний по зовнішньому IP CDE ноди
```

### 16.4 DMZ → CDE Traefik NodePort (має працювати)

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
kubectl run tmp -it --rm --image=busybox -n stage-dmz \
  -- nc -zv ${STAGE_CDE_VIP} 30443
# Очікується: open — CDE Traefik доступний з DMZ
```

### 16.5 API маршрутизація end-to-end

Після повного підняття середовища перевірити що API запит проходить весь ланцюг:

```bash
# Має відповісти 401 (auth required) — означає що запит пройшов весь ланцюг до CDE сервісу
curl -s https://online-stage.finpay.com.ua/api/v1/banks/search -o /dev/null -w "%{http_code}\n"
# Очікується: 401
```

### 16.6 RabbitMQ per-service users

Після першого запуску RabbitMQ — налаштувати окремих user-ів для сервісів:

```bash
KUBECONFIG=~/.kube/finpaybank-stage-cde \
kubectl port-forward svc/rabbitmq-management 15672:15672 -n stage-cde &

KUBECONFIG=~/.kube/finpaybank-stage-cde \
kubectl exec -it rabbitmq-0 -n stage-cde -- \
  rabbitmqctl add_user push-gateway '<STRONG_PASS>'

KUBECONFIG=~/.kube/finpaybank-stage-cde \
kubectl exec -it rabbitmq-0 -n stage-cde -- \
  rabbitmqctl set_permissions push-gateway / "" "" "push-notifications"
# Аналогічно: sms, notifications, cards, payments, transactions, ...
```

### 16.7 ArgoCD статус

```bash
export KUBECONFIG=~/.kube/finpaybank-management
argocd app list | grep stage
```

---

## 17. Різниця між stage і test

| | test | stage |
|---|---|---|
| Топологія | 1 нода, 2 namespace | 2 окремих k3s кластери (DMZ + CDE) |
| Деплой | `kubectl apply -k .../overlays/test` | ArgoCD (ручний sync або через Kargo) |
| Replicas | 1 | 2 |
| Image tags | `:latest` або конкретний | конкретний тег (не `:latest`) |
| Secrets | SOPS, ручний decrypt | SOPS, ArgoCD sops-plugin розшифровує |
| Kargo | не потрібен | обов'язковий, ручне підтвердження |
| Internet з CDE | заборонений (NetworkPolicy) | заборонений (NetworkPolicy + firewall) |
| kubeconfig | 1 файл | 2 файли: stage-dmz + stage-cde |

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
kubectl describe pod <POD_NAME> -n stage-cde
kubectl logs <POD_NAME> -n stage-cde --previous
```

### ImagePullBackOff

```bash
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get secret registry-credentials -n stage-cde
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl get secret registry-credentials -n stage-dmz
```

### cde-proxy: API повертає 404

Ланцюг: nginx WAF → DMZ Traefik → cde-proxy IngressRoute → CDE Traefik:30443 → ESB pod.

```bash
# 1. Перевірити чи CDE Traefik доступний з DMZ і повертає правильний код
curl -s --resolve "online-stage.finpay.com.ua:30443:${STAGE_CDE_VIP}" \
  https://online-stage.finpay.com.ua:30443/api/v1/banks/search \
  -o /dev/null -w "%{http_code}\n"
# Очікується: 401

# 2. Перевірити чи IngressRoute і ServersTransport задеплоєні
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
  kubectl -n stage-dmz get ingressroute,serverstransport

# 3. Перевірити EndpointSlice (має мати STAGE_CDE_VIP)
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
  kubectl -n stage-dmz get endpointslice cde-traefik -o yaml | grep -A3 "endpoints:"

# 4. Traefik logs (тимчасово включити DEBUG)
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
  kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=50 | grep -i "cde\|route\|error"
```

> **Важливо (Traefik v3):** стандартний Kubernetes Ingress з анотацією `service.serversscheme: https`
> ігнорується для ClusterIP бекендів. Використовується `IngressRoute` CRD з явним `scheme: https`
> та `ServersTransport.serverName`. ArgoCD sync не застосовує `EndpointSlice` через ServerSideApply
> конфлікт — застосовувати через `kubectl apply -k`.

### Загальна діагностика

```bash
KUBECONFIG=~/.kube/finpaybank-stage-dmz kubectl get pods -A
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get pods -A
KUBECONFIG=~/.kube/finpaybank-stage-cde kubectl get events -A \
  --sort-by=.metadata.creationTimestamp | tail -30
```
