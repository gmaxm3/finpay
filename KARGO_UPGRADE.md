5. Kargo upgrade

Kargo зазвичай ставиться через Helm OCI chart:

helm -n kargo list
helm -n kargo get values kargo > kargo-values.yaml

Kargo docs показують інсталяцію через:

oci://ghcr.io/akuity/kargo-charts/kargo

і радять для кастомної інсталяції витягувати values через helm inspect values.

Upgrade до 1.9.x
helm upgrade kargo \
  oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo \
  --values kargo-values.yaml \
  --version 1.9.x \
  --wait \
  --timeout 10m

Потім перевірити:

kubectl -n kargo get pods
kubectl -n kargo get events --sort-by=.lastTimestamp | tail -50
Потім до 1.10.x
helm upgrade kargo \
  oci://ghcr.io/akuity/kargo-charts/kargo \
  --namespace kargo \
  --values kargo-values.yaml \
  --version 1.10.x \
  --wait \
  --timeout 10m


  В kargo-values.yaml додати для прокиду порта:
  USER-SUPPLIED VALUES:
api:
  adminAccount:
    enabled: true
    passwordHash: тут хеш
    tokenSigningKey: тут кей
  host: 10.201.69.50:30444
  tls:
    enabled: true
    selfSignedCert: true
  service:
    type: NodePort
    nodePort: 30444