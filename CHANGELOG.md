# CHANGELOG

Цей файл використовується як робочий журнал змін у репозиторії.

Правила ведення:

- кожен запис містить дату
- кожен запис містить оточення (`test`, `stage`, `prod`, `shared`)
- кожен запис коротко описує, що змінено
- для кожного запису наводяться основні файли

## 2026-04-13

### Environment: test

Оновлено `deploy.TEST.md` під поточну схему розгортання `test`, де `management` тимчасово живе на тому самому хості, що і `test` cluster.

Файли:

- `deploy.TEST.md`

Зміни:

- зафіксовано `TEST_HOST=kapowai.finpaybank.test.esb`
- зафіксовано `TEST_NODE_IP=10.201.34.10`
- зазначено, що `MGMT_HOST` тимчасово дорівнює `kapowai.finpaybank.test.esb`
- зафіксовано `TEST_POSTGRES_PRIMARY_IP=10.201.35.10`
- зафіксовано `TEST_POSTGRES_REPLICA_IP=10.201.35.10` як тимчасове значення, поки окремої репліки немає
- зафіксовано `TEST_PUBLIC_DOMAIN=online-test.finpay.com.ua`
- зафіксовано `ARGOCD_EXTERNAL_URL=argocd.online-test.finpay.com.ua`
- зафіксовано `KARGO_EXTERNAL_URL=kargo.online-test.finpay.com.ua`
- зафіксовано `ACME_EMAIL=vladimir.fesik@kapowai.online`

### Environment: test

Оновлено `ArgoCD` маніфести для `test` cluster.

Файли:

- `k8s-ops/argocd/applicationsets/test-appset.yaml`
- `k8s-ops/argocd/projects/test-project.yaml`
- `k8s-ops/argocd/argocd-cm-patch.yaml`

Зміни:

- `test` destination server змінено на `https://10.201.34.10:6443`
- зовнішній URL `ArgoCD` змінено на `https://argocd.online-test.finpay.com.ua`

### Environment: test

Оновлено `test` DNS для публічного `nginx`.

Файли:

- `k8s-ops/apps/dmz/nginx/overlays/test/kustomization.yaml`

Зміни:

- ingress host змінено на `online-test.finpay.com.ua`
- certificate dnsName змінено на `online-test.finpay.com.ua`

### Environment: test

Оновлено `cert-manager` конфігурацію для `test`.

Файли:

- `infrastructure/cert-manager/argocd-certificate.yaml`
- `infrastructure/cert-manager/cluster-issuer.yaml`

Зміни:

- `ArgoCD` certificate dnsName змінено на `argocd.online-test.finpay.com.ua`
- `Kargo` certificate dnsName змінено на `kargo.online-test.finpay.com.ua`
- ACME email змінено на `vladimir.fesik@kapowai.online`

### Environment: test

Оновлено monitoring-конфігурацію для `test` cluster endpoint.

Файли:

- `infrastructure/monitoring/prometheus-agent.yaml`

Зміни:

- `test` cluster endpoint змінено на `https://10.201.34.10:6443`

### Environment: shared

Виправлено побічну помилку у шаблоні `prod`, що з'явилась після масової підстановки.

Файли:

- `k8s-ops/apps/cde/_template/overlays/prod/kustomization.yaml`

Зміни:

- повернуто placeholder `REPLACE_PROD_POSTGRES_PRIMARY_IP`

## 2026-04-14

### Environment: shared

Оновлено bootstrap встановлення `Kargo` на актуальний спосіб через OCI chart замість застарілого `charts.kargo.io`.

Файли:

- `scripts/bootstrap/03-install-kargo.sh`
- `deploy.TEST.md`
- `README.md`

Зміни:

- дефолтну версію `Kargo` оновлено з `v0.8.0` до `1.8.4`
- джерело Helm chart змінено з `https://charts.kargo.io` на `oci://ghcr.io/akuity/kargo-charts/kargo`
- додано обов'язкову змінну `KARGO_TOKEN_SIGNING_KEY`
- додано перевірку наявності `KARGO_ADMIN_PASSWORD_HASH`
- оновлено інструкції з генерації параметрів для встановлення `Kargo`

### Environment: test

Виправлено команди віддаленого запуску для `ArgoCD` і `Kargo` на `k3s` management host.

Файли:

- `deploy.TEST.md`
- `README.md`

Зміни:

- команди віддаленого запуску змінено на `sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash -s`
- команду отримання початкового пароля `ArgoCD` змінено на `sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml`
- усунуто проблему `Kubernetes cluster unreachable: http://localhost:8080`

### Environment: test

Виправлено передачу env-змінних при віддаленому запуску `Kargo` install через `sudo`.

Файли:

- `deploy.TEST.md`

Зміни:

- команду запуску `scripts/bootstrap/03-install-kargo.sh` змінено на `sudo env ... bash -s`
- усунуто втрату `KARGO_ADMIN_PASSWORD_HASH` і `KARGO_TOKEN_SIGNING_KEY` через очищення env у `sudo`

