# Оновлення TLS сертифікату *.finpay.com.ua

Wildcard сертифікат `*.finpay.com.ua` від GoDaddy розгорнутий на 4 кластерах
як Kubernetes Secret `finpay-wildcard-tls` у namespace `kube-system`.

Використовується:
- **DMZ кластери** (stage-dmz, prod-dmz) — TLS термінація вхідного трафіку (Traefik TLSStore)
- **CDE кластери** (stage-cde, prod-cde) — TLS на порту 30443 для DMZ→CDE routing

---

## Де зберігається в Git

```
infrastructure/traefik/overlays/
  dev/    secret-wildcard-tls.yaml   (SOPS encrypted)
  test/   secret-wildcard-tls.yaml   (SOPS encrypted)
  stage/  secret-wildcard-tls.yaml   (SOPS encrypted)
  prod/   secret-wildcard-tls.yaml   (SOPS encrypted)
```

---

## Крок 1. Отримати новий сертифікат

У GoDaddy перевипустити/поновити `*.finpay.com.ua`. Завантажити:
- `wildcard.crt` — повний ланцюжок (fullchain)
- `wildcard.key` — приватний ключ

---

## Крок 2. Зашифрувати і зберегти в Git

Достатньо одного файлу на env — і DMZ, і CDE беруть один і той самий cert.

```bash
# Stage
kubectl create secret tls finpay-wildcard-tls \
  --cert=wildcard.crt \
  --key=wildcard.key \
  --namespace kube-system \
  --dry-run=client -o yaml \
  > infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml

sops -e -i infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml

# Prod
kubectl create secret tls finpay-wildcard-tls \
  --cert=wildcard.crt \
  --key=wildcard.key \
  --namespace kube-system \
  --dry-run=client -o yaml \
  > infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml

sops -e -i infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml
```

Закомітити:

```bash
git add infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml \
        infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml
git commit -m "chore(tls): rotate wildcard cert *.finpay.com.ua"
git push
```

---

## Крок 3. Застосувати на кластерах

### Stage

```bash
# DMZ
KUBECONFIG=~/.kube/finpaybank-stage-dmz \
  sops -d infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# CDE
KUBECONFIG=~/.kube/finpaybank-stage-cde \
  sops -d infrastructure/traefik/overlays/stage/secret-wildcard-tls.yaml \
  | kubectl apply -f -
```

### Prod

```bash
# DMZ
KUBECONFIG=~/.kube/finpaybank-prod-dmz \
  sops -d infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml \
  | kubectl apply -f -

# CDE
KUBECONFIG=~/.kube/finpaybank-prod-cde \
  sops -d infrastructure/traefik/overlays/prod/secret-wildcard-tls.yaml \
  | kubectl apply -f -
```

Traefik підхоплює оновлений Secret автоматично (Reloader не потрібен — Traefik сам watches Secrets).

---

## Крок 4. Перевірка

```bash
# Переконатись що новий cert активний — перевірити expiry
echo | openssl s_client -connect online.finpay.com.ua:443 -servername online.finpay.com.ua 2>/dev/null \
  | openssl x509 -noout -dates

echo | openssl s_client -connect online-stage.finpay.com.ua:443 -servername online-stage.finpay.com.ua 2>/dev/null \
  | openssl x509 -noout -dates
```

---

## Коли оновлювати

GoDaddy надсилає email за 30 та 7 днів до закінчення. Перевірити вручну:

```bash
echo | openssl s_client -connect online.finpay.com.ua:443 2>/dev/null \
  | openssl x509 -noout -enddate
```
