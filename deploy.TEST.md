# Deploy TEST Environment

Цей файл описує розгортання `test` середовища без `management` cluster, без `ArgoCD` і без `Kargo`.

Ціль цього сценарію:

- підняти `k3s` на `kapowai.finpaybank.test.esb`
- розгорнути базову інфраструктуру в `test`
- створити потрібні `Secret`
- розгортати сервіси напряму через `kubectl apply -k .../overlays/test`

Окремий `management` cluster, `ArgoCD` і `Kargo` винесені в [deploy.MGMT.md](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/deploy.MGMT.md).

## 1. Що потрібно до старту

Підготувати:

- доступ по `ssh` до `kapowai.finpaybank.test.esb`
- `sudo` права для користувача `ubuntu`
- IP або DNS вузла `kapowai.finpaybank.test.esb`
- доступи до:
  - Docker registry
  - DNS/domain
  - PostgreSQL для `test`

Локально на адміністративній машині встановити:

```bash
brew install kubectl helm kustomize kubeseal sops age
mkdir -p ~/.kube
cd /Users/xeon/work/kapowai/finpaybank/finpaybank-gitops
set -a; source environments/test.env; set +a
```

## 2. Визначити змінні

Основний варіант: всі значення зберігаються в одному файлі [environments/test.env](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/environments/test.env).

Завантажити їх у shell:

```bash
set -a
source environments/test.env
set +a

export TEST_SSH="ssh ${TEST_HOST} -l ubuntu"
```

## 3. Перевірити і замінити test-плейсхолдери в repo

Перед першим деплоєм перевірити залишки плейсхолдерів:

```bash
rg -n "REPLACE_|TEST_NODE_IP|POSTGRES_PRIMARY_IP|POSTGRES_REPLICA_IP" \
  k8s-ops infrastructure scripts/bootstrap
```

Для `test` критичні насамперед:

- `k8s-ops/apps/cde/*/base/kustomization.yaml`
- `k8s-ops/apps/cde/*/base/networkpolicy.yaml`
- `k8s-ops/apps/dmz/nginx/overlays/test/kustomization.yaml`
- `infrastructure/cert-manager/cluster-issuer.yaml`

Мінімальний список значень:

```text
TEST_NODE_IP -> 10.201.34.10
POSTGRES_PRIMARY_IP -> 10.201.35.10
POSTGRES_REPLICA_IP -> 10.201.35.10
online-test.finpay.com.ua -> DNS test середовища
ACME email -> vladimir.fesik@kapowai.online
```

Після змін:

```bash
git diff -- k8s-ops infrastructure scripts/bootstrap
```

## 4. Встановити k3s на test node

```bash
ssh kapowai.finpaybank.test.esb -l ubuntu "sudo bash -s" \
  < scripts/bootstrap/01-install-k3s.sh
```

Перевірка:

```bash
ssh kapowai.finpaybank.test.esb -l ubuntu "sudo systemctl status k3s --no-pager"
```

## 5. Забрати kubeconfig

```bash
ssh kapowai.finpaybank.test.esb -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${TEST_NODE_IP}/" > ~/.kube/finpaybank-test

chmod 600 ~/.kube/finpaybank-test
export KUBECONFIG=~/.kube/finpaybank-test
kubectl get nodes -o wide
```

## 6. Встановити cert-manager в test cluster

```bash
kubectl apply -k infrastructure/cert-manager/
kubectl -n cert-manager rollout status deployment --timeout=180s
kubectl get crd certificates.cert-manager.io issuers.cert-manager.io
```

Якщо `cert-manager-webhook` ламається на `x509: certificate signed by unknown authority`, дивись troubleshooting внизу цього файлу.

## 7. Підготувати SOPS age key для test

Secret management: **SOPS + age**. Жодного контролера встановлювати не потрібно —
секрети зашифровані прямо в Git і розшифровуються при `kubectl apply`.

### 7.1 Перевірити наявність operator key

