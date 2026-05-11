#!/bin/bash
# bootstrap script - pi 4 webhost stack
# kzltc | github.com/kzltc
# testado en raspbian 11/12. si tienes ubuntu server cambia zram-tools por zram-config
set -e

# --- solo lo que uso de verdad ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $1"; }
err(){ echo -e "${RED}[!]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || err "sudo bash install.sh, no seas animal"

# cojo la ip del admin de la sesion ssh, si no hay tiro de who
if [[ -n "${SSH_CLIENT:-}" ]]; then
    ADMIN_IP="${SSH_CLIENT%% *}"
elif IP=$(who -m 2>/dev/null | grep -oP '\(\K[^)]+' | head -1); then
    ADMIN_IP="$IP"
else
    ADMIN_IP="192.168.1.1"  # ajusta esto a tu red, yo tiro esta porque es mi /24 habitual
fi

# genero todo con openssl que nunca falla, /dev/urandom es mas lento en pi
API_TOKEN=$(openssl rand -hex 16)
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

log "admin ip: ${ADMIN_IP} (si no es, edita /etc/fail2ban/jail.local y /opt/webhost/config/creds.env)"

# --- paquetes. nginx-light viene sin tonterias, no como nginx-full que trae modulo de geoip y mierdas ---
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    nginx-light \
    certbot python3-certbot-nginx \
    python3 python3-pip python3-venv \
    fail2ban iptables iptables-persistent \
    curl net-tools apache2-utils \
    zram-tools logrotate procps openssl
apt-get autoremove -y -qq
apt-get clean -qq
log "paquetes ok"

# --- servicios que joden ram. en mi pi el bluetooth se comia 30mb el solo ---
for svc in bluetooth hciuart avahi-daemon triggerhappy wpa_supplicant ModemManager; do
    if systemctl is-active --quiet ${svc}.service 2>/dev/null; then
        systemctl disable --now ${svc}.service 2>/dev/null && log "muerto: $svc" || true
    fi
done

# journald me lleno la sd en 3 dias la primera vez. nunca mas.
cat > /etc/systemd/journald.conf << 'JRNL'
[Journal]
Storage=volatile
RuntimeMaxUse=10M
SystemMaxUse=50M
MaxFileSec=1day
MaxRetentionSec=2day
ForwardToSyslog=no
JRNL
systemctl restart systemd-journald

# --- zram. en raspbian usa zram-tools, ubuntu es distinto ---
if dpkg -l zram-tools &>/dev/null; then
    cat > /etc/default/zramswap << 'ZRAM'
ALGO=zstd
SIZE=512
PRIORITY=100
ZRAM
    systemctl enable zramswap.service 2>/dev/null || true
    systemctl restart zramswap.service 2>/dev/null || log "zram no arranco, revisa si es ubuntu"
else
    # alternativa para ubuntu server
    modprobe zram 2>/dev/null || true
    echo 512M > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null && swapon /dev/zram0 2>/dev/null || true
fi

# --- estructura. nada de /opt/webhost/scripts/backup/2024/olds/ mierdas anidadas ---
mkdir -p /opt/webhost/{scripts,config,logs}
mkdir -p /var/www/{sites,html}
mkdir -p /var/log/nginx

id webadmin &>/dev/null || useradd -m -s /bin/bash -G www-data webadmin
echo "webadmin:${ADMIN_PASS}" | chpasswd
chown -R www-data:www-data /var/www

# --- python. flask con waitress porque gunicorn me dio problemas con workers en pi ---
python3 -m venv /opt/webhost/venv
source /opt/webhost/venv/bin/activate
pip install --quiet --no-cache-dir flask waitress
deactivate

# --- tmpfs para logs de nginx. la sd de 16gb me duro 4 meses sin esto, con esto llevo 2 años ---
grep -q "/var/log/nginx" /etc/fstab || \
    echo "tmpfs /var/log/nginx tmpfs defaults,noatime,nosuid,size=20M 0 0" >> /etc/fstab
mount /var/log/nginx 2>/dev/null || true

# --- nginx. 1 worker, sin http2, timeouts cortos. suficiente para 3-5 sitios estaticos ---
cat > /etc/nginx/nginx.conf << 'NGX'
user www-data;
worker_processes 1;
pid /run/nginx.pid;
events {
    worker_connections 256;
    use epoll;
    multi_accept on;
}
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 5;
    keepalive_requests 10;
    client_body_timeout 3;
    client_header_timeout 3;
    send_timeout 5;
    client_body_buffer_size 8k;
    client_header_buffer_size 1k;
    client_max_body_size 10m;
    large_client_header_buffers 2 1k;
    server_names_hash_bucket_size 32;
    server_names_hash_max_size 256;
    limit_req_zone $binary_remote_addr zone=normal:1m rate=5r/s;
    limit_req_zone $binary_remote_addr zone=defense:1m rate=2r/s;
    limit_conn_zone $binary_remote_addr zone=connlimit:1m;
    log_format minimal '$remote_addr $time_iso8601 "$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log minimal buffer=16k flush=30s;
    error_log /var/log/nginx/error.log warn;
    gzip on;
    gzip_comp_level 1;
    gzip_min_length 100;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    server_tokens off;
    map $request_method $block_method {
        default 0;
        ~^(PUT|DELETE|TRACE|CONNECT|PATCH)$ 1;
    }
    map $http_user_agent $bad_ua {
        default 0;
        "~*nmap" 1; "~*nikto" 1; "~*sqlmap" 1;
        "~*dirbuster" 1; "~*gobuster" 1; "~*masscan" 1;
        "~*zgrab" 1; "~*censys" 1; "~*shodan" 1;
        "~*nessus" 1; "~*openvas" 1;
    }
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGX

cat > /etc/nginx/sites-available/default << 'VHOST'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
    limit_req zone=normal burst=10 nodelay;
    limit_conn connlimit 10;
    if ($block_method) { return 405; }
    if ($bad_ua) { return 403; }
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    location / { try_files $uri $uri/ =404; }
    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        limit_req zone=normal burst=5 nodelay;
    }
    location ~ /\. { deny all; return 404; }
}
VHOST
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# verifico sintaxis antes de seguir, me ha salvado el culo mil veces
nginx -t 2>&1 || err "nginx config rota, algo fue mal"
systemctl restart nginx

