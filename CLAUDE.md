# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture overview

GitOps repository for FinPayBank internet banking, PCI-DSS compliant. The full architectural context for agents is in [AGENT.md](AGENT.md).

**Cluster topology:**
- `management-node` — ArgoCD Hub + Kargo (controls all clusters)
- `dev-node`, `test-node`, `stage-node-1,2` — non-prod k3s clusters
- `prod-dmz` (2 nodes) — internet-facing
- `prod-cde` (3 nodes) — PCI-DSS scope, no internet
- `observability-node` — Prometheus + Loki + Grafana

**Security zones:**
- **DMZ** (`zone: dmz`) — internet-facing: frontend, nginx, push-gateway, sms
- **CDE** (`zone: cde`) — no internet: ESB services (cards, payments, etc.), Redis, RabbitMQ, PostgreSQL access

DMZ services communicate with CDE exclusively via RabbitMQ port 5672.

## Repository structure

```
k8s-ops/
  apps/dmz/_template/    # Template for new DMZ services (Kustomize)
  apps/cde/_template/    # Template for new CDE services (Kustomize)
  apps/logging/filebeat/ # Filebeat DaemonSet (збір логів → ELK)
  argocd/projects/       # 6 AppProjects (dev/test/stage/prod-dmz/prod-cde/logging)
  argocd/applicationsets/ # 6 ApplicationSets + prometheus-agent
  kargo/_template/       # Kargo pipeline template (project+warehouse+stages)
  kargo/{service}/       # Per-service Kargo pipelines (36 total)
infrastructure/
  cert-manager/          # Let's Encrypt + Internal CA
  secrets/               # Sealed Secrets or SOPS
  monitoring/            # Prometheus + Loki + Grafana + alerts
  reloader/              # Stakater Reloader — auto-restart on Secret/ConfigMap change
scripts/
  bootstrap/             # 6 bootstrap scripts (01–06)
  maintenance/           # rotate-registry-secrets.sh, add-new-service.sh
```

## Adding a new service

Use the automated script or follow manually:
```bash
scripts/maintenance/add-new-service.sh SERVICE_NAME dmz|cde
```

Manual steps:
1. Copy the appropriate `_template` to `k8s-ops/apps/{dmz|cde}/SERVICE_NAME/`
2. Replace placeholders: `SERVICE_NAME`, `SERVICE_PORT`, `CONTAINER_IMAGE`
3. Configure overlays per environment (dev: 1 replica, prod: 2+)
4. Create Kargo pipeline from `k8s-ops/kargo/_template/`
5. Update service tables in README.md and AGENT.md

**Zone selection rule:** If service touches PostgreSQL, PCI data, payment centers (ПЦ/АБС), Redis, or RabbitMQ → CDE. If internet-facing or sends push/SMS → DMZ. When in doubt → CDE.

## Validate manifests

```bash
# Validate kustomize builds before committing
kubectl kustomize k8s-ops/apps/dmz/SERVICE_NAME/overlays/dev
kubectl kustomize k8s-ops/apps/cde/SERVICE_NAME/overlays/dev

# Find remaining placeholder IPs or tokens
grep -r "REPLACE\|DEV_NODE_IP\|TEST_NODE_IP\|STAGE_NODE_VIP\|PROD_DMZ_VIP\|PROD_CDE_VIP\|POSTGRES_PRIMARY_IP" \
  --include="*.yaml" --include="*.sh" -l
```

## Promotion workflow (Kargo)

```
CI push → dev (auto) → test (auto) → stage (manual approval) → prod (manual, 2x for payments)
```

```bash
kargo get freights --project SERVICE_NAME
kargo promote --project SERVICE_NAME --freight FREIGHT_ID --stage stage
kargo get promotions --project SERVICE_NAME
```

## PCI-DSS mandatory requirements