```bash
ls ~/.config/sops/age/keys.txt
# Якщо відсутній — запустити: infrastructure/secrets/bootstrap-secrets.sh
```

### 7.2 Перевірити що секрети вже є в репо

```bash
ls k8s-ops/apps/cde/rabbitmq/overlays/test/secret-rabbitmq.yaml
ls k8s-ops/apps/cde/redis/overlays/test/secret-redis.yaml
ls k8s-ops/apps/cde/elasticsearch/overlays/test/secret-elasticsearch.yaml
# Мають бути зашифровані SOPS файли (містять блок sops:)
```

Переглянути розшифрований вміст (перевірка):

```bash
sops -d k8s-ops/apps/cde/rabbitmq/overlays/test/secret-rabbitmq.yaml
```

### 7.3 При ручному apply — розшифрувати перед застосуванням

Якщо деплоїш **без ArgoCD** (прямий `kubectl apply`), секрети треба розшифрувати:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Розшифрувати і одразу застосувати (plain-text не пишеться на диск)
sops -d k8s-ops/apps/cde/rabbitmq/overlays/test/secret-rabbitmq.yaml \
  | kubectl apply -f -

sops -d k8s-ops/apps/cde/redis/overlays/test/secret-redis.yaml \
  | kubectl apply -f -

sops -d k8s-ops/apps/cde/elasticsearch/overlays/test/secret-elasticsearch.yaml \
  | kubectl apply -f -
```

Якщо деплоїш **через ArgoCD** — ArgoCD сам розшифровує через sidecar plugin
(потрібен завантажений `sops-age-key` secret в namespace `argocd`, див. `deploy.MGMT.md` крок 4а).

## 8. Створити registry secrets

```bash
export REGISTRY_USERNAME='<REGISTRY_USERNAME>'
export REGISTRY_PASSWORD='<REGISTRY_PASSWORD>'

TARGET_NAMESPACES='test-dmz test-cde' scripts/bootstrap/04-add-registry-secrets.sh
```

Перевірка:

```bash
kubectl get secret registry-credentials -n test-dmz
kubectl get secret registry-credentials -n test-cde
```

## 9. Застосувати infrastructure secrets

Всі secrets зашифровані в Git (SOPS + age). При ручному deploy (`kubectl apply`, не ArgoCD) — розшифровуємо і застосовуємо:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

# Shared secrets — спільні ENV змінні для всіх CDE сервісів
# (DEFAULT_URL, REDIS_URL, RABBITMQ_URL, SECRET_KEY, DATABASE_URL)
sops -d k8s-ops/apps/cde/shared-secrets/overlays/test/secret-shared.yaml | kubectl apply -f -

# Infrastructure secrets
sops -d k8s-ops/apps/cde/rabbitmq/overlays/test/secret-rabbitmq.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/redis/overlays/test/secret-redis.yaml | kubectl apply -f -
sops -d k8s-ops/apps/cde/elasticsearch/overlays/test/secret-elasticsearch.yaml | kubectl apply -f -

# Service-specific secrets (тільки для сервісів з override)
sops -d k8s-ops/apps/cde/cards/overlays/test/secret-cards.yaml | kubectl apply -f -
```

Секрети, які НЕ в Git (створюються вручну):

```bash
# MinIO credentials
kubectl create secret generic minio-credentials \
  -n test-cde \
  --from-literal=accesskey='<ACCESS_KEY>' \
  --from-literal=secretkey='<SECRET_KEY>'

# Push Gateway Google credentials (FCM service account JSON)
kubectl create secret generic push-gateway-google-credentials \
  -n test-dmz \
  --from-file=credentials.json=/path/to/google-credentials.json

# PCI certs (ПЦ/АБС) — для cards, ukrcard
kubectl create secret generic cards-pci-certs -n test-cde \
  --from-file=client.crt=/path/to/client.crt \
  --from-file=client.key=/path/to/client.key \
  --from-file=ca.crt=/path/to/ca.crt
```

