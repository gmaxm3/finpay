#!/usr/bin/env python3.11
"""Generate FinPayBank PROD Architecture PNG diagram."""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import matplotlib.patheffects as pe

fig, ax = plt.subplots(1, 1, figsize=(28, 20))
ax.set_xlim(0, 28)
ax.set_ylim(0, 20)
ax.axis('off')
fig.patch.set_facecolor('#ffffff')

# ── helpers ──────────────────────────────────────────────────────────────────
def box(ax, x, y, w, h, label, sublabel='', fc='#fff2cc', ec='#d6b656',
        fontsize=9, bold=False, radius=0.15, alpha=1.0):
    rect = FancyBboxPatch((x, y), w, h,
                           boxstyle=f"round,pad=0,rounding_size={radius}",
                           linewidth=1.5, edgecolor=ec, facecolor=fc, alpha=alpha, zorder=3)
    ax.add_patch(rect)
    weight = 'bold' if bold else 'normal'
    full = label + ('\n' + sublabel if sublabel else '')
    ax.text(x + w/2, y + h/2, full, ha='center', va='center',
            fontsize=fontsize, fontweight=weight, wrap=True, zorder=4,
            multialignment='center')

def arrow(ax, x1, y1, x2, y2, label='', color='#888888', lw=1.5, style='->'):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle=style, color=color, lw=lw), zorder=5)
    if label:
        mx, my = (x1+x2)/2, (y1+y2)/2
        ax.text(mx, my, label, ha='center', va='center', fontsize=7,
                color=color, zorder=6,
                bbox=dict(boxstyle='round,pad=0.1', fc='white', ec='none', alpha=0.8))

def swim(ax, x, y, w, h, title, fc='#fff8e1', ec='#d6b656', title_fc=None, fontsize=10):
    rect = FancyBboxPatch((x, y), w, h,
                           boxstyle="round,pad=0,rounding_size=0.2",
                           linewidth=2, edgecolor=ec, facecolor=fc, zorder=2)
    ax.add_patch(rect)
    tfc = title_fc or ec
    ax.text(x + w/2, y + h - 0.27, title, ha='center', va='center',
            fontsize=fontsize, fontweight='bold', color=tfc, zorder=4)

# ─────────────────────────────────────────────────────────────────────────────
# TITLE
ax.text(14, 19.5, 'FinPayBank — PROD Architecture (PCI-DSS)', ha='center',
        va='center', fontsize=17, fontweight='bold', color='#1a1a1a')
ax.text(14, 19.1, 'prod-dmz cluster  ⟷  RabbitMQ :5672  ⟷  prod-cde cluster  |  ArgoCD Hub + Kargo  |  Observability',
        ha='center', va='center', fontsize=9, color='#555555')

# ─────────────────────────────────────────────────────────────────────────────
# INTERNET
box(ax, 5.8, 17.2, 3.2, 1.1, '[ INTERNET ]', fc='#dae8fc', ec='#6c8ebf', fontsize=11, bold=True)

# ─────────────────────────────────────────────────────────────────────────────
# MANAGEMENT NODE
swim(ax, 0.3, 15.5, 5.0, 1.8, '', fc='#f9f9f9', ec='#aaaaaa')
ax.text(0.7, 17.1, 'MANAGEMENT NODE', fontsize=8, fontweight='bold', color='#666666')
box(ax, 0.5, 15.7, 2.0, 1.1, 'ArgoCD Hub\nv2.10.4', fc='#d5e8d4', ec='#82b366', fontsize=9, bold=True)
box(ax, 2.9, 15.7, 2.0, 1.1, 'Kargo\nv0.8.0', fc='#d5e8d4', ec='#82b366', fontsize=9, bold=True)
ax.annotate('', xy=(2.9, 16.25), xytext=(2.5, 16.25),
            arrowprops=dict(arrowstyle='<->', color='#82b366', lw=1.2), zorder=5)

# ─────────────────────────────────────────────────────────────────────────────
# PROD-DMZ CLUSTER
swim(ax, 0.3, 4.5, 12.2, 10.8,
     'prod-dmz cluster  |  2 ноди  |  zone: dmz  |  Internet-facing  |  namespace: prod',
     fc='#fffde7', ec='#d6b656', title_fc='#7a5c00', fontsize=9)

