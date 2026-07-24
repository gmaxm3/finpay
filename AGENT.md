# AGENT.md — Інструкції для Claude при роботі з finpaybank-gitops

> Цей файл читається Claude на початку кожної сесії роботи з репозиторієм.
> Тут зібрані всі архітектурні рішення, правила та процедури.

---

## 1. Огляд архітектури

### Машини та кластери

| Машина | Роль | Кластер/Namespace |
|--------|------|-------------------|
| dev-node | k3s non-prod | namespaces: `dev-dmz`, `dev-cde` |
| test-node | k3s non-prod | namespaces: `test-dmz`, `test-cde` |
| stage-node-1,2 | k3s non-prod HA | namespaces: `stage-dmz`, `stage-cde` |
| prod-dmz (2 ноди) | k3s prod, internet-facing | namespace: `prod` |
| prod-cde (3 ноди) | k3s prod, PCI-DSS scope | namespace: `prod` |
| management-node | ArgoCD hub + Kargo | управляє всіма кластерами |
| observability-node | Prometheus + Loki + Grafana | моніторинг |

### Зони безпеки

**DMZ** (`zone: dmz`) — має доступ до інтернету:
- frontend (Angular SPA)
- Traefik ingress (cde-proxy: IngressRoute → CDE Traefik NodePort)
- push-gateway (FCM)
- sms-service
- Будь-який сервіс з outbound internet

**CDE** (`zone: cde`) — БЕЗ інтернету, PCI-DSS scope:
- ESB сервіси: cards, payments, deposits, accounts, ...
- Redis (StatefulSet)
- RabbitMQ (StatefulSet)
- Сервіси з доступом до ПЦ, АБС, PostgreSQL

### Правило DMZ ↔ CDE
```
DMZ → RabbitMQ (CDE, port 5672) → ESB сервіси виконують задачі
```
- RabbitMQ живе в CDE
- DMZ має тільки outbound egress до RabbitMQ port 5672
- Кожен DMZ сервіс — окремий RabbitMQ user з правами лише на свою чергу

### PostgreSQL
- Bare metal поза K8s: db-primary + db-replica
- Підключення ТІЛЬКИ з CDE namespace
- Адреса: `POSTGRES_PRIMARY_IP:5432`

---

## 2. Правила визначення зони для нового сервісу

### Сервіс іде в DMZ якщо:
- [ ] Приймає трафік з інтернету (є `ports:` в docker-compose з публічним доступом)
- [ ] Надсилає push notifications або SMS
- [ ] Є frontend або API gateway
- [ ] Підключається до зовнішніх payment provider APIs

### Сервіс іде в CDE якщо:
- [ ] Має доступ до PostgreSQL з фінансовими даними
- [ ] Є ESB сервісом (cards, payments, deposits, accounts, transfers...)
- [ ] Підключається до ПЦ (платіжний центр) або АБС (core banking)
- [ ] Є Redis або RabbitMQ (stateful data)
- [ ] Обробляє PAN/CVV або інші cardholder data

### Якщо сервіс підходить під обидва — вибирати CDE (суворіша безпека).

---

## 3. Процедура додавання нового сервісу

### Кроки (виконувати по порядку):

#### 3.1 Визначити зону (DMZ або CDE)
Використовувати правила з розділу 2.

#### 3.2 Скопіювати _template
```bash
# Для DMZ сервісу:
cp -r k8s-ops/apps/dmz/_template k8s-ops/apps/dmz/SERVICE_NAME

# Для CDE сервісу:
cp -r k8s-ops/apps/cde/_template k8s-ops/apps/cde/SERVICE_NAME
```

#### 3.3 Замінити плейсхолдери в base/
Знайти та замінити:
- `SERVICE_NAME` → ім'я сервісу (lowercase-kebab-case)
- `SERVICE_PORT` → порт сервісу
- `CONTAINER_IMAGE` → залишити як змінну (замінюється в overlay)
- `SECRET_MANAGER` → залишити як коментар
- Налаштувати ресурси requests/limits під конкретний сервіс