## 10. Розгорнути базову інфраструктуру test

Рекомендований мінімальний порядок:

```bash
# Спершу shared-secrets — інші сервіси залежать від нього
kubectl apply -k k8s-ops/apps/cde/shared-secrets/overlays/test

kubectl apply -k k8s-ops/apps/cde/redis/overlays/test
kubectl apply -k k8s-ops/apps/cde/rabbitmq/overlays/test
kubectl apply -k k8s-ops/apps/cde/elasticsearch/overlays/test
kubectl apply -k k8s-ops/apps/cde/minio/overlays/test
kubectl apply -k k8s-ops/apps/dmz/nginx/overlays/test
```

Після цього можна застосовувати прикладні сервіси по одному:

```bash
kubectl apply -k k8s-ops/apps/cde/identity/overlays/test
kubectl apply -k k8s-ops/apps/cde/customer/overlays/test
kubectl apply -k k8s-ops/apps/cde/cards/overlays/test
kubectl apply -k k8s-ops/apps/dmz/static/overlays/test
kubectl apply -k k8s-ops/apps/dmz/sms/overlays/test
```

Якщо хочеш підняти все test середовище вручну, зручно пройтись по сервісах по черзі, а не робити масовий apply на весь `k8s-ops/apps`.

## 11. Базова перевірка

```bash
kubectl get ns
kubectl get pods -n test-dmz
kubectl get pods -n test-cde
```

Перевірити доступ DMZ до RabbitMQ:

```bash
kubectl run tmp -it --rm --image=busybox -n test-dmz \
  -- nc -zv rabbitmq.test-cde.svc.cluster.local 5672
```

Перевірити network policy для CDE:

```bash
kubectl run tmp -it --rm --image=busybox -n test-cde \
  -- nc -zv 8.8.8.8 443
```

## 12. Optional: підготовка до майбутнього ArgoCD

Цей пункт не потрібен для ручного `test` deploy.

Коли винесеш `management` cluster окремо, дивись:

- [deploy.MGMT.md](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/deploy.MGMT.md)
- [environments/mgmt.env.example](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/environments/mgmt.env.example)

І тільки тоді підключай:

- `ArgoCD`
- `Kargo`
- `ApplicationSet`
- `argocd cluster add`

## 13. Troubleshooting

### cert-manager webhook x509 error

Перевірити webhook:

```bash
kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'
kubectl -n cert-manager get secret cert-manager-webhook-ca -o yaml
```

Рестарт:

```bash
kubectl -n cert-manager rollout restart deployment/cert-manager-webhook deployment/cert-manager-cainjector
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
```

Якщо `caBundle` порожній, можна зробити тимчасовий patch:

```bash
CA_BUNDLE="$(kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath='{.data.ca\.crt}')"
kubectl patch validatingwebhookconfiguration cert-manager-webhook --type='json' -p='[{"op":"add","path":"/webhooks/0/clientConfig/caBundle","value":"'"${CA_BUNDLE}"'"}]'
```

### Pod не стартує

```bash
kubectl describe pod <POD_NAME> -n <NAMESPACE>
kubectl logs <POD_NAME> -n <NAMESPACE> --previous
```

### ImagePullBackOff

```bash
kubectl get secret registry-credentials -n <NAMESPACE>
```

### SOPS decrypt помилка

Якщо `sops -d` падає з `failed to get the data key`:

```bash
# Перевірити наявність operator key
ls ~/.config/sops/age/keys.txt
grep "public key" ~/.config/sops/age/keys.txt

# Перевірити що публічний ключ у файлі співпадає з .sops.yaml
cat .sops.yaml | grep "age:"
```

Якщо ключ відсутній — відновити з password manager або з кластера:

```bash
kubectl -n argocd get secret sops-age-key \
  -o jsonpath='{.data.key\.txt}' | base64 -d > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

### Загальна діагностика

```bash
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
```