# Traefik
box(ax, 3.8, 13.5, 3.0, 0.9, 'Traefik IngressController\nTLS termination + Rate limiting',
    fc='#ffe0b2', ec='#e65100', fontsize=8.5, bold=True)

# nginx
box(ax, 3.8, 12.3, 3.0, 0.9, 'nginx (балансувальник)\nnginx:1.27',
    fc='#fff9c4', ec='#d6b656', fontsize=8.5)

# DMZ services row 1
box(ax, 0.6, 10.9, 2.6, 0.9, 'static\n(Angular SPA)\nstatic:26.03.1', fc='#fff9c4', ec='#d6b656', fontsize=7.5)
box(ax, 3.5, 10.9, 2.8, 0.9, 'onboarding-web\n(Web SPA)\nwebviews-on-boarding:1.0.0', fc='#fff9c4', ec='#d6b656', fontsize=7.5)
box(ax, 6.6, 10.9, 2.8, 0.9, 'kyc-liveness-web\n(KYC UI)\nkyc-liveness-web:25.08.01', fc='#fff9c4', ec='#d6b656', fontsize=7.5)

# DMZ services row 2 (internet egress)
box(ax, 0.6, 9.7, 2.8, 0.9, 'push-gateway\npush-gateway:26.01.1\n→ FCM :443', fc='#ffe0b2', ec='#e65100', fontsize=7.5)
box(ax, 3.7, 9.7, 2.8, 0.9, 'sms\nsms:26.02.1\n→ SMS provider :443/:80', fc='#ffe0b2', ec='#e65100', fontsize=7.5)

# DMZ NetworkPolicy note
np_box = FancyBboxPatch((0.5, 7.4), 11.7, 2.0,
                         boxstyle="round,pad=0,rounding_size=0.1",
                         linewidth=1, edgecolor='#d6b656', facecolor='#fffde7', alpha=0.7, zorder=2)
ax.add_patch(np_box)
ax.text(0.7, 9.25, 'NetworkPolicy:', fontsize=8, fontweight='bold', color='#7a5c00')
ax.text(0.7, 8.9,  '• Ingress: Internet → Traefik → nginx → services', fontsize=7.5, color='#333')
ax.text(0.7, 8.6,  '• Egress: → RabbitMQ CDE :5672  (єдиний канал до CDE)', fontsize=7.5, color='#333')
ax.text(0.7, 8.3,  '• Egress: push-gateway → FCM :443  |  sms → provider :443/:80', fontsize=7.5, color='#333')
ax.text(0.7, 8.0,  '• Egress: DNS :53  |  NO direct CDE egress крім RabbitMQ', fontsize=7.5, color='#333')
ax.text(0.7, 7.65, '✓ runAsNonRoot  ✓ readOnlyRootFilesystem  ✓ allowPrivilegeEscalation:false  '
                    '✓ caps.drop:ALL  ✓ seccompProfile:RuntimeDefault',
        fontsize=7, color='#2e7d32', fontstyle='italic')

# DMZ nodes info
ax.text(0.7, 5.15, 'Ноди: prod-dmz-node-1, prod-dmz-node-2 (HA)  |  Replicas: 2+  |  '
                    'imagePullSecrets: registry-credentials',
        fontsize=7.5, color='#5c4000')

# ─────────────────────────────────────────────────────────────────────────────
# PROD-CDE CLUSTER
swim(ax, 13.2, 4.5, 13.8, 10.8,
     'prod-cde cluster  |  3 ноди  |  zone: cde  |  PCI-DSS scope  |  NO internet  |  namespace: prod',
     fc='#fce4ec', ec='#c62828', title_fc='#7a0000', fontsize=9)

# StatefulSets sub-box
swim(ax, 13.4, 12.5, 13.4, 2.4,
     'StatefulSets — data node (prod-cde-node-3, taint: dedicated=data:NoSchedule)',
     fc='#ffcdd2', ec='#c62828', title_fc='#7a0000', fontsize=8)
box(ax, 13.6, 12.6, 2.8, 1.9, 'Redis 8\nStatefulSet\n50Gi PVC', fc='#ffcdd2', ec='#c62828', fontsize=8, bold=True)
box(ax, 16.7, 12.6, 2.8, 1.9, 'RabbitMQ 4\nStatefulSet\n50Gi PVC\nManagement UI :15672', fc='#ffcdd2', ec='#c62828', fontsize=8, bold=True)
box(ax, 19.8, 12.6, 3.2, 1.9, 'Elasticsearch 7.4.2\nStatefulSet\n200Gi PVC\nxpack.security', fc='#ffcdd2', ec='#c62828', fontsize=8, bold=True)
box(ax, 23.3, 12.6, 3.0, 1.9, 'MinIO\nStatefulSet\n50Gi PVC', fc='#ffcdd2', ec='#c62828', fontsize=8, bold=True)

