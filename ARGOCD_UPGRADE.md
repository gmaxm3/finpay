# ArgoCD Upgrade

Підтримувані версії: тільки 3 останніх minor (перевірити: https://endoflife.date/argo-cd)

## Швидкий upgrade (скрипт)

```bash
sudo bash scripts/maintenance/upgrade-argocd.sh
# або конкретна версія:
sudo ARGOCD_VERSION=v3.5.0 bash scripts/maintenance/upgrade-argocd.sh
```

Скрипт робить все автоматично: apply manifest → rollout status → відновлює argocd-cm та RBAC.

## Ручний upgrade

### 1. Apply manifest

Використовувати `--server-side` щоб уникнути помилки "Too long" на великому ApplicationSet CRD:

```bash
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/install.yaml
```

### 2. Чекати rollout

```bash
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
```

### 3. Відновити argocd-cm

`install.yaml` перезаписує argocd-cm дефолтним — треба застосувати наш патч:

```bash
kubectl apply -n argocd -f k8s-ops/argocd/argocd-cm-patch.yaml
```

### 4. Відновити RBAC

`install.yaml` також перезаписує argocd-rbac-cm — застосувати з репо:

```bash
kubectl apply -n argocd -f k8s-ops/argocd/ 
```

Або взяти актуальний RBAC зі скрипту `scripts/bootstrap/02-install-argocd.sh`.

### 5. Перевірка

```bash
kubectl -n argocd get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 6. Якщо apps показують OutOfSync

Після upgrade tracking method змінюється (label → annotation) — одноразовий sync вирішує:

```bash
argocd app list -o name | xargs -I{} argocd app sync {} --async
```

## Нотатки по міграції v2 → v3

При переході з v2 на v3 (зроблено 2026-05-21, v2.10.4 → v3.4.2):

- **`repositories:` в argocd-cm** — більше не підтримується. Репозиторії тільки через Secrets (`argocd.argoproj.io/secret-type=repo-creds`). Видалено з `argocd-cm-patch.yaml`.
- **`logs, get` RBAC** — в v3 обов'язково явно дозволяти. Додано для всіх ролей.
- **Resource tracking** — дефолт змінився з `label` на `annotation`. Apps потребують одноразового sync після upgrade.
- **`server.rbac.log.enforce.enable`** — флаг видалено, enforcement тепер завжди увімкнений.
