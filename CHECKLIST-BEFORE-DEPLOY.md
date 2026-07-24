# Checklist перед першим деплоєм

> Виконати перед запуском `kubectl apply` на будь-якому кластері.

---

## 1. Замінити IP адреси (обов'язково)

```bash
# Знайти всі placeholder IP в репозиторії:
grep -r "REPLACE\|DEV_NODE_IP\|TEST_NODE_IP\|STAGE_NODE_VIP\|PROD_DMZ_VIP\|PROD_CDE_VIP\|POSTGRES_PRIMARY_IP\|OBSERVABILITY_NODE_IP" \
  --include="*.yaml" --include="*.sh" -l
```

| Placeholder | Де замінити |
|-------------|------------|
| `DEV_NODE_IP` | `scripts/bootstrap/05-add-clusters-argocd.sh`, `k8s-ops/argocd/projects/dev-project.yaml`, `k8s-ops/argocd/applicationsets/dev-appset.yaml` |
| `TEST_NODE_IP` | аналогічно для test |
| `STAGE_NODE_VIP` | аналогічно для stage |
| `PROD_DMZ_VIP` | аналогічно для prod-dmz |
| `PROD_CDE_VIP` | аналогічно для prod-cde |
| `REPLACE_DEV_POSTGRES_IP` | `k8s-ops/apps/cde/shared-network/overlays/dev/kustomization.yaml` |
| `REPLACE_STAGE_POSTGRES_IP` | `k8s-ops/apps/cde/shared-network/overlays/stage/kustomization.yaml` |
| `REPLACE_PROD_POSTGRES_IP` | `k8s-ops/apps/cde/shared-network/overlays/prod/kustomization.yaml` |
| `OBSERVABILITY_NODE_IP` | `infrastructure/monitoring/prometheus-release.yaml`, `prometheus-agent.yaml` |
| `REPLACE_PUBLIC_DOMAIN` | `k8s-ops/apps/dmz/nginx/base/ingress.yaml` |
| `REPLACE_YOUR_DOMAIN` | `infrastructure/cert-manager/cluster-issuer.yaml` |
| `REPLACE_ONLINE_HOST` | всі `k8s-ops/apps/cde/*/base/ingress.yaml` — hostname API (напр. `online-stage.finpay.com.ua` для stage, `online.finpay.com.ua` для prod) |
| `REPLACE_PROD_CDE_NODE_IP` | `k8s-ops/apps/dmz/cde-proxy/overlays/prod/service-patch.yaml`, `k8s-ops/apps/dmz/shared-network/overlays/prod/kustomization.yaml` |
| `REPLACE_PROD_API_HOST` | `k8s-ops/apps/dmz/cde-proxy/overlays/prod/ingress.yaml` |
| `ARGOCD_EXTERNAL_URL` | `k8s-ops/argocd/argocd-cm-patch.yaml` |

---

## 2. Secrets (НЕ комітити в Git)

Створити вручну на кожному кластері:

- [ ] `registry-credentials` — скрипт `04-add-registry-secrets.sh`
- [ ] `rabbitmq-admin-credentials` — для кожного namespace де є RabbitMQ
- [ ] `redis` password — через SECRET_MANAGER (додати `requirepass` в redis.conf secret)
- [ ] `elasticsearch-credentials` — для xpack.security
- [ ] `minio-credentials` — access/secret key
- [ ] `push-gateway-google-credentials` — Firebase service account JSON
- [ ] `cards-pci-certs` — cert.pem, key.pem, hmac.txt, ca.pem, public.pem
- [ ] `ukrcard-pci-certs` — аналогічно
- [ ] `bitbucket-git` (в кожному project namespace) — Bitbucket HTTPS token для Kargo git push
  ```bash
  export BITBUCKET_REPO_TOKEN="<токен>"
  bash scripts/maintenance/update-kargo-git-credentials.sh
  ```
  Токен: Bitbucket → `finpaybank-gitops` → **Repository settings → Security → Access tokens**
  Permissions: **Repository write**. Username для HTTPS: `x-token-auth`.
- [ ] `argocd-credentials` (kargo namespace) — ArgoCD API token

---

## 3. Kargo stages.yaml — замінити ZONE

Kargo `stages.yaml` в `_template` має плейсхолдер `ZONE`. При копіюванні через `add-new-service.sh` він замінюється автоматично. Перевірити що в усіх скопійованих pipelines ZONE замінено:

```bash
grep -r "path: ZONE" k8s-ops/kargo/ | grep -v _template
```

---

## 4. ArgoCD SSH key для Bitbucket