Every Deployment must have (see AGENT.md §4 for full YAML snippets):
- Pod `securityContext`: `runAsNonRoot: true`, `runAsUser: 1000`, `seccompProfile: RuntimeDefault`
- Container `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`
- Dedicated `ServiceAccount` with `automountServiceAccountToken: false`
- `NetworkPolicy` with default-deny + explicit allow-list (CDE must have no internet egress)
- `livenessProbe`, `readinessProbe`, `startupProbe`
- `resources.requests` and `resources.limits`
- `imagePullSecrets: [{name: registry-credentials}]`
- Prod overlays: digest-based image refs, never `:latest`

## Secret management

**SOPS + age** (finalized). See `infrastructure/secrets/README.md` for full details.

**Shared secrets** (`k8s-ops/apps/cde/shared-secrets/`) — одна точка для спільних ENV змінних усіх CDE сервісів: `DEFAULT_URL`, `REDIS_URL`, `RABBITMQ_URL`, `SECRET_KEY`, `DATABASE_URL`. Деплоїться як окремий ArgoCD App у кожен `{env}-cde` namespace.

**Shared network** (`k8s-ops/apps/cde/shared-network/`, `k8s-ops/apps/dmz/shared-network/`) — базові NetworkPolicy egress правила для всієї зони. Postgres IP задається в `overlays/{env}/kustomization.yaml` (одне місце на env). CDE: DNS + PostgreSQL + Redis + RabbitMQ + internal. DMZ: DNS + CDE RabbitMQ + зовнішні сервіси (заготовка).

Every CDE deployment must include:
```yaml
envFrom:
  - secretRef:
      name: shared-secrets
```

For DATABASE_URL override (service-specific DB schema):
```yaml
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: {service}-credentials
        key: DATABASE_URL
```

Encrypt new secrets: `sops -e -i overlays/{env}/secret-{service}.yaml`
Edit existing: `sops overlays/{env}/secret-{service}.yaml`

**Never commit plain-text secrets.** Registry credentials are stored as `registry-credentials` secret in every namespace.

**Reloader** (`infrastructure/reloader/`) — Stakater Reloader задеплоєний на всіх кластерах (namespace `reloader`). Всі CDE та DMZ Deployment мають анотацію:
```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
```
При зміні будь-якого Secret або ConfigMap, на який посилається Deployment, Reloader автоматично ініціює rolling restart. Ручний `kubectl rollout restart` після зміни `shared-secrets` або `*-config` більше не потрібен. Нові сервіси отримують анотацію автоматично через `_template/base/deployment.yaml`.

## Logging (ELK / Filebeat)

**ELK стек** розгорнутий поза кластером (Docker на окремих хостах). Filebeat збирає логи з усіх контейнерів і надсилає в Logstash.

```
K8s nodes → Filebeat DaemonSet (namespace: logging) → Logstash:5044 → Elasticsearch → Kibana
```

**Hosts:**
- dev/test → `10.201.3.41:5044`
- stage/prod → `10.201.98.21:5044`

**Індекси:** `logs-myapp-{environment}-YYYY.MM.dd` (один індекс на env)

**Маніфести:** `k8s-ops/apps/logging/filebeat/` (Kustomize base + overlays/dev/test/stage/prod)

**ArgoCD:** `logging-project` + `logging-appset` — 5 Applications (filebeat-dev/test/stage/prod-dmz/prod-cde)

**RBAC у logging-project:**
- `logging-dev-operator` (dev-team) — sync тільки filebeat-dev і filebeat-test
- `logging-prod-operator` (prod-operators) — sync всіх

**Важливо:** Filebeat пише registry в `hostPath: /var/lib/filebeat-data` на кожній ноді — виживає між рестартами і уникає дублікатів логів.

## Key prohibitions

- No plain-text passwords/tokens/keys in Git
- No `runAsUser: 0` or `allowPrivilegeEscalation: true` (exception: Filebeat DaemonSet — approved, reads host logs)
- No `:latest` tags in prod overlays
- No internet egress from CDE namespace
- No PostgreSQL access from DMZ namespace
- No `default` ServiceAccount
- No manual `kubectl apply` in prod — use ArgoCD/Kargo only

## Pre-deploy checklist

See [CHECKLIST-BEFORE-DEPLOY.md](CHECKLIST-BEFORE-DEPLOY.md) for the full list of IP placeholders to replace, secrets to create, and post-deploy verification commands.