# api-gateway
box(ax, 17.5, 11.2, 3.0, 0.9, 'api-gateway (nginx:1.27)\nInternal router → identity/cards/customer',
    fc='#f8cecc', ec='#c62828', fontsize=8, bold=True)

# ESB row 1
row1_y = 10.0
box(ax, 13.4, row1_y, 2.4, 0.9, 'identity\n25.09.3', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 16.1, row1_y, 2.4, 0.9, 'cards ⚠️\n(PCI certs)\nlatest→digest', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 18.8, row1_y, 2.4, 0.9, 'payments ⚠️\nlatest→digest\n2x approval prod', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 21.5, row1_y, 2.4, 0.9, 'ukrcard ⚠️\n(PCI certs)\n→ ПЦ/АБС', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 24.2, row1_y, 2.5, 0.9, 'customer\nlatest→digest', fc='#f8cecc', ec='#c62828', fontsize=7.5)

# ESB row 2
row2_y = 8.8
box(ax, 13.4, row2_y, 2.4, 0.9, 'transactions\n+ worker', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 16.1, row2_y, 2.4, 0.9, 'notifications\n+ worker', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 18.8, row2_y, 2.4, 0.9, 'banks\n+ worker\n→ Elasticsearch', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 21.5, row2_y, 2.4, 0.9, 'onboarding\n26.03.11', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 24.2, row2_y, 2.5, 0.9, 'kyc-liveness\nservice+worker\n→ minio/postgres', fc='#f8cecc', ec='#c62828', fontsize=7.5)

# ESB row 3
row3_y = 7.6
box(ax, 13.4, row3_y, 2.4, 0.9, 'password-recovery\n26.03.4', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 16.1, row3_y, 2.4, 0.9, 'customers-update\n26.01.7', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 18.8, row3_y, 2.4, 0.9, 'qr | print-reports\ncheck-for-update\nmaintenance', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 21.5, row3_y, 2.4, 0.9, 'ukrpost-client\n26.02.3\n→ External API', fc='#f8cecc', ec='#c62828', fontsize=7.5)
box(ax, 24.2, row3_y, 2.5, 0.9, 'vkursi-client\n26.02.4\n→ External API', fc='#f8cecc', ec='#c62828', fontsize=7.5)

# CDE NetworkPolicy note
np_cde = FancyBboxPatch((13.4, 5.1), 13.4, 2.2,
                          boxstyle="round,pad=0,rounding_size=0.1",
                          linewidth=1, edgecolor='#c62828', facecolor='#fce4ec', alpha=0.7, zorder=2)
ax.add_patch(np_cde)
ax.text(13.6, 7.1, 'NetworkPolicy CDE:', fontsize=8, fontweight='bold', color='#7a0000')
ax.text(13.6, 6.8,  '• Ingress: тільки від DMZ через RabbitMQ :5672 та api-gateway', fontsize=7.5, color='#333')
ax.text(13.6, 6.5,  '• Egress: → PostgreSQL bare metal :5432  |  DNS :53', fontsize=7.5, color='#333')
ax.text(13.6, 6.2,  '• NO internet egress  |  NO DMZ direct access', fontsize=7.5, color='#b71c1c', fontweight='bold')
ax.text(13.6, 5.9,  '⚠ C-1: prod overlays newTag:latest → потребує digest/semver pin', fontsize=7.5, color='#b71c1c')
ax.text(13.6, 5.55, '⚠ H-1: Elasticsearch initContainer privileged:true + runAsUser:0  '
                     '⚠ H-6: payments 2x approval — задеклар., не реаліз.',
        fontsize=7, color='#b71c1c')
ax.text(13.6, 5.2,  '✓ runAsNonRoot  ✓ readOnlyRootFilesystem  ✓ allowPrivilegeEscalation:false  '
                     '✓ automountServiceAccountToken:false  ✓ RBAC per-service',
        fontsize=7, color='#2e7d32', fontstyle='italic')