```bash
# Згенерувати SSH ключ для ArgoCD → Bitbucket:
ssh-keygen -t ed25519 -C "argocd@finpaybank" -f ~/.ssh/argocd_bitbucket_ed25519 -N ""

# Додати публічний ключ в Bitbucket:
# Repository settings → Access keys → Add key (Read access)
cat ~/.ssh/argocd_bitbucket_ed25519.pub

# Додати приватний ключ в ArgoCD:
kubectl create secret generic argocd-repo-creds-bitbucket \
  --from-literal=type=git \
  --from-literal=url=git@bitbucket.org:Kapowai \
  --from-file=sshPrivateKey=~/.ssh/argocd_bitbucket_ed25519 \
  -n argocd
kubectl label secret argocd-repo-creds-bitbucket \
  argocd.argoproj.io/secret-type=repo-creds -n argocd
```

---

## 5. RabbitMQ per-service users

Після першого запуску RabbitMQ — створити окремого user для кожного сервісу:

```bash
# Port-forward до RabbitMQ management:
kubectl port-forward svc/rabbitmq-management 15672:15672 -n dev-cde

# Через API або rabbitmqctl:
kubectl exec -it rabbitmq-0 -n dev-cde -- rabbitmqctl add_user push-gateway STRONG_PASS
kubectl exec -it rabbitmq-0 -n dev-cde -- rabbitmqctl set_permissions push-gateway / "" "" "push-notifications"

# Аналогічно для: sms, notifications, cards, payments, ...
```

---

## 6. TLS сертифікати для Ingress

Ingress для кожного сервісу використовує TLS secret `{service}-tls` в відповідному namespace.

### Додати власний сертифікат

```bash
# 1. Зашифрувати cert+key через SOPS і зберегти в overlay
kubectl create secret tls identity-tls \
  --cert=path/to/fullchain.pem \
  --key=path/to/privkey.pem \
  --namespace=test-cde \
  --dry-run=client -o yaml | \
  sops --encrypt --input-type=yaml --output-type=yaml /dev/stdin \
  > k8s-ops/apps/cde/identity/overlays/test/secret-tls.yaml

# 2. Додати secret-tls.yaml в resources overlay kustomization.yaml:
#    resources:
#      - ../../base
#      - secret-tls.yaml
```

### Формат сертифіката

- `fullchain.pem` — сертифікат + intermediate CA (PEM)
- `privkey.pem` — приватний ключ (PEM)
- Wildcard `*.finpay.com.ua` покриє всі env субдомени

### Доменна таблиця

| Env  | Domain                        | Namespace  | Secret name  |
|------|-------------------------------|------------|--------------|
| test | online-test.finpay.com.ua     | test-cde   | identity-tls |
| stage| online-stage.finpay.com.ua    | stage-cde  | identity-tls |
| prod | online.finpay.com.ua          | prod       | identity-tls |

### Ротація сертифіката

```bash
# Оновити SOPS-зашифрований файл:
sops k8s-ops/apps/cde/identity/overlays/test/secret-tls.yaml
# Або перегенерувати через kubectl + sops (як вище)
# Після коміту ArgoCD застосує автоматично
```

---

## 7. Ротація Bitbucket токена для Kargo

Коли токен протерміновується або потребує заміни:

```bash
# 1. Створити новий токен:
#    Bitbucket → finpaybank-gitops → Repository settings → Security → Access tokens
#    Permissions: Repository write

# 2. Оновити secrets у всіх project namespaces:
export BITBUCKET_REPO_TOKEN="<новий токен>"
bash scripts/maintenance/update-kargo-git-credentials.sh
```

Скрипт оновить `bitbucket-git` secret в усіх 32 Kargo project namespace-ах
і застосує поточні `stages.yaml`. Старий токен після цього можна деактивувати.

---

## 7. shared-network — налаштування мережевих правил

`shared-network` — окремий ArgoCD app що деплоїться в кожен namespace (dev-cde, test-cde, тощо)
і задає базові NetworkPolicy правила для всіх pods у зоні.

### CDE egress (один раз на env)

Файл: `k8s-ops/apps/cde/shared-network/overlays/{env}/kustomization.yaml`

```yaml
patches:
  - target:
      kind: NetworkPolicy
      name: cde-common-egress
    patch: |-
      - op: replace
        path: /spec/egress/1/to/0/ipBlock/cidr
        value: <POSTGRES_IP>/32
```

Дозволяє для всіх CDE pods: DNS + PostgreSQL + Redis + RabbitMQ + CDE internal HTTP.

### PostgreSQL replica (коли з'явиться)

