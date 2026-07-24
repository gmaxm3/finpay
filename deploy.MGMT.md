# Deploy Management Cluster

Цей файл описує встановлення окремого `management` cluster для:

- `ArgoCD`
- `Kargo`
- підключення workload cluster-ів

Цей сценарій треба виконувати тільки після того, як є окремий `mgmt` сервер з `k3s`.

Для ручного розгортання `test` без `mgmt` дивись [deploy.TEST.md](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/deploy.TEST.md).

## 1. Що потрібно

- окремий сервер для `management`
- `sudo` доступ
- локально встановлені `kubectl`, `argocd`, `helm`, `kustomize`
- доступ до Bitbucket
- доступ до registry

## 2. Визначити змінні

Основний варіант: створити власний env-файл на основі шаблону [environments/mgmt.env.example](/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/environments/mgmt.env.example).

Наприклад:

```bash
cp environments/mgmt.env.example environments/mgmt.env
```

Потім заповнити значення і завантажити їх:

```bash
set -a
source environments/mgmt.env
set +a
```

## 3. Встановити k3s на management host

```bash
ssh "${MGMT_HOST}" -l ubuntu "sudo bash -s" < scripts/bootstrap/01-install-k3s.sh
```

Забрати kubeconfig:

```bash
ssh "${MGMT_HOST}" -l ubuntu "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/${MGMT_NODE_IP}/" > ~/.kube/finpaybank-management

chmod 600 ~/.kube/finpaybank-management
export KUBECONFIG=~/.kube/finpaybank-management
kubectl get nodes -o wide
```

## 4. Встановити ArgoCD

```bash
ssh "${MGMT_HOST}" -l ubuntu \
  "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash -s" \
  < scripts/bootstrap/02-install-argocd.sh
```

Отримати початковий пароль:

```bash
ssh "${MGMT_HOST}" -l ubuntu \
  "sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

Локальний доступ:

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd login localhost:8080 --username admin --insecure
```

## 4а. Завантажити SOPS age key в ArgoCD

> Виконується одразу після встановлення ArgoCD, до першого sync.
> ArgoCD не зможе синхронізувати застосунки із зашифрованими секретами без цього кроку.

```bash
export KUBECONFIG=~/.kube/finpaybank-management
```

Завантажити приватний ArgoCD age key (генерується в `infrastructure/secrets/bootstrap-secrets.sh`):

```bash
kubectl create secret generic sops-age-key \
  --namespace argocd \
  --from-file=key.txt=/Users/xeon/.config/sops/age/keys.txt # Путь до локального ключа ~/.config/sops/age/keys.txt
```

Застосувати SOPS plugin ConfigMap:

```bash
kubectl apply -k infrastructure/secrets/
```

Застосувати patch для argocd-repo-server (sidecar + age key mount):

```bash
kubectl patch deployment argocd-repo-server -n argocd \
  --patch-file infrastructure/secrets/sops-argocd-plugin-patch.yaml
```

Перевірити, що argocd-repo-server підхопив age key:

```bash
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=120s

# Перевірити що env змінна SOPS_AGE_KEY_FILE видима в контейнері
kubectl -n argocd exec deployment/argocd-repo-server -c kustomize-sops -- \
  printenv SOPS_AGE_KEY_FILE
# Очікується: /sops-age-key/key.txt
```

Backup ArgoCD age key (зберегти в password manager — якщо загубиш, секрети не розшифруються):

```bash
# Витягнути ключ з кластера (він там вже є як Secret)
kubectl -n argocd get secret sops-age-key \
  -o jsonpath='{.data.key\.txt}' | base64 -d
```

## 5. Додати repo credentials в ArgoCD

```bash
ssh-keygen -t ed25519 -C "argocd@finpaybank" -f ~/.ssh/argocd_bitbucket_ed25519 -N ""
cat ~/.ssh/argocd_bitbucket_ed25519.pub
```

Після додавання ключа в Bitbucket:

```bash
export KUBECONFIG=~/.kube/finpaybank-management

kubectl create secret generic argocd-repo-creds-bitbucket \
  --from-literal=type=git \
  --from-literal=url=git@bitbucket.org:Kapowai \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd_bitbucket_ed25519 \
  -n argocd

kubectl label secret argocd-repo-creds-bitbucket \
  argocd.argoproj.io/secret-type=repo-creds -n argocd
```

