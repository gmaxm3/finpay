# TODO

## Термінові

- [ ] **Persistent storage для RabbitMQ та Redis (всі середовища)**
  - Зараз RabbitMQ і Redis використовують `emptyDir` — дані втрачаються при рестарті поду
  - Потрібно: підняти Storage Class (local-path або Longhorn), додати PVC в base, налаштувати розміри per-env
  - Залежність: вирішити проблему з `.erlang.cookie` permissions для RabbitMQ (fsGroup + PVC → файл отримує group bits, Erlang відмовляється стартувати)
  - Варіанти фіксу cookie: додати `RABBITMQ_ERLANG_COOKIE` env var з Secret → docker-entrypoint створює cookie з chmod 600

## Infrastructure

- [ ] **Harbor як Docker Registry (PCI-DSS)**
  - Дослідити Harbor як приватний registry відповідно до вимог PCI-DSS
  - Ключові аспекти для перевірки:
    - RBAC та ізоляція проєктів (окремо для DMZ / CDE)
    - Vulnerability scanning (Trivy вбудований у Harbor)
    - Immutable tags — заборона перезапису образів у prod
    - Content trust / image signing (Notation або Cosign)
    - Audit log доступу до образів
    - Replication та HA для prod
    - mTLS між кластерами та Harbor
    - Integration з Sealed Secrets / SOPS для `registry-credentials`
    - Відповідність PCI-DSS вимогам 6.3 (захист від вразливостей), 8.2 (контроль доступу), 10.2 (audit trail)
  - Налаштувати Harbor згідно PCI-DSS:
    - Увімкнути автоматичне сканування при push
    - Заборонити деплой образів з HIGH/CRITICAL CVE
    - Налаштувати retention policy (видалення непідписаних/старих образів)
    - Окремий Harbor project для кожного environment або zone (dmz/cde)

## Logging / Filebeat

- [ ] **NetworkPolicy: обмежити DNS egress до CoreDNS** *(низький пріоритет)*
  - Поточне правило дозволяє port 53 до будь-якого хосту
  - Замінити на `namespaceSelector: kube-system` + `podSelector: k8s-app: kube-dns`
  - Файл: `k8s-ops/apps/logging/filebeat/base/networkpolicy.yaml:11-17`

- [ ] **NetworkPolicy: замінити 10.0.0.0/8 на конкретні k8s API IP** *(низький пріоритет)*
  - Поточний блок дозволяє Filebeat звертатись по HTTPS до всієї внутрішньої мережі
  - Замінити на конкретні IP k8s API server per overlay (у k3s зазвичай ClusterIP `kubernetes` сервісу)
  - Файл: `k8s-ops/apps/logging/filebeat/base/networkpolicy.yaml:19-25`

## Security / PCI-DSS

- [ ] **NetworkPolicy: traefik podSelector у всіх CDE сервісах з Ingress не матчиться через `commonLabels`**
  - `commonLabels` (`app.kubernetes.io/part-of: finpaybank`, `zone: cde`) у `base/kustomization.yaml` додається kustomize не тільки до metadata, а й до `matchLabels` усіх селекторів — включно з traefik `podSelector` у NetworkPolicy
  - Рендериться: `podSelector.matchLabels: {app.kubernetes.io/name: traefik, app.kubernetes.io/part-of: finpaybank, zone: cde}` — traefik pod у `kube-system` цих двох додаткових лейблів не має, тож правило ніколи не матчиться і ingress-трафік на сервіс-порт фактично блокується
  - Зачіпає всі CDE сервіси з Ingress: `customer`, `payments`, `cards`, `banks`, `notifications`, `identity`, `qr`, `transactions`, `onboarding`
  - Варіанти фіксу: перейти з `commonLabels` на `labels` з `includeSelectors: false` (Kustomize ≥3.8), або винести traefik-правило в окремий ресурс без commonLabels, або генерувати селектор без зайвих лейблів через patch
  - Перевірити після фіксу: `kubectl kustomize k8s-ops/apps/cde/{service}/overlays/prod | grep -A5 "name: traefik"`

- [ ] **Розділення DB користувачів: app vs migrator (PCI-DSS least privilege)**
  - Для кожного CDE сервісу створити два PostgreSQL користувача:
    - `{service}_app` — тільки DML (`SELECT/INSERT/UPDATE/DELETE`)
    - `{service}_migrator` — DDL + DML (для міграцій)
  - Два секрети в кожному overlay:
    - `{service}-credentials` → `DATABASE_URL` з `{service}_app`
    - `{service}-migration-credentials` → `DATABASE_URL` з `{service}_migrator`
  - Додати init container до кожного deployment:
    ```yaml
    initContainers:
      - name: migrate
        image: same-image
        command: ["alembic", "upgrade", "head"]
        envFrom:
          - secretRef:
              name: {service}-migration-credentials
    ```
  - Основний контейнер залишає `{service}-credentials` (DML-only)
  - PCI-DSS вимога 7 (least privilege) — аплікаційний акаунт не повинен мати DDL-прав

- [ ] **Ротація PCI сертифікатів** (`pci-certs`)
  - Отримати нові сертифікати від ПЦ/АБС
  - Оновити для кожного environment:
    ```bash
    kubectl create secret generic pci-certs \
      --from-file=client.crt=... --from-file=client.key=... --from-file=ca.crt=... \
      --dry-run=client -o yaml \
      > k8s-ops/apps/cde/pci-certs/overlays/{env}/secret-pci-certs.yaml
    sops -e -i k8s-ops/apps/cde/pci-certs/overlays/{env}/secret-pci-certs.yaml
    ```
  - Перевірити термін дії сертифікатів: `openssl x509 -in client.crt -noout -dates`
  - PCI-DSS вимагає ротацію мінімум раз на рік (або при компрометації)