Розкоментувати блок у `base/networkpolicy-cde-egress.yaml` і додати patch в кожен overlay:
```yaml
      - op: replace
        path: /spec/egress/2/to/0/ipBlock/cidr
        value: <POSTGRES_REPLICA_IP>/32
```

### DMZ egress

Файл: `k8s-ops/apps/dmz/shared-network/base/networkpolicy-dmz-egress.yaml`

Дозволяє: DNS + CDE RabbitMQ. Зовнішні сервіси (SMS, push) — розкоментувати відповідні блоки.

### ApplicationSet

`shared-network` підхоплюється автоматично appset-ами — окремо реєструвати не потрібно.
Після git push ArgoCD створить apps `shared-network-cde-{env}` та `shared-network-dmz-{env}`.

---

## 8. Reloader — встановлення (один раз на кластер)

Stakater Reloader автоматично рестартує поди при зміні Secret або ConfigMap.
Всі CDE/DMZ Deployment вже мають анотацію `reloader.stakater.com/auto: "true"`.

```bash
# 1. Зареєструвати Helm repo в ArgoCD (один раз)
argocd repo add https://stakater.github.io/stakater-charts --type helm --name stakater

# 2. Застосувати ApplicationSet (деплоїть Reloader на всі кластери)
kubectl apply -k infrastructure/reloader/

# 3. Дочекатись появи pod-ів (перевіряти на кожному цільовому кластері)
KUBECONFIG=~/.kube/finpaybank-{env} kubectl -n reloader rollout status deployment --timeout=120s

# 4. Перевірити логи
KUBECONFIG=~/.kube/finpaybank-{env} kubectl -n reloader logs deployment/reloader-{env}-reloader -f
```

> Після встановлення: будь-яка зміна `shared-secrets` або `*-config` → автоматичний rolling restart всіх сервісів, що їх використовують. Ручний `kubectl rollout restart` більше не потрібен.

---

## 9. Доменні імена Ingress — cluster-domains component

Хост для всіх Ingress з лейблом `ingress-type: external` встановлюється автоматично через
Kustomize Component `k8s-ops/components/cluster-domains/{env}/kustomization.yaml`.

**Компонент інжектується ArgoCD ApplicationSet**, а не прописується в кожному сервісі.
При додаванні нового сервісу з Ingress **нічого не треба додавати в overlay** — AppSet додає компонент автоматично.

| Env  | Компонент | Хост |
|------|-----------|------|
| dev  | `cluster-domains/dev`   | `online-dev.finpay.com.ua` |
| test | `cluster-domains/test`  | `online-test.finpay.com.ua` |
| stage| `cluster-domains/stage` | `online-stage.finpay.com.ua` |
| prod | `cluster-domains/prod`  | `online.finpay.com.ua` |

**Вимога до нового сервісу з Ingress:**
- В `base/ingress.yaml` поставити `REPLACE_{SERVICE}_HOST` як placeholder для `spec.rules[0].host`
- Додати лейбл `ingress-type: external` на Ingress ресурс

**Зміна домену:** редагувати `value:` у відповідному `cluster-domains/{env}/kustomization.yaml` → commit → ArgoCD підхопить.

**Локальний kustomize build** покаже `REPLACE_{SERVICE}_HOST` — це нормально.
Хост замінюється тільки під час ArgoCD build:
```bash
# Для локальної перевірки з компонентом:
kubectl kustomize --enable-alpha-plugins \
  k8s-ops/apps/cde/SERVICE_NAME/overlays/test
# АБО перевіряти через ArgoCD UI → App Details → Diff
```

---

## 10. ArgoCD ApplicationSets — ручне застосування

ApplicationSet-и **не** синхронізуються через ArgoCD (bootstrap рівень).
При змінах в `k8s-ops/argocd/applicationsets/` застосовувати вручну:

```bash
kubectl apply -f k8s-ops/argocd/applicationsets/
```

---

## 10. Перевірка після деплою

```bash
# Всі поди запущені:
kubectl get pods -n dev-dmz
kubectl get pods -n dev-cde

# NetworkPolicy працює (тест з'єднань):
# DMZ → CDE RabbitMQ має працювати:
kubectl run tmp -it --rm --image=busybox -n dev-dmz -- nc -zv rabbitmq.dev-cde.svc.cluster.local 5672

# CDE → internet має НЕ працювати:
kubectl run tmp -it --rm --image=busybox -n dev-cde -- nc -zv 8.8.8.8 443
# Очікується: timeout або connection refused

# ArgoCD sync статус:
argocd app list
```