# ─────────────────────────────────────────────────────────────────────────────
# OBSERVABILITY NODE
swim(ax, 0.3, 2.0, 8.5, 2.2, 'OBSERVABILITY NODE', fc='#f3e5f5', ec='#7b1fa2', title_fc='#7b1fa2', fontsize=9)
box(ax, 0.5, 2.1, 1.9, 1.7, 'Prometheus\nkube-prometheus-\nstack 58.3.1', fc='#e1d5e7', ec='#9673a6', fontsize=8)
box(ax, 2.7, 2.1, 1.8, 1.7, 'Loki\nLog\naggregation', fc='#e1d5e7', ec='#9673a6', fontsize=8)
box(ax, 4.8, 2.1, 1.8, 1.7, 'Grafana\nDashboards', fc='#e1d5e7', ec='#9673a6', fontsize=8)
box(ax, 6.9, 2.1, 1.7, 1.7, 'Alert-\nmanager\nPCI alerts', fc='#e1d5e7', ec='#9673a6', fontsize=8)

# ─────────────────────────────────────────────────────────────────────────────
# POSTGRESQL BARE METAL
swim(ax, 9.5, 2.0, 7.0, 2.2, 'PostgreSQL (bare metal — поза K8s)', fc='#e3f2fd', ec='#1565c0', title_fc='#0d47a1', fontsize=9)
box(ax, 9.7, 2.1, 2.8, 1.7, 'db-primary\n:5432\n(read/write)', fc='#dae8fc', ec='#6c8ebf', fontsize=9, bold=True)
box(ax, 13.0, 2.1, 3.2, 1.7, 'db-replica\n:5432\n(read-only)', fc='#dae8fc', ec='#6c8ebf', fontsize=9)
arrow(ax, 12.5, 2.95, 13.0, 2.95, 'streaming\nreplication', color='#6c8ebf', lw=1.2)

# ─────────────────────────────────────────────────────────────────────────────
# EXTERNAL SERVICES (right side, stacked)
ext_x = 17.0
swim(ax, ext_x, 2.0, 10.2, 2.2, 'EXTERNAL SERVICES', fc='#f5f5f5', ec='#9e9e9e', title_fc='#424242', fontsize=9)
box(ax, ext_x+0.2, 2.1, 2.0, 1.7, 'Google FCM\n(Firebase :443)', fc='#f5f5f5', ec='#9e9e9e', fontsize=8)
box(ax, ext_x+2.5, 2.1, 2.0, 1.7, 'SMS Provider\n(:443/:80)', fc='#f5f5f5', ec='#9e9e9e', fontsize=8)
box(ax, ext_x+4.8, 2.1, 2.3, 1.7, 'ПЦ / АБС\n(Платіжний центр\nCore Banking)', fc='#f5f5f5', ec='#9e9e9e', fontsize=8)
box(ax, ext_x+7.4, 2.1, 2.5, 0.7, 'Укрпошта API', fc='#f5f5f5', ec='#9e9e9e', fontsize=7.5)
box(ax, ext_x+7.4, 3.0, 2.5, 0.7, 'Vkursi API', fc='#f5f5f5', ec='#9e9e9e', fontsize=7.5)

# Container Registry
box(ax, 0.3, 0.3, 13.5, 1.4,
    'Container Registry:  hub.kapowai.com.ua  |  finpaybank.kapowai.com.ua\n'
    'imagePullSecrets: registry-credentials (в кожному namespace)',
    fc='#f5f5f5', ec='#9e9e9e', fontsize=8.5)

# ─────────────────────────────────────────────────────────────────────────────
# KARGO PROMOTION FLOW
promo_box = FancyBboxPatch((14.1, 0.3), 13.5, 1.4,
                            boxstyle="round,pad=0,rounding_size=0.1",
                            linewidth=1.5, edgecolor='#82b366', facecolor='#d5e8d4', alpha=0.9, zorder=2)
ax.add_patch(promo_box)
ax.text(20.85, 1.4, 'KARGO PROMOTION FLOW', ha='center', fontsize=9, fontweight='bold', color='#2e7d32')
ax.text(20.85, 1.0, 'CI push → dev (auto) → test (auto) → stage (manual approval) → prod (manual, 2x для payments)',
        ha='center', fontsize=8.5, color='#1b5e20')
ax.text(20.85, 0.6, 'Kargo Warehouse детектує нові image tags → Freight → Stage promotion  |  prod: ArgoCD manual sync',
        ha='center', fontsize=8, color='#1b5e20')

