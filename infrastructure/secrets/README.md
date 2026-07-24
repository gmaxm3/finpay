# Secret Management — SOPS + age

> PCI-DSS вимога: секрети НЕ повинні зберігатися в plain-text в Git.

## Поточний підхід: SOPS + age

Обраний варіант — **SOPS + age**. Sealed Secrets не використовується.

```
Secret YAML (локально, plain-text)
    ↓ sops -e -i secret.yaml  (шифрування публічними ключами)
Зашифрований YAML (безпечно в Git)
    ↓ ArgoCD CMP plugin (sops decrypt у тимчасовій директорії)
Secret (в кластері)
```

---

## Ключі

| Ключ | Де зберігається | Для чого |
|------|-----------------|---------|
| **Operator** (приватний) | `~/.config/sops/age/keys.txt` + password manager | Локальна робота з секретами |
| **ArgoCD** (приватний) | `kubectl secret sops-age-key -n argocd` + password manager | ArgoCD decrypt при sync |
| **Публічні ключі** | `.sops.yaml` у корені репо | Шифрування нових секретів |

**Публічні ключі** (безпечно зберігати в Git):
- Operator: `age10xmnsfwr9n9my3flngcpm9dsvd0ye3rkguqr40y64fx9adadf34qtt8glg`
- ArgoCD:   `age1248hr3m37cghxalp8maamcec4qyhx2vq9lqxmw4fsv6dfqzkys6qcnrvzq`

---

## Bootstrap (перший раз)

```bash
# Встановити залежності
brew install sops age

# Запустити bootstrap (генерує ключі + шифрує всі секрети)
./infrastructure/secrets/bootstrap-secrets.sh
```

Скрипт:
1. Генерує operator age key → `~/.config/sops/age/keys.txt`
2. Генерує ArgoCD age key → `infrastructure/secrets/.argocd-age-key.txt`
3. Оновлює `.sops.yaml` з реальними публічними ключами
4. Створює та шифрує `secret-*.yaml` для RabbitMQ, Redis, Elasticsearch у всіх overlays
5. Оновлює `kustomization.yaml` overlay-ів — додає посилання на secret файли

**Після bootstrap**: завантажити ArgoCD ключ у кластер (див. `deploy.MGMT.md` крок 4а).

---

## Повсякденна робота

### Зашифрувати новий секрет

```bash
# 1. Створити plain-text secret YAML
cat > k8s-ops/apps/cde/my-service/overlays/prod/secret-my-service.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-service-credentials
  namespace: prod-cde
type: Opaque
stringData:
  api-key: REAL_SECRET_VALUE
EOF

# 2. Зашифрувати (in-place)
sops -e -i k8s-ops/apps/cde/my-service/overlays/prod/secret-my-service.yaml

# 3. Додати до kustomization.yaml overlay-у
# resources:
#   - secret-my-service.yaml

# 4. Закомітити (зашифрований файл — безпечно)
git add k8s-ops/apps/cde/my-service/overlays/prod/secret-my-service.yaml
```

### Переглянути або відредагувати секрет

```bash
# Переглянути розшифрований вміст (тільки stdout, не записує на диск)
sops -d k8s-ops/apps/cde/rabbitmq/overlays/prod/secret-rabbitmq.yaml

# Редагувати (відкриває $EDITOR, зберігає зашифрованим)
sops k8s-ops/apps/cde/rabbitmq/overlays/prod/secret-rabbitmq.yaml
```

### Ротація секретів сервісу

```bash
# Відредагувати новий пароль
sops k8s-ops/apps/cde/my-service/overlays/prod/secret-my-service.yaml
# → змінити значення → зберегти → автоматично зашифрується

git add k8s-ops/apps/cde/my-service/overlays/prod/secret-my-service.yaml
git commit -m "rotate: my-service prod credentials"
# ArgoCD підхопить і перезапустить pod
```

### Ротація age ключів (при компрометації)

```bash
# 1. Згенерувати нові ключі
age-keygen -o ~/.config/sops/age/keys-new.txt
# Отримати новий публічний ключ
NEW_PUBKEY=$(grep "public key" ~/.config/sops/age/keys-new.txt | awk '{print $NF}')

# 2. Додати новий публічний ключ у .sops.yaml (поруч зі старим)
# 3. Перешифрувати всі файли
find k8s-ops -name "secret*.yaml" -exec sops updatekeys --yes {} \;

# 4. Видалити старий ключ з .sops.yaml
# 5. Оновити ArgoCD secret у кластері
kubectl delete secret sops-age-key -n argocd
kubectl create secret generic sops-age-key \
  --namespace argocd \
  --from-file=key.txt=infrastructure/secrets/.argocd-age-key-new.txt
```

---

## Shared secrets — централізовані змінні для всіх CDE сервісів

`k8s-ops/apps/cde/shared-secrets/` — окремий ArgoCD App, який деплоїть один Secret
`shared-secrets` у кожен CDE namespace. Всі сервіси читають його через `envFrom`.

**Містить:** `DEFAULT_URL`, `REDIS_URL`, `RABBITMQ_URL`, `SECRET_KEY`, `DATABASE_URL`

```yaml
# У deployment.yaml кожного CDE сервісу:
envFrom:
  - configMapRef:
      name: my-service-config
  - secretRef:
      name: shared-secrets      # ← всі спільні змінні
```

### Переозначення DATABASE_URL для конкретного сервісу

Якщо сервіс використовує окрему БД — `env` завжди перемагає `envFrom`:

```yaml
envFrom:
  - secretRef:
      name: shared-secrets      # DATABASE_URL = дефолтна БД
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: cards-credentials  # DATABASE_URL = cards schema
        key: DATABASE_URL
```

### Редагування shared secrets

```bash
# Переглянути
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d k8s-ops/apps/cde/shared-secrets/overlays/test/secret-shared.yaml

# Редагувати (відкриє $EDITOR, збереже зашифрованим)
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops k8s-ops/apps/cde/shared-secrets/overlays/prod/secret-shared.yaml
```

---

## PCI certs — спільні сертифікати для cards і ukrcard

`k8s-ops/apps/cde/pci-certs/` — окремий ArgoCD App, який деплоїть Secret `pci-certs`
у кожен CDE namespace. Монтується як volume `/app/certs` в `cards` і `ukrcard`.

**Містить:** `client.crt`, `client.key`, `ca.crt` — mTLS сертифікати для підключення до ПЦ/АБС.

### Заповнити реальними сертифікатами

```bash
# Генеруємо Secret маніфест з файлів сертифікатів
kubectl create secret generic pci-certs \
  --from-file=client.crt=/path/to/client.crt \
  --from-file=client.key=/path/to/client.key \
  --from-file=ca.crt=/path/to/ca.crt \
  --dry-run=client -o yaml \
  > k8s-ops/apps/cde/pci-certs/overlays/test/secret-pci-certs.yaml

# Шифруємо (перезаписує placeholder)
sops -e -i k8s-ops/apps/cde/pci-certs/overlays/test/secret-pci-certs.yaml
```

Повторити для кожного environment. Prod сертифікати зазвичай відрізняються від test.

### Застосувати вручну (без ArgoCD)

```bash
./scripts/maintenance/kustomize-apply.sh k8s-ops/apps/cde/pci-certs/overlays/test
```

---

## Структура секретів у репо

```
k8s-ops/apps/cde/shared-secrets/overlays/
  dev/   secret-shared.yaml    ← DEFAULT_URL, REDIS_URL, RABBITMQ_URL,
  test/                           SECRET_KEY, DATABASE_URL (default)
  stage/
  prod/

k8s-ops/apps/cde/rabbitmq/overlays/
  dev/   secret-rabbitmq.yaml  ← username, password, erlang-cookie
  test/
  stage/
  prod/

k8s-ops/apps/cde/redis/overlays/
  dev/   secret-redis.yaml     ← requirepass
  ...

k8s-ops/apps/cde/elasticsearch/overlays/
  dev/   secret-elasticsearch.yaml  ← username, password, keystore.seed
  ...

k8s-ops/apps/cde/pci-certs/overlays/
  dev/   secret-pci-certs.yaml ← client.crt, client.key, ca.crt
  test/                           (спільні для cards і ukrcard)
  stage/
  prod/

k8s-ops/apps/cde/{service}/overlays/
  dev/   secret-{service}.yaml ← тільки переозначення (напр. DATABASE_URL)
  ...
```

Кожен `overlays/{env}/kustomization.yaml` посилається на свій `secret-*.yaml` через `resources:`.

---

## Типи секретів та де зберігаються

| Секрет | Namespace | Файл |
|--------|-----------|------|
| **Shared** (DEFAULT_URL, REDIS_URL, RABBITMQ_URL, SECRET_KEY, DATABASE_URL) | `{env}-cde` | `cde/shared-secrets/overlays/{env}/secret-shared.yaml` |
| RabbitMQ admin credentials | `{env}-cde` | `cde/rabbitmq/overlays/{env}/secret-rabbitmq.yaml` |
| Redis password | `{env}-cde` | `cde/redis/overlays/{env}/secret-redis.yaml` |
| Elasticsearch credentials | `{env}-cde` | `cde/elasticsearch/overlays/{env}/secret-elasticsearch.yaml` |
| Cards DATABASE_URL override | `{env}-cde` | `cde/cards/overlays/{env}/secret-cards.yaml` |
| PCI certs (cards + ukrcard) | `{env}-cde` | `cde/pci-certs/overlays/{env}/secret-pci-certs.yaml` |
| Registry imagePullSecret | всі | `scripts/bootstrap/04-add-registry-secrets.sh` (не в Git) |
| Kargo git token | `kargo` | `kubectl` вручну (не в Git) |
| ArgoCD admin password | `argocd` | `kubectl` вручну (не в Git) |
| ПЦ/АБС API credentials | `prod-cde` | `cde/{service}/overlays/prod/secret-*.yaml` (SOPS) |
| Internal CA key | `cert-manager` | `kubectl` вручну (не в Git) |

---

## ArgoCD plugin

ArgoCD розшифровує секрети через sidecar CMP (`kustomize-sops`).
Конфігурація: `infrastructure/secrets/sops-argocd-plugin.yaml`

ArgoCD отримує age key з Secret:
```bash
kubectl get secret sops-age-key -n argocd \
  -o jsonpath='{.data.key\.txt}' | base64 -d
```

---

## Важливі правила

- **НІКОЛИ** не комітити `age-key.txt`, `*-age-key.txt` — вони в `.gitignore`
- **НІКОЛИ** не комітити plain-text `secret.yaml` без шифрування
- **ЗАВЖДИ** перевіряти `git diff` перед комітом — зашифрований файл містить `sops:` блок
- Зберігати operator private key у password manager (1Password/Bitwarden)
- Backup ArgoCD private key — також у password manager
