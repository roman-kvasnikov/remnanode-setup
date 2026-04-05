#!/bin/bash
set -euo pipefail

SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID9RdgFuS9wCoBSJ/OpdGWBO1JNVVVbi32o2J/YO2uMC romank@master"

# Проверка запуска от root
if [[ "$EUID" -ne 0 ]]; then
    echo "Запускай от root: sudo bash setup-node.sh"
    exit 1
fi

echo "=== [1/8] Создание пользователя super ==="
if id "super" &>/dev/null; then
    echo "Пользователь super уже существует, пропускаю"
else
    useradd -m -s /bin/bash -G sudo super
    echo "super:super" | chpasswd
    echo "Пользователь super создан"
fi

echo "=== [2/8] Настройка SSH ключа ==="
mkdir -p /home/super/.ssh
echo "$SSH_PUBLIC_KEY" > /home/super/.ssh/authorized_keys
chmod 700 /home/super/.ssh
chmod 600 /home/super/.ssh/authorized_keys
chown -R super:super /home/super/.ssh

echo "=== [3/8] Харденинг SSH ==="
cat > /etc/ssh/sshd_config.d/00-hardening.conf << 'EOF'
Port 12122
LoginGraceTime 1m
MaxAuthTries 5
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
AllowUsers super
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

echo "=== [4/8] Установка Docker ==="
curl -fsSL https://get.docker.com | sh
echo "Docker установлен: $(docker --version)"

echo "=== [5/8] Установка и настройка UFW ==="
apt-get update -qq
apt-get install -y -qq ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 12122/tcp	# SSH
ufw allow 8443/tcp	# VLESS Reality XRAY
ufw allow 443/tcp	# VLESS Reality XHTTP
ufw allow 443/udp	# Hysteria2
ufw allow 2053/tcp	# VLESS Reality XRAY
ufw allow 2222/tcp	# Node management
ufw allow 1234/tcp

ufw --force enable
echo "UFW активирован"

echo "=== [6/8] Установка и настройка fail2ban ==="
apt-get install -y -qq fail2ban

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 12122
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "=== [7/8] Подготовка Remnanode ==="
mkdir -p /opt/remnanode
cat > /opt/remnanode/docker-compose.yml << 'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=""
    volumes:
      - ./geoip.dat:/usr/local/share/xray/geoip.dat:ro
      - ./geosite.dat:/usr/local/share/xray/geosite.dat:ro
      - ./ru-geoip.dat:/usr/local/share/xray/ru-geoip.dat:ro
      - ./ru-geosite.dat:/usr/local/share/xray/ru-geosite.dat:ro
EOF

echo "=== [8/8] Скрипт обновления геобаз + cron ==="
cat > /opt/remnanode/update-geo.sh << 'SCRIPT'
#!/bin/bash

GEO_DIR="/opt/remnanode"
LOG_FILE="/var/log/xray-geo-update.log"

echo "$(date): Starting geo update" >> "$LOG_FILE"

# Скачиваем все файлы во временные
if wget -q -O "$GEO_DIR/geoip.dat.new" \
     https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
   wget -q -O "$GEO_DIR/geosite.dat.new" \
     https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat && \
   wget -q -O "$GEO_DIR/ru-geoip.dat.new" \
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat && \
   wget -q -O "$GEO_DIR/ru-geosite.dat.new" \
     https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat; then

  # Все скачалось — делаем атомарную замену
  mv "$GEO_DIR/geoip.dat.new" "$GEO_DIR/geoip.dat"
  mv "$GEO_DIR/geosite.dat.new" "$GEO_DIR/geosite.dat"
  mv "$GEO_DIR/ru-geoip.dat.new" "$GEO_DIR/ru-geoip.dat"
  mv "$GEO_DIR/ru-geosite.dat.new" "$GEO_DIR/ru-geosite.dat"

  docker restart remnanode
  echo "$(date): Update successful, container restarted" >> "$LOG_FILE"
else
  # Что-то не скачалось — чистим временные файлы
  rm -f "$GEO_DIR"/*.new
  echo "$(date): Download failed, no changes made" >> "$LOG_FILE"
fi
SCRIPT

chmod +x /opt/remnanode/update-geo.sh

# Добавляем в cron (каждый день в 4:00)
CRON_JOB="0 4 * * * /opt/remnanode/update-geo.sh"
(crontab -l 2>/dev/null | grep -v "update-geo.sh"; echo "$CRON_JOB") | crontab -

# Первый запуск геобаз
echo "Скачиваю геобазы (первый запуск)..."
/opt/remnanode/update-geo.sh

# Перезапуск SSH
echo ""
echo "=== Перезапускаю SSH ==="
systemctl restart sshd

echo ""
echo "============================================"
echo "  ГОТОВО! Сервер настроен."
echo "============================================"
echo ""
echo "  Пользователь:   super"
echo "  SSH порт:       12122"
echo "  Подключение:    ssh super@<IP> -p 12122"
echo ""
echo "  Remnanode:      cd /opt/remnanode"
echo "  Редактировать:  nano /opt/remnanode/docker-compose.yml"
echo "  Запуск:         docker compose -f /opt/remnanode/docker-compose.yml up -d"
echo ""
echo "============================================"