## 6. Встановити cert-manager у management cluster

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kubectl apply -k infrastructure/cert-manager/overlays/management/
kubectl -n cert-manager rollout status deployment --timeout=180s
```

Перший `apply` створить CRDs але не зможе застосувати ClusterIssuer/Certificate — це нормально.
Після того як webhook готовий, застосуй ще раз:

```bash
kubectl apply -k infrastructure/cert-manager/overlays/management/
```

Якщо другий apply падає з `x509: certificate signed by unknown authority` — виконай patch caBundle (дивись troubleshooting нижче) і повтори `apply`.

## 6а. Створити internal CA (management — внутрішня мережа)

Management cluster не має публічного IP — використовуємо internal CA замість Let's Encrypt.

```bash
# Генеруємо CA key та self-signed cert
openssl genrsa -out internal-ca.key 4096
openssl req -new -x509 -key internal-ca.key -out internal-ca.crt \
  -days 3650 -subj "/CN=FinPayBank Internal CA/O=FinPayBank"

# Завантажуємо в кластер
kubectl create secret tls internal-ca-secret \
  --cert=internal-ca.crt \
  --key=internal-ca.key \
  -n cert-manager

# Зберегти internal-ca.key в password manager, потім видалити локально
rm internal-ca.key internal-ca.crt

# Застосувати certificates (тепер internal-ca готовий)
kubectl apply -k infrastructure/cert-manager/overlays/management/
kubectl get clusterissuer
kubectl get certificate -A
```

```bash
kubectl get crd certificates.cert-manager.io issuers.cert-manager.io
```

## 7. Встановити Kargo

```bash
export KARGO_ADMIN_PASSWORD_HASH="$(htpasswd -bnBC 10 "" 'STRONG_PASSWORD' | tr -d ':\n')"
export KARGO_TOKEN_SIGNING_KEY="$(openssl rand -base64 48 | tr -d '=+/' | head -c 32)"
```

```bash
ssh "${MGMT_HOST}" -l ubuntu "sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml KARGO_ADMIN_PASSWORD_HASH='${KARGO_ADMIN_PASSWORD_HASH}' KARGO_TOKEN_SIGNING_KEY='${KARGO_TOKEN_SIGNING_KEY}' bash -s" < scripts/bootstrap/03-install-kargo.sh
```

Перевірка:

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kubectl -n kargo get pods
kubectl port-forward svc/kargo-api -n kargo 8081:443
```

## 8. Підключити workload clusters в ArgoCD

Для `test` cluster:

```bash
KUBECONFIG=~/.kube/finpaybank-test argocd cluster add \
  --name test \
  "$(KUBECONFIG=~/.kube/finpaybank-test kubectl config current-context)" \
  --yes
```

## 9. Налаштувати Kargo integration

Увімкнути apiKey для admin (необхідно для генерації токена):

```bash
kubectl -n argocd patch configmap argocd-cm \
  -p '{"data":{"accounts.admin":"apiKey,login"}}'
```

Створити token в ArgoCD:

```bash
argocd account generate-token
```

Потім:

```bash
export KUBECONFIG=~/.kube/finpaybank-management
export BITBUCKET_REPO_TOKEN='<BITBUCKET_REPO_TOKEN>'
export ARGOCD_TOKEN='<ARGOCD_TOKEN>'
export REGISTRY_USERNAME='<REGISTRY_USERNAME>'
export REGISTRY_PASSWORD='<REGISTRY_PASSWORD>'

scripts/bootstrap/06-bootstrap-kargo.sh
kubectl apply -k k8s-ops/kargo/
```

## 10. Увімкнути GitOps для test

Після того як `test` cluster зареєстрований:

```bash
export KUBECONFIG=~/.kube/finpaybank-management
kubectl apply -f k8s-ops/argocd/projects/
kubectl apply -f k8s-ops/argocd/applicationsets/
kubectl -n argocd get applicationsets
argocd app list
```

## 11. Troubleshooting

### cert-manager webhook x509 error

```bash
kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'
kubectl -n cert-manager get secret cert-manager-webhook-ca -o yaml
kubectl -n cert-manager rollout restart deployment/cert-manager-webhook deployment/cert-manager-cainjector
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
```

Якщо `caBundle` порожній:

```bash
CA_BUNDLE="$(kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath='{.data.ca\.crt}')"
kubectl patch validatingwebhookconfiguration cert-manager-webhook --type='json' -p='[{"op":"add","path":"/webhooks/0/clientConfig/caBundle","value":"'"${CA_BUNDLE}"'"}]'
```
