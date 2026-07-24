# Kargo Credentials — налаштування доступів

> Всі credentials створюються вручну через kubectl та НЕ зберігаються в Git.
> Виконувати на management node де встановлено Kargo.

---

## 1. Git credentials (Bitbucket)

Kargo потребує доступ до Git репозиторію для:
- Читання поточного стану overlays
- Запису оновленого image tag/digest після promotion

### Створення Bitbucket repo access token

1. Перейти в Bitbucket → Repository settings → Access tokens
2. Створити token з правами: **Read** + **Write** на repository
3. Скопіювати token (показується один раз)

### Застосування в кластері

```bash
# На management node:
kubectl create secret generic kargo-git-credentials \
  --namespace kargo \
  --from-literal=type=git \
  --from-literal=url=git@bitbucket.org:Kapowai \
  --from-literal=username=x-token-auth \
  --from-literal=password="BITBUCKET_REPO_ACCESS_TOKEN"

kubectl label secret kargo-git-credentials \
  --namespace kargo \
  kargo.akuity.io/secret-type=repository
```

Перевірка:
```bash
kubectl get secret kargo-git-credentials -n kargo
kargo get credentials --project kargo
```

### Ротація

```bash
# Видалити старий secret та створити новий з новим токеном
kubectl delete secret kargo-git-credentials -n kargo
# Повторити команди створення вище з новим токеном
```

---

## 2. Registry credentials (для warehouse polling)

Kargo warehouse поллить image registry щоб знайти нові версії.

```bash
# Створити docker-registry secret в namespace kargo
kubectl create secret docker-registry registry-credentials \
  --namespace kargo \
  --docker-server=hub.kapowai.com.ua \
  --docker-username="REGISTRY_USERNAME" \
  --docker-password="REGISTRY_PASSWORD"

# Позначити як Kargo image credentials
kubectl label secret registry-credentials \
  --namespace kargo \
  kargo.akuity.io/secret-type=image

# Другий registry (ті ж credentials)
kubectl create secret docker-registry registry-credentials-mirror \
  --namespace kargo \
  --docker-server=finpaybank.kapowai.com.ua \
  --docker-username="REGISTRY_USERNAME" \
  --docker-password="REGISTRY_PASSWORD"

kubectl label secret registry-credentials-mirror \
  --namespace kargo \
  kargo.akuity.io/secret-type=image
```

---

## 3. ArgoCD integration credentials

Kargo викликає ArgoCD API для тригеру sync після promotion.

### Крок 1: Додати account "kargo" в ArgoCD

```bash
kubectl patch configmap argocd-cm \
  --namespace argocd \
  --patch '{
    "data": {
      "accounts.kargo": "apiKey",
      "accounts.kargo.enabled": "true"
    }
  }'
```

### Крок 2: Видати права account "kargo"

```bash
kubectl patch configmap argocd-rbac-cm \
  --namespace argocd \
  --patch '{
    "data": {
      "policy.csv": "p, role:kargo, applications, get, */*, allow\np, role:kargo, applications, sync, */*, allow\np, role:kargo, applications, update, */*, allow\ng, kargo, role:kargo\n"
    }
  }'
```

### Крок 3: Згенерувати API token

```bash
# Отримати token для account kargo
ARGOCD_TOKEN=$(argocd account generate-token --account kargo)
echo "Token: $ARGOCD_TOKEN"
```

### Крок 4: Зберегти token в Kargo namespace

```bash
kubectl create secret generic argocd-credentials \
  --namespace kargo \
  --from-literal=token="$ARGOCD_TOKEN" \
  --from-literal=url="https://argocd-server.argocd.svc.cluster.local"

kubectl label secret argocd-credentials \
  --namespace kargo \
  kargo.akuity.io/secret-type=argocd
```

---

## 4. Перевірка всіх credentials

```bash
# Список всіх Kargo credentials secrets
kubectl get secrets -n kargo \
  -l kargo.akuity.io/secret-type

# Перевірити підключення до git
kargo check-health --project kargo

# Перевірити warehouse може бачити images
kargo get freights --project SERVICE_NAME

# Перевірити ArgoCD integration
kargo get stages --project SERVICE_NAME
```

---

## 5. Що зберігається де

| Credentials | Де зберігається | Метод |
|-------------|----------------|-------|
| Bitbucket repo token | Secret `kargo-git-credentials` в namespace `kargo` | kubectl (не в Git) |
| Registry username/password | Secret `registry-credentials` в namespace `kargo` | kubectl (не в Git) |
| ArgoCD API token | Secret `argocd-credentials` в namespace `kargo` | kubectl (не в Git) |
| Kargo admin password hash | Helm values при встановленні | `03-install-kargo.sh` |

**Жоден з цих секретів НЕ повинен бути в Git.**