# --- fail2ban. solo 3 jails, mas es tirar ram. el filtro nginx-dos lo pongo yo porque
#     el que trae debian por defecto es una mierda que no pilla nada ---
htpasswd -bc /opt/webhost/config/.htpasswd admin "${ADMIN_PASS}"

cat > /etc/fail2ban/jail.local << F2B
[DEFAULT]
ignoreip = 127.0.0.1/8 ${ADMIN_IP}
bantime = 300
findtime = 60
maxretry = 3
backend = polling
usedns = no
enabled = false

[nginx-dos]
enabled = true
port = http,https
filter = nginx-dos
logpath = /var/log/nginx/access.log
maxretry = 80
findtime = 60
bantime = 600

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 600

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 300
F2B

cat > /etc/fail2ban/filter.d/nginx-dos.conf << 'FLT'
[Definition]
failregex = ^<HOST> - - \[.*\] "(GET|POST) .* HTTP.*" (200|301|302|404)
ignoreregex =
FLT

# --- iptables. deny por defecto, solo ssh/http/https entrantes ---
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

systemctl restart fail2ban
log "firewall + fail2ban ok"

# --- guardo creds (protege este archivo) ---
cat > /opt/webhost/config/creds.env << CREDS
# IMPORTANTE: chmod 600 a esto
ADMIN_USER=webadmin
ADMIN_PASS=${ADMIN_PASS}
API_TOKEN=${API_TOKEN}
ADMIN_IP=${ADMIN_IP}
CREDS
chmod 600 /opt/webhost/config/creds.env

# --- resumen final ---
SERVER_IP=$(hostname -I | awk '{print $1}')
FREE_RAM=$(free -m | awk '/Mem:/ {print $7}')
echo ""
echo "--- LISTO ---"
echo "ip:       ${SERVER_IP}"
echo "ram libre: ${FREE_RAM}MB"
echo "panel:    http://${SERVER_IP}/panel"
echo "user:     admin"
echo "pass:     ${ADMIN_PASS}"
echo "api token: ${API_TOKEN}"
echo ""
echo "sube estos archivos a mano:"
echo "  api.py       -> /opt/webhost/scripts/"
echo "  defense.py   -> /opt/webhost/scripts/"
echo "  dashboard.html -> /var/www/html/panel/index.html"
echo "  landing.html   -> /var/www/html/index.html"
echo "  healthcheck.sh -> /opt/webhost/scripts/"
echo "  add-site.sh    -> /opt/webhost/scripts/"
echo ""
echo "reinicia y comprueba con: free -h && ps aux --sort=-%mem | head -10"
echo "kzltc | github.com/kzltc"