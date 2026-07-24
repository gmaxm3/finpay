#!/usr/bin/env bash
# ==============================================================================
# 01-install-k3s.sh — Встановлення k3s на ноду
#
# Використання:
#   Для server (перша нода в кластері):
#     ssh ubuntu@NODE_IP "bash -s" < 01-install-k3s.sh
#
#   Для agent (додаткові ноди):
#     K3S_URL=https://SERVER_IP:6443 K3S_TOKEN=TOKEN \
#       ssh ubuntu@NODE_IP "bash -s" < 01-install-k3s.sh
#
#   Для data ноди prod-cde (з taint):
#     INSTALL_K3S_EXEC="agent --node-taint dedicated=data:NoSchedule" \
#       K3S_URL=https://SERVER_IP:6443 K3S_TOKEN=TOKEN \
#       ssh ubuntu@NODE_IP "bash -s" < 01-install-k3s.sh
# ==============================================================================
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.29.3+k3s1}"
INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC:-server}"

echo "=== Встановлення k3s ${K3S_VERSION} ==="
echo "    Mode: ${INSTALL_K3S_EXEC}"

# Системні вимоги
echo "--- Перевірка системних вимог ---"
if [ "$(id -u)" -ne 0 ]; then
  echo "ПОМИЛКА: скрипт потребує root доступу (sudo)"
  exit 1
fi

# Вимикаємо swap (вимога Kubernetes)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Налаштування kernel parameters для k8s
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# PCI-DSS: вимикаємо IP forwarding з зовнішніх інтерфейсів де не потрібно
net.ipv4.conf.all.send_redirects    = 0
net.ipv4.conf.all.accept_redirects  = 0
net.ipv4.conf.all.accept_source_route = 0
EOF
sysctl --system

# Завантаження модулів
modprobe br_netfilter
modprobe overlay

echo "--- Встановлення k3s ---"

# Параметри для server mode
SERVER_ARGS=""
if echo "${INSTALL_K3S_EXEC}" | grep -q "^server"; then
  SERVER_ARGS="--disable traefik"  # Traefik встановимо окремо для контролю версії
  # Якщо потрібен кастомний Traefik — розкоментувати наступний рядок:
  # SERVER_ARGS="${SERVER_ARGS} --disable traefik"
fi

INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} ${SERVER_ARGS}" \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  curl -sfL https://get.k3s.io | sh -

echo "--- k3s встановлено ---"

# Для server node — виводимо kubeconfig та token
if echo "${INSTALL_K3S_EXEC}" | grep -q "^server"; then
  echo ""
  echo "=== Інформація для підключення ==="
  echo "Node IP: $(hostname -I | awk '{print $1}')"
  echo "Token (зберегти для agent нод):"
  cat /var/lib/rancher/k3s/server/node-token
  echo ""
  echo "kubeconfig (замінити 127.0.0.1 на зовнішній IP):"
  cat /etc/rancher/k3s/k3s.yaml
fi

echo ""
echo "=== k3s встановлено успішно ==="
echo "Статус: $(systemctl is-active k3s || systemctl is-active k3s-agent)"