#### 3.4 Налаштувати overlays
Для кожного середовища (dev/test/stage/prod):
- Встановити image tag (для dev/test — `:latest` або конкретний тег)
- Встановити replicas (dev: 1, test: 1, stage: 2, prod: 2+)
- Налаштувати env-специфічні ConfigMap values

#### 3.5 Налаштувати NetworkPolicy
- DMZ: дозволити egress до RabbitMQ в CDE
- CDE: дозволити ingress тільки від конкретних DMZ сервісів
- Обидві зони: дозволити DNS (port 53)

#### 3.6 Створити Kargo pipeline
```bash
mkdir -p k8s-ops/kargo/SERVICE_NAME
cp k8s-ops/kargo/_template/* k8s-ops/kargo/SERVICE_NAME/
# Замінити SERVICE_NAME у скопійованих файлах
```

#### 3.7 Оновити документацію
- [ ] Додати сервіс до таблиці в README.md (секція "Сервіси")
- [ ] Якщо змінилася архітектура — оновити AGENT.md

#### 3.8 Перевірка (обов'язково)
```bash
# Перевірити що kustomize build проходить без помилок
kubectl kustomize k8s-ops/apps/DMZ_OR_CDE/SERVICE_NAME/overlays/dev

# Перевірити що всі PCI-DSS вимоги виконані (чекліст нижче)
```

---

## 4. PCI-DSS чекліст для кожного сервісу

Перед комітом перевірити що в кожному Deployment є:

### SecurityContext (Pod рівень)
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
```

### SecurityContext (Container рівень)
```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

### RBAC
- [ ] Окремий ServiceAccount з ім'ям сервісу
- [ ] `automountServiceAccountToken: false`
- [ ] Role з мінімальними правами
- [ ] RoleBinding

### NetworkPolicy
- [ ] Default deny all (ingress та egress)
- [ ] Явне дозволення тільки потрібних портів та namespace
- [ ] CDE: відсутній internet egress
- [ ] DNS egress дозволено (port 53 UDP/TCP)

### Probes
- [ ] livenessProbe
- [ ] readinessProbe
- [ ] startupProbe

### Resources
- [ ] requests.cpu та requests.memory встановлені
- [ ] limits.cpu та limits.memory встановлені

### Images
- [ ] imagePullSecrets з обома registry
- [ ] prod overlay: digest-based image reference (не `:latest`)

### Secrets
- [ ] НЕ має plain-text секретів в Git
- [ ] Використовує SECRET_MANAGER placeholder або реальний механізм

---

## 5. Процедура оновлення існуючого сервісу

### Оновлення image (нова версія):
1. Оновити image tag в overlay відповідного середовища
2. Kargo автоматично підхопить нову версію з registry warehouse
3. Promotion відбувається: dev → test → (approval) → stage → (approval) → prod

### Оновлення конфігурації:
1. Змінити ConfigMap або env vars в потрібному overlay
2. Якщо зміна стосується всіх середовищ — змінювати в base/
3. Комітити та пушити — ArgoCD підхопить автоматично (dev/test)

### Зміна NetworkPolicy:
1. Редагувати `networkpolicy.yaml` в base/ (або overlay якщо env-специфічно)
2. Обов'язково тестувати на dev перед просуванням

### Додавання нового env var:
- Non-secret: додати в ConfigMap
- Secret: додати через SECRET_MANAGER, додати reference в deployment

---

## 6. Secret management правила

### Поточна конфігурація
`SECRET_MANAGER` — не визначено остаточно. Варіанти:
- **Sealed Secrets**: `kubeseal` шифрує Secret → `SealedSecret` CRD, безпечно в Git
- **SOPS + age**: шифрує YAML файли з секретами, ключі в age/gpg

### Правила (незалежно від вибраного механізму):
- **НІКОЛИ** не комітити plain-text Secret у Git
- Всі Secret файли повинні бути або `.sealed.yaml` або `sops`-зашифровані
- Credentials для Registry зберігаються як imagePullSecret в кожному namespace
- Database credentials — тільки в CDE namespace
- RabbitMQ credentials — per-service, per-queue
- Kargo git credentials — Secret в namespace `kargo` (не в Git)

### Placeholder convention:
Поки SECRET_MANAGER не визначено, використовуємо коментарі:
```yaml
# SECRET_MANAGER: замінити на SealedSecret або SOPS encrypted
# значення: base64(YOUR_SECRET_VALUE)
value: "REPLACE_WITH_SECRET"
```

---

## 7. Registry imagePullSecrets

Два registry з однаковими credentials:
- `hub.kapowai.com.ua`
- `finpaybank.kapowai.com.ua`

Secret name: `registry-credentials` (в кожному namespace)

Кожен Deployment мусить мати:
```yaml
imagePullSecrets:
  - name: registry-credentials
```

Для оновлення credentials — використовувати:
```bash
scripts/maintenance/rotate-registry-secrets.sh
```

---

## 8. Заборони (НЕ робити)

- **НЕ** комітити plain-text паролі, tokens, keys в Git
- **НЕ** запускати контейнери від root (runAsUser: 0)
- **НЕ** використовувати `:latest` tag в prod overlay (тільки digest або конкретна версія)
- **НЕ** давати `allowPrivilegeEscalation: true`
- **НЕ** монтувати ServiceAccount token якщо не потрібен (`automountServiceAccountToken: false`)
- **НЕ** відкривати internet egress з CDE namespace
- **НЕ** підключати PostgreSQL з DMZ namespace
- **НЕ** використовувати `default` ServiceAccount
- **НЕ** давати широкі RBAC права (wildcards `*`)
- **НЕ** робити manual kubectl apply в prod без ArgoCD/Kargo

---

## 9. Каталог сервісів

### DMZ сервіси (`k8s-ops/apps/dmz/`)

