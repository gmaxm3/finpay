# Додавання нового сервісу

## Зміст

1. [Визначення зони (DMZ або CDE)](#1-визначення-зони)
2. [Як ApplicationSets знаходять сервіси](#2-як-applicationsets-знаходять-сервіси)
3. [Стандартний flow: всі середовища](#3-стандартний-flow-всі-середовища)
4. [Dev-only сервіс (поступовий rollout)](#4-dev-only-сервіс)
5. [Сервіс тільки для одного середовища](#5-сервіс-тільки-для-одного-середовища)
6. [Kargo pipeline](#6-kargo-pipeline)
7. [Ingress і домени](#7-ingress-і-домени)
8. [TLS сертифікат](#8-tls-сертифікат)
9. [Покроковий чеклист](#9-покроковий-чеклист)

---

## 1. Визначення зони

| Зона | Коли використовувати |
|------|----------------------|
| **DMZ** | Інтернет-трафік, push/SMS, frontend, API gateway, зовнішні payment APIs |
| **CDE** | PostgreSQL, PCI дані, ESB сервіси (cards/payments/deposits), Redis, RabbitMQ, ПЦ/АБС |

Якщо сервіс підходить під обидві зони — вибирати **CDE** (суворіша безпека).

---

## 2. Як ApplicationSets знаходять сервіси

**Принцип роботи:** git generator сканує директорії `k8s-ops/apps/{zone}/*` і для кожної знайденої директорії створює ArgoCD Application, що вказує на `overlays/{env}`.

```
k8s-ops/apps/cde/my-service/   ← git generator знайшов директорію
                               ↓
dev-appset    → Application "my-service-cde-dev"   → overlays/dev
test-appset   → Application "my-service-cde-test"  → overlays/test
stage-appset  → Application "my-service-cde-stage" → overlays/stage
prod-cde-appset → Application "my-service-cde-prod" → overlays/prod
```

**Важливо:** якщо директорія сервісу існує, але overlay для певного середовища відсутній — ArgoCD все одно створює Application, але він падає в стан `ComparisonError: path not found`. Це не тихе "не деплоїться", а видима помилка в ArgoCD UI.

**Висновок:** кожна директорія сервісу повинна мати overlays для всіх середовищ де є відповідний appset.

---

## 3. Стандартний flow: всі середовища

### Структура директорій

```
k8s-ops/apps/cde/my-service/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   ├── networkpolicy.yaml
│   └── configmap.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patch-replicas.yaml    # replicas: 1
    ├── test/
    │   ├── kustomization.yaml
    │   └── patch-replicas.yaml    # replicas: 1
    ├── stage/
    │   ├── kustomization.yaml
    │   └── patch-replicas.yaml    # replicas: 2
    └── prod/
        ├── kustomization.yaml
        └── patch-replicas.yaml    # replicas: 2
```

### Promotion flow

```
CI push image → Kargo Warehouse
                     ↓ (auto)
                   dev ──────────────────────────────────── ArgoCD auto sync
                     ↓ (auto, після успішного dev)
                   test ─────────────────────────────────── ArgoCD manual sync
                     ↓ (manual approval від release-manager)
                   stage ────────────────────────────────── ArgoCD manual sync
                     ↓ (manual approval від prod-operator)
                   prod ─────────────────────────────────── ArgoCD manual sync
```

### Кроки

```bash
# 1. Скопіювати шаблон
cp -r k8s-ops/apps/cde/_template k8s-ops/apps/cde/my-service

# 2. Замінити плейсхолдери
find k8s-ops/apps/cde/my-service -type f \( -name "*.yaml" \) \
  -exec sed -i 's/SERVICE_NAME/my-service/g; s/SERVICE_PORT/8080/g' {} \;

# 3. Видалити CONTAINER_IMAGE з base (він задається в overlay через kustomize images)
# 4. Налаштувати resources requests/limits під конкретний сервіс

# 5. Перевірити що всі overlays білдяться
kubectl kustomize k8s-ops/apps/cde/my-service/overlays/dev
kubectl kustomize k8s-ops/apps/cde/my-service/overlays/test
kubectl kustomize k8s-ops/apps/cde/my-service/overlays/stage
kubectl kustomize k8s-ops/apps/cde/my-service/overlays/prod

# 6. Комміт → ArgoCD автоматично виявить сервіс (~30 сек)
git add k8s-ops/apps/cde/my-service/
git commit -m "feat(cde): add my-service manifests"
```

---

## 4. Dev-only сервіс

Сценарій: новий сервіс готовий тільки до dev, на test/stage/prod поки не потрібен.

### Підхід: replicas: 0 в non-dev overlays

Всі overlays створюються (щоб ArgoCD не падав з помилкою), але поди не запускаються:

```yaml
# overlays/test/patch-replicas.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  replicas: 0
```

```yaml
# overlays/test/kustomization.yaml
resources:
  - ../../base
patches:
  - path: patch-replicas.yaml
images:
  - name: CONTAINER_IMAGE
    newTag: "placeholder"   # Kargo замінить коли буде готово до promotion
```

Те саме для `overlays/stage` і `overlays/prod`.

### Коли готово до promotion на test

1. Змінити `replicas: 0` → `replicas: 1` в `overlays/test/patch-replicas.yaml`
2. Закомітити
3. Запустити Kargo promotion або дочекатись автоматичного (якщо pipeline налаштований)

### Kargo pipeline для dev-only

Якщо сервіс поки тільки на dev — можна не створювати Kargo pipeline взагалі. Деплой на dev через ArgoCD auto sync після зміни image tag в `overlays/dev/kustomization.yaml` вручну.

Коли сервіс готовий до повного promotion pipeline — додати `k8s-ops/kargo/my-service/` (див. розділ 6).

---

## 5. Сервіс тільки для одного середовища

### Сервіс тільки в prod (наприклад, HSM-адаптер)

**Проблема:** якщо покласти в `k8s-ops/apps/cde/my-service`, то dev/test/stage appsets теж спробують його підхопити.

**Рішення A (простіше):** всі overlays є, але dev/test/stage мають `replicas: 0`. Kargo pipeline не створюється. Деплой на prod — вручну через ArgoCD після ручної зміни image tag.

**Рішення B (чистіше, потребує зміни appsets):** додати в git generator appset фільтр за наявністю файлу-маркера. Наприклад, `overlays/{env}/.deploy-enabled`. Appset сканує тільки директорії де є цей файл. Потребує модифікації всіх 5 appset файлів.

### Сервіс тільки в dev (mock, інструментальний)

Те саме що dev-only вище — всі overlays, але test/stage/prod мають `replicas: 0` і `newTag: "placeholder"`.

Альтернатива: тримати такі сервіси в окремій зоні `k8s-ops/apps/dev-only/` з окремим appset що сканує тільки цю папку і деплоїть тільки на dev кластер. Потребує нового appset файлу.

---

## 6. Kargo pipeline

Kargo pipeline потрібен для автоматичного просування image між середовищами.

```bash
# Скопіювати шаблон pipeline
cp -r k8s-ops/kargo/_template k8s-ops/kargo/my-service

# Замінити плейсхолдери
find k8s-ops/kargo/my-service -type f -name "*.yaml" \
  -exec sed -i 's/SERVICE_NAME/my-service/g; s/ZONE/cde/g' {} \;
```

### Структура pipeline

```
k8s-ops/kargo/my-service/
├── project.yaml          # Kargo Project (namespace ізоляція)
├── project-config.yaml   # RBAC для promotion
├── warehouse.yaml        # Слідкує за новими image tags в registry
└── stages.yaml           # dev → test → stage → prod stages
```

### Перевірка pipeline

```bash
kargo get freights --project my-service
kargo get stages --project my-service

# Ручний promote на конкретний stage
kargo promote --project my-service --freight FREIGHT_ID --stage test
```

---

## 7. Ingress і домени

### Типи Ingress

| Label на Ingress | Домен | Traefik entrypoint | Port | Статус |
|-----------------|-------|--------------------|------|--------|
| `ingress-type: external` | `online-{env}.finpay.com.ua` | `websecure` | 443 | активний |
| `ingress-type: internal` | `internal-{env}.finpay.com.ua` | `internal` | 8443 | заплановано |
| `ingress-type: admin` | `admin-{env}.finpay.com.ua` | `internal` | 8443 | заплановано |

### Як працює підстановка домену

Домен задається **один раз на env** у Kustomize component:

```
k8s-ops/components/cluster-domains/
├── dev/kustomization.yaml    ← online-dev.finpay.com.ua
├── test/kustomization.yaml   ← online-test.finpay.com.ua
├── stage/kustomization.yaml  ← online-stage.finpay.com.ua
└── prod/kustomization.yaml   ← online.finpay.com.ua
```

Component автоматично патчить host у всіх Ingress ресурсах що мають відповідний label.

### Новий сервіс з Ingress

**Крок 1.** Додати label `ingress-type: external` до `base/ingress.yaml`:
```yaml
metadata:
  labels:
    ingress-type: external
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
```

**Крок 2.** Ingress без `spec.tls` — TLS сертифікат роздається через TLSStore (kube-system):
```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: REPLACE_HOST  # буде замінено component
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

**Крок 3.** Підключити component у кожен overlay:
```yaml
# overlays/test/kustomization.yaml
resources:
  - ../../base
components:
  - ../../../../../components/cluster-domains/test
```

Більше нічого не треба — домен підставиться автоматично, cert обслуговується глобально через TLSStore.

### Змінити домен середовища

Відредагувати один файл, наприклад для test:
```
k8s-ops/components/cluster-domains/test/kustomization.yaml
```
Змінити `value: online-test.finpay.com.ua` → нове значення. Всі сервіси підхоплять після commit.

---

## 8. TLS сертифікат

### Архітектура

Використовується **один wildcard сертифікат** `*.finpay.com.ua`. Traefik має глобальний TLS (`--entryPoints.websecure.http.tls=true`), тому cert задається через **TLSStore** в `kube-system` — один раз на кластер.

```
infrastructure/traefik/
├── base/
│   ├── tlsstore.yaml                    ← TLSStore: defaultCertificate: finpay-wildcard-tls
│   └── kustomization.yaml
└── overlays/
    ├── dev/secret-wildcard-tls.yaml     ← SOPS зашифрований, namespace: kube-system
    ├── test/secret-wildcard-tls.yaml
    ├── stage/secret-wildcard-tls.yaml
    └── prod/secret-wildcard-tls.yaml
```

Сервіси **не потребують** `spec.tls` в Ingress — wildcard cert роздається автоматично для всіх websecure connections.

### Додати новий домен (окремий сертифікат)

Додати секрет в `kube-system` і дописати в `infrastructure/traefik/base/tlsstore.yaml`:

```yaml
spec:
  defaultCertificate:
    secretName: finpay-wildcard-tls
  certificates:
    - secretName: other-domain-tls    # ← новий домен
```

Traefik автоматично підбирає потрібний cert через SNI.

### Додати/оновити сертифікат

```bash
# 1. Створити plain-text файл (не комітити!)
cp infrastructure/traefik/overlays/test/secret-wildcard-tls.yaml.example \
   infrastructure/traefik/overlays/test/secret-wildcard-tls.yaml

# 2. Вставити cert та key
#    tls.crt — повний ланцюжок: wildcard cert + intermediate CA
#    tls.key — приватний ключ
#    namespace: kube-system

# 3. Зашифрувати
sops -e -i infrastructure/traefik/overlays/test/secret-wildcard-tls.yaml

# 4. Повторити для інших env (dev, stage, prod)

# 5. Застосувати на кластер
kubectl kustomize infrastructure/traefik/overlays/test | kubectl apply -f -
# (SOPS decryption виконує ArgoCD якщо є Application, або sops -d вручну)

# 6. Commit
git add infrastructure/traefik/
git commit -m "chore: update wildcard TLS certificate"
```

### Редагувати існуючий сертифікат

```bash
sops infrastructure/traefik/overlays/test/secret-wildcard-tls.yaml
# редагуєш tls.crt і tls.key → зберігаєш → SOPS автоматично перешифровує
```

Після apply Traefik автоматично підхоплює оновлений secret (або потребує `kubectl rollout restart deployment/traefik -n kube-system`).

### Структура plain-text secret (до шифрування)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: finpay-wildcard-tls
  namespace: kube-system
type: kubernetes.io/tls
stringData:
  tls.crt: |
    -----BEGIN CERTIFICATE-----
    <wildcard cert *.finpay.com.ua>
    -----END CERTIFICATE-----
    -----BEGIN CERTIFICATE-----
    <intermediate CA — GoDaddy G2>
    -----END CERTIFICATE-----
  tls.key: |
    -----BEGIN PRIVATE KEY-----
    <private key>
    -----END PRIVATE KEY-----
```

---

## 9. Покроковий чеклист

### Новий стандартний сервіс (всі середовища)

- [ ] Визначити зону: DMZ або CDE
- [ ] `cp -r k8s-ops/apps/{zone}/_template k8s-ops/apps/{zone}/SERVICE_NAME`
- [ ] Замінити `SERVICE_NAME`, `SERVICE_PORT` у всіх файлах
- [ ] Налаштувати `resources` requests/limits
- [ ] Для CDE: додати `envFrom: [{secretRef: {name: shared-secrets}}]`
- [ ] Перевірити PCI-DSS вимоги: securityContext, NetworkPolicy, probes, ServiceAccount
- [ ] `kubectl kustomize` для кожного overlay — жодних помилок
- [ ] `cp -r k8s-ops/kargo/_template k8s-ops/kargo/SERVICE_NAME` + замінити плейсхолдери
- [ ] Зашифрувати service-specific secrets: `sops -e -i overlays/{env}/secret-SERVICE_NAME.yaml`
- [ ] Commit + push → перевірити що ArgoCD створив Application на dev
- [ ] Перевірити що поди запустились: `kubectl get pods -n dev-cde`

### Сервіс з Ingress (додатково до стандартного чеклисту)

- [ ] Додати label `ingress-type: external` та Traefik annotations до `base/ingress.yaml`
- [ ] **Не додавати** `spec.tls` — cert роздається глобально через TLSStore в kube-system
- [ ] Встановити `REPLACE_HOST` як placeholder для host у `spec.rules`
- [ ] Додати `components: [../../../../../components/cluster-domains/{env}]` в кожен overlay
- [ ] Переконатись що TLSStore і secret задеплоєні на кластер:
  ```bash
  kubectl get tlsstore default -n kube-system
  kubectl get secret finpay-wildcard-tls -n kube-system
  ```
- [ ] Перевірити що домен підставився: `kubectl kustomize overlays/test | grep host:`
- [ ] Перевірити TLS: `echo | openssl s_client -connect {domain}:443 -servername {domain} 2>/dev/null | openssl x509 -noout -subject`

### Dev-only сервіс (поступовий rollout)

- [ ] Всі кроки зі стандартного чеклисту вище
- [ ] В `overlays/test`, `overlays/stage`, `overlays/prod`: `replicas: 0`, `newTag: "placeholder"`
- [ ] Kargo pipeline не створювати (або створити але не активувати promotion на test/stage/prod)
- [ ] Коли готово до test: змінити `replicas: 0` → `1` в `overlays/test`, закомітити

### Перевірка після деплою на dev

```bash
# ArgoCD Application статус
kubectl get applications -n argocd | grep SERVICE_NAME

# Поди
kubectl get pods -n dev-cde -l app=SERVICE_NAME

# Логи
kubectl logs -n dev-cde -l app=SERVICE_NAME --tail=50

# Kargo freights
kargo get freights --project SERVICE_NAME
```