# ─────────────────────────────────────────────────────────────────────────────
# ARROWS

# Internet → Traefik
arrow(ax, 7.4, 17.2, 5.3, 14.4, 'HTTPS :443', color='#1565c0', lw=2)

# ArgoCD → DMZ cluster (sync)
arrow(ax, 1.5, 15.7, 3.5, 15.3, 'sync\n(GitOps)', color='#2e7d32', lw=1.5)

# ArgoCD → CDE cluster (sync)
arrow(ax, 3.2, 15.7, 14.5, 15.3, 'sync\n(GitOps)', color='#2e7d32', lw=1.5)

# Kargo → Registry (polling)
arrow(ax, 3.9, 15.7, 3.9, 1.7, 'image\npolling', color='#82b366', lw=1.2)

# DMZ → CDE via RabbitMQ (main bridge)
arrow(ax, 12.5, 10.0, 13.2, 10.0, 'RabbitMQ :5672\n(єдиний канал DMZ→CDE)', color='#e65100', lw=2.5)

# push-gateway → FCM
arrow(ax, 5.4, 9.7, 17.2, 3.0, ':443', color='#888', lw=1, style='->')

# sms → SMS provider
arrow(ax, 6.5, 9.7, 19.5, 3.0, ':443', color='#888', lw=1, style='->')

# ukrcard → ПЦ/АБС
arrow(ax, 22.7, 7.6, 21.8, 3.0, 'mTLS\nПЦ/АБС', color='#c62828', lw=1.2)

# CDE → PostgreSQL
arrow(ax, 19.0, 4.5, 13.0, 3.2, 'TCP :5432\n(тільки з CDE)', color='#0d47a1', lw=2)

# Observability ← clusters metrics (Prometheus Agent)
arrow(ax, 6.5, 4.5, 2.4, 3.8, 'Prometheus Agent\nremote_write', color='#7b1fa2', lw=1.2)
arrow(ax, 17.0, 4.5, 4.3, 3.8, 'Prometheus Agent\nremote_write', color='#7b1fa2', lw=1.2)

# ─────────────────────────────────────────────────────────────────────────────
# LEGEND (top right)
lx, ly = 21.5, 17.0
leg_bg = FancyBboxPatch((lx, ly-4.0), 6.2, 4.3,
                          boxstyle="round,pad=0,rounding_size=0.1",
                          linewidth=1, edgecolor='#aaaaaa', facecolor='#fafafa', zorder=3)
ax.add_patch(leg_bg)
ax.text(lx+3.1, ly+0.1, 'ЛЕГЕНДА', ha='center', fontsize=10, fontweight='bold', color='#333')

legend_items = [
    ('#fff9c4', '#d6b656', 'DMZ сервіс (internet-facing)'),
    ('#ffe0b2', '#e65100', 'DMZ сервіс з internet egress'),
    ('#f8cecc', '#c62828', 'CDE ESB сервіс (PCI-DSS scope)'),
    ('#ffcdd2', '#c62828', 'CDE StatefulSet (data)'),
    ('#d5e8d4', '#82b366', 'GitOps (ArgoCD / Kargo)'),
    ('#e1d5e7', '#9673a6', 'Observability node'),
    ('#dae8fc', '#6c8ebf', 'Bare metal / External DB'),
    ('#f5f5f5', '#9e9e9e', 'External services'),
]
for i, (fc, ec, label) in enumerate(legend_items):
    yy = ly - 0.55*(i+1)
    rect = FancyBboxPatch((lx+0.2, yy-0.15), 0.5, 0.35,
                           boxstyle="round,pad=0,rounding_size=0.05",
                           linewidth=1, edgecolor=ec, facecolor=fc, zorder=4)
    ax.add_patch(rect)
    ax.text(lx+0.9, yy+0.02, label, va='center', fontsize=8, color='#333', zorder=5)

ax.text(lx+0.2, ly-4.65, '⚠ = Critical/High issues (architecture review findings)',
        fontsize=7.5, color='#b71c1c', fontstyle='italic')

# ─────────────────────────────────────────────────────────────────────────────
plt.tight_layout(pad=0)
output = '/Users/xeon/work/kapowai/finpaybank/finpaybank-gitops/docs/architecture-prod.png'
plt.savefig(output, dpi=150, bbox_inches='tight', facecolor='white', edgecolor='none')
print(f'Saved: {output}')