| Сервіс | Image | Internet egress | Особливості |
|--------|-------|----------------|-------------|
| `static` | `finpaybank.kapowai.com.ua/finpaybank/static:26.03.1` | — | Frontend assets |
| `onboarding-web` | `finpay.kapowai.com.ua/webviews-on-boarding:1.0.0` | — | Web SPA |
| `push-gateway` | `finpaybank.kapowai.com.ua/finpaybank/push-gateway:26.01.1` | FCM :443 | Google credentials via Secret |
| `sms` | `hub.kapowai.com.ua/finpaybank/sms:26.02.1` | SMS :443/:80 | Переміщено з CDE |
| `kyc-liveness-web` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-web:25.08.01` | — | KYC UI |

### CDE StatefulSets (`k8s-ops/apps/cde/`)

| Сервіс | Image | Storage | Node | Credentials |
|--------|-------|---------|------|-------------|
| `redis` | `redis:8` | 10Gi→50Gi | data node | SECRET_MANAGER: requirepass |
| `rabbitmq` | `rabbitmq:4-management` | 10Gi→50Gi | data node | SECRET_MANAGER: admin user |
| `elasticsearch` | `elasticsearch:7.4.2` | 50Gi→200Gi | data node | xpack.security + SECRET_MANAGER |
| `minio` | `minio/minio` | 50Gi | data node | SECRET_MANAGER: access/secret key |

### CDE ESB Deployments (`k8s-ops/apps/cde/`)

| Сервіс | Image | PCI-certs | Залежності |
|--------|-------|-----------|-----------|
| `identity` | `hub.kapowai.com.ua/finpaybank/identity:25.09.3` | — | redis, rabbitmq |
| `cards` | `finpaybank.kapowai.com.ua/finpaybank/cards:latest` | ✓ cert/key/hmac | redis, rabbitmq |
| `cards-worker` | `finpaybank.kapowai.com.ua/finpaybank/cards-worker:latest` | — | redis, rabbitmq |
| `customer` | `finpaybank.kapowai.com.ua/finpaybank/customer:latest` | — | redis, rabbitmq |
| `banks` | `finpaybank.kapowai.com.ua/finpaybank/banks:latest` | — | redis, rabbitmq, elasticsearch |
| `banks-worker` | `finpaybank.kapowai.com.ua/finpaybank/banks-worker:latest` | — | elasticsearch, rabbitmq |
| `ukrcard` | `finpaybank.kapowai.com.ua/finpaybank/ukrcard:latest` | ✓ cert/key/hmac | redis, rabbitmq, ПЦ/АБС |
| `payments` | `finpaybank.kapowai.com.ua/finpaybank/payments:latest` | — | redis, rabbitmq — **2x approval prod** |
| `password-recovery` | `...password-recovery:26.03.4` | — | redis, rabbitmq |
| `customers-update` | `...customers-update:26.01.7` | — | redis, rabbitmq |
| `notifications` | `...notifications:latest` | — | redis, rabbitmq |
| `notifications-worker` | `...notifications-worker:latest` | — | redis, rabbitmq |
| `qr` | `...finpay-qr:latest` | — | redis, rabbitmq |
| `print-reports` | `...finpay-print:latest` | — | redis, rabbitmq |
| `ukrpost` | `hub.kapowai.com.ua/finpaybank/ukrpost-client:26.02.3` | — | External API |
| `onboarding` | `...onboarding:26.03.11` | — | redis, rabbitmq |
| `vkursi` | `hub.kapowai.com.ua/finpaybank/vkursi-client:26.02.4` | — | External API |
| `transactions` | `...transactions:latest` | — | redis, rabbitmq |
| `transactions-worker` | `...transactions-worker:latest` | — | redis, rabbitmq |
| `image2text` | `hub.kapowai.com.ua/finpaybank/image2text-service:1.0.0` | — | redis, rabbitmq |
| `check-for-update` | `hub.kapowai.com.ua/finpaybank/check-for-update:latest` | — | redis, rabbitmq |
| `maintenance` | `hub.kapowai.com.ua/finpaybank/maintenance:21.2.1` | — | redis, rabbitmq |
| `kyc-liveness-service` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-service:25.08.01` | — | minio, postgres, redis, rabbitmq |
| `kyc-liveness-worker` | `hub.kapowai.com.ua/finpaybank/kyc-liveness-service:25.09.01` | — | minio, redis, rabbitmq |

---

## 10. Структура репозиторію (довідка)

```
finpaybank-gitops/
├── AGENT.md                          ← цей файл
├── README.md                         ← deployment guide
├── scripts/
│   ├── bootstrap/                    ← 6 bootstrap скриптів
│   └── maintenance/                  ← rotate-registry, add-new-service
├── k8s-ops/
│   ├── argocd/
│   │   ├── projects/                 ← 5 AppProject (dev/test/stage/prod-dmz/prod-cde)
│   │   └── applicationsets/          ← 5 ApplicationSet + prometheus-agent
│   ├── kargo/
│   │   ├── _template/               ← шаблон pipeline (project+warehouse+stages)
│   │   ├── CREDENTIALS.md           ← інструкція по credentials
│   │   ├── rbac.yaml                ← ClusterRoles для approvers
│   │   └── {service}/               ← 36 Kargo pipelines
│   └── apps/
│       ├── dmz/                      ← 6 DMZ сервісів
│       │   └── _template/
│       └── cde/                      ← 29 CDE сервісів (4 StatefulSet + 25 ESB)
│           └── _template/
└── infrastructure/
    ├── cert-manager/                 ← Let's Encrypt + Internal CA
    ├── secrets/                      ← Sealed Secrets або SOPS
    └── monitoring/                   ← Prometheus + Loki + Grafana + alerts
```

---

*Останнє оновлення: при ініціалізації репозиторію*
*Оновлювати цей файл при зміні архітектури або процедур*