### Environment: test

Уточнено спосіб запуску віддаленої команди встановлення `Kargo`, щоб уникнути розриву `ssh` команди переносом рядка всередині `env`.

Файли:

- `deploy.TEST.md`

Зміни:

- додано примітку, що `ssh ... "sudo env ... bash -s"` має виконуватись одним викликом
- додано однорядковий приклад команди для уникнення випадкового виконання `env` без `bash -s`

### Environment: shared

Додано явну вимогу `cert-manager` перед встановленням `Kargo`.

Файли:

- `scripts/bootstrap/03-install-kargo.sh`
- `deploy.TEST.md`
- `README.md`

Зміни:

- у bootstrap `Kargo` додано precheck на CRD-и `cert-manager`
- у runbook для `test` додано окремий крок встановлення `cert-manager` у management cluster перед `Kargo`
- у `README.md` оновлено порядок встановлення для management cluster

### Environment: test

Уточнено спосіб встановлення `cert-manager` у management cluster, коли репозиторій відсутній на віддаленому хості.

Файли:

- `deploy.TEST.md`

Зміни:

- додано варіант `kubectl kustomize ... | ssh ... kubectl apply -f -`
- додано окрему перевірку CRD-ів `cert-manager` через віддалений `k3s` kubeconfig
- зафіксовано, що локальний `~/.kube/finpaybank-management` можна використовувати лише якщо він точно відповідає management cluster

### Environment: test

Додано перевірку готовності webhook `cert-manager` перед встановленням `Kargo`.

Файли:

- `deploy.TEST.md`

Зміни:

- додано перевірку `validatingwebhookconfiguration cert-manager-webhook`
- додано recovery-крок через `rollout restart` для `cert-manager-webhook` і `cert-manager-cainjector`
- зафіксовано, що `Kargo` слід ставити лише після появи коректного `caBundle`

### Environment: test

Розширено troubleshooting для випадку, коли `cert-manager-webhook` не має `caBundle`.

Файли:

- `deploy.TEST.md`

Зміни:

- додано перевірку secret `cert-manager-webhook-ca`
- додано команди для збору логів `cert-manager-cainjector` і `cert-manager-webhook`
- додано recovery-послідовність через перевстановлення `cert-manager` у віддаленому кластері

### Environment: test

Додано workaround для ручної ін'єкції `caBundle` в `cert-manager-webhook`, якщо secret уже існує, але `cainjector` не оновив webhook configuration.

Файли:

- `deploy.TEST.md`

Зміни:

- додано команду читання `ca.crt` з secret `cert-manager-webhook-ca`
- додано `kubectl patch` для `validatingwebhookconfiguration cert-manager-webhook`
- позначено цей сценарій як тимчасовий workaround

### Environment: shared

Runbook розділено на окремі сценарії для `test` середовища і для `management` cluster.

Файли:

- `deploy.TEST.md`
- `deploy.MGMT.md`

Зміни:

- `deploy.TEST.md` спрощено до сценарію розгортання `test` без `ArgoCD` і без `Kargo`
- кроки для `management`, `ArgoCD`, `Kargo` і `ApplicationSet` винесено в новий `deploy.MGMT.md`
- у `deploy.TEST.md` інтеграцію з `ArgoCD` залишено як optional фінальний крок через посилання на окремий файл

### Environment: shared

Додано централізовані env-файли для запуску сценаріїв `test` і `management`.

Файли:

- `environments/test.env`
- `environments/mgmt.env.example`
- `deploy.TEST.md`
- `deploy.MGMT.md`

Зміни:

- створено єдиний env-файл для `test` з IP, DNS і базовими параметрами середовища
- додано шаблон env-файлу для майбутнього `management` cluster
- оновлено runbook-и, щоб вони починалися з `source` env-файлу
- зафіксовано підхід "один файл конфігурації на одне оточення"

### Environment: test

Уточнено перевірку `Sealed Secrets` після встановлення.

Файли:

- `deploy.TEST.md`

Зміни:

- додано перевірку `deploy/pod/svc/endpoints` для `sealed-secrets-controller`
- зафіксовано, що `kubeseal --fetch-cert` можливий лише після появи ready endpoints
- додано troubleshooting для `ImagePullBackOff` у `sealed-secrets-controller`

### Environment: shared

Оновлено image для `Sealed Secrets` controller, оскільки старий тег більше не існує в registry.

Файли:

- `infrastructure/secrets/sealed-secrets-controller.yaml`

Зміни:

- image змінено з `docker.io/bitnami/sealed-secrets-controller:v0.26.2` на `ghcr.io/bitnami-labs/sealed-secrets-controller:v0.33.0`

### Environment: shared

Впроваджено secret management через **SOPS + age**. Sealed Secrets виведено з використання.

Файли:

- `.sops.yaml` — новий файл, конфігурація SOPS (публічні ключі, правила per-environment)
- `infrastructure/secrets/bootstrap-secrets.sh` — новий скрипт генерації ключів і шифрування секретів
- `infrastructure/secrets/sops-argocd-plugin.yaml` — переписано: sidecar CMP замість download-at-runtime
- `infrastructure/secrets/kustomization.yaml` — перемкнуто на SOPS plugin
- `infrastructure/secrets/README.md` — повністю переписано під SOPS + age
- `k8s-ops/apps/cde/rabbitmq/overlays/*/secret-rabbitmq.yaml` — нові зашифровані секрети (4 env)
- `k8s-ops/apps/cde/redis/overlays/*/secret-redis.yaml` — нові зашифровані секрети (4 env)
- `k8s-ops/apps/cde/elasticsearch/overlays/*/secret-elasticsearch.yaml` — нові зашифровані секрети (4 env)
- `k8s-ops/apps/cde/rabbitmq|redis|elasticsearch/overlays/*/kustomization.yaml` — додано посилання на secret файли
- `deploy.MGMT.md` — додано крок 4а: завантаження ArgoCD age key в кластер
- `deploy.TEST.md` — замінено кроки 7 і 9: Sealed Secrets → SOPS decrypt інструкції
- `README.md` — оновлено Prerequisites і крок 6.2 Bootstrap
- `.gitignore` — додано паттерни для age ключів

Зміни:

- обрано SOPS + age як єдиний механізм secret management (замість Sealed Secrets)
- згенеровано operator age key (`~/.config/sops/age/keys.txt`) та ArgoCD age key
- зашифровано перші 12 секретів (RabbitMQ, Redis, Elasticsearch × 4 env) через `bootstrap-secrets.sh`
- ArgoCD розшифровує секрети через sidecar CMP (`kustomize-sops`) без жодного контролера в кластері
- при ручному `kubectl apply` (без ArgoCD): `sops -d secret.yaml | kubectl apply -f -`
- backup ArgoCD ключа: `kubectl get secret sops-age-key -n argocd -o jsonpath='{.data.key\.txt}' | base64 -d`

### Environment: shared

Додано centralized shared secrets і service-specific secrets для `cards`.

Файли:

- `k8s-ops/apps/cde/shared-secrets/` — новий ArgoCD App (base + overlays × 4 env)
- `k8s-ops/apps/cde/shared-secrets/overlays/*/secret-shared.yaml` — зашифровані SOPS (4 env)
- `k8s-ops/apps/cde/cards/overlays/*/secret-cards.yaml` — зашифровані SOPS, тільки `DATABASE_URL` override (4 env)
- `k8s-ops/apps/cde/cards/base/deployment.yaml` — додано `envFrom: shared-secrets`, `env: DATABASE_URL override`
- `k8s-ops/apps/cde/_template/base/deployment.yaml` — додано `envFrom: shared-secrets` у шаблон
- `infrastructure/secrets/README.md` — додано секцію shared-secrets, оновлено таблицю секретів
- `deploy.TEST.md` — додано `shared-secrets` apply у кроки 9 і 10
- `CLAUDE.md` — оновлено Secret management секцію

Зміни:

- введено патерн `shared-secrets`: один Secret у кожному CDE namespace з `DEFAULT_URL`, `REDIS_URL`, `RABBITMQ_URL`, `SECRET_KEY`, `DATABASE_URL`
- `shared-secrets` підхоплюється ApplicationSet автоматично як окремий ArgoCD App
- всі CDE deployment-и отримують спільні змінні через `envFrom: secretRef: name: shared-secrets`
- для переозначення `DATABASE_URL` у конкретному сервісі: `env: valueFrom: secretKeyRef` (перемагає `envFrom`)
- `cards` використовує `DATABASE_URL` з `cards-credentials` (окрема схема БД)

### Environment: shared

Винесено PCI сертифікати в централізований `pci-certs` ArgoCD App.

Файли:

- `k8s-ops/apps/cde/pci-certs/` — новий ArgoCD App (base + overlays × 4 env)
- `k8s-ops/apps/cde/pci-certs/overlays/*/secret-pci-certs.yaml` — зашифровані SOPS placeholders (4 env)
- `k8s-ops/apps/cde/cards/base/deployment.yaml` — `secretName: cards-pci-certs` → `pci-certs`
- `k8s-ops/apps/cde/ukrcard/base/deployment.yaml` — `secretName: ukrcard-pci-certs` → `pci-certs`, додано `shared-secrets`
- `infrastructure/secrets/README.md` — додано секцію PCI certs

Зміни:

- `cards` і `ukrcard` тепер монтують один спільний Secret `pci-certs` з `/app/certs`
- сертифікати зберігаються в одному місці per environment — змінювати тільки в `pci-certs/overlays/{env}/`
- для заповнення реальними сертами: `kubectl create secret --dry-run | sops -e -i`
