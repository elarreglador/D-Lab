#!/bin/bash
# Script para configurar WireGuard en D1/D2 y autorizar clave SSH de DV0
# Ejecutar en cada nodo (D1 y D2) cuando tengas acceso local o por SSH

set -e

if [ "$#" -ne 1 ]; then
    echo "Uso: $0 {d1|d2}"
    exit 1
fi

NODE=$1

if [ "$NODE" = "d1" ]; then
    CONFIG_FILE="wg0-client-d1.conf"
    NODE_IP="10.8.0.11"
elif [ "$NODE" = "d2" ]; then
    CONFIG_FILE="wg0-client-d2.conf"
    NODE_IP="10.8.0.12"
else
    echo "Error: debe ser 'd1' o 'd2'"
    exit 1
fi

echo "=== Configurando $NODE ==="

# 1. Instalar WireGuard
sudo apt-get install -y wireguard wireguard-tools

# 2. Copiar config WireGuard
sudo cp "$CONFIG_FILE" /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf

# 3. Iniciar WireGuard
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# 4. Verificar conexión
echo "Esperando conexión WireGuard..."
sleep 3
ping -c 2 10.8.0.1

# 5. Autorizar clave SSH de DV0
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys << 'EOF'
<DV0_SSH_PUBLIC_KEY>
EOF

echo "=== $NODE configurado correctamente ==="
echo "IP WireGuard: $NODE_IP"
