#!/bin/bash
# añadir sitio nuevo sin tener que tocar nginx a mano
# kzltc | github.com/kzltc
set -e

read -p "dominio (ej: midominio.com): " DOMAIN
[[ -z "$DOMAIN" ]] && echo "dominio vacio, aborto" && exit 1

read -p "tipo [static/proxy]: " TYPE
[[ "$TYPE" != "static" && "$TYPE" != "proxy" ]] && echo "solo static o proxy" && exit 1

SITE_DIR="/var/www/sites/${DOMAIN}"
CONF_FILE="/etc/nginx/sites-available/${DOMAIN}"

mkdir -p "$SITE_DIR"

if [ "$TYPE" = "proxy" ]; then
    read -p "puerto a rutear (ej: 3000): " PORT
    [[ -z "$PORT" ]] && echo "necesito puerto" && exit 1
    cat > "$CONF_FILE" << VHOST
server {
    listen 80;
    server_name ${DOMAIN};
    limit_req zone=normal burst=10 nodelay;
    limit_conn connlimit 10;
    if (\$block_method) { return 405; }
    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
VHOST
else
    cat > "$CONF_FILE" << VHOST
server {
    listen 80;
    server_name ${DOMAIN};
    root ${SITE_DIR};
    index index.html index.htm;
    limit_req zone=normal burst=10 nodelay;
    limit_conn connlimit 10;
    if (\$block_method) { return 405; }
    location / {
        try_files \$uri \$uri/ =404;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }
}
VHOST
fi

ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/

# verifico sintaxis antes de recargar, nginx -t no miente
if nginx -t &>/dev/null; then
    nginx -s reload
    echo "sitio activo: http://${DOMAIN}"
else
    echo "ERROR: config rota, revisa $CONF_FILE"
    rm -f /etc/nginx/sites-enabled/$(basename "$CONF_FILE")
    exit 1
fi

# intento certbot SSL, si falla no pasa nada (se queda en http)
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email admin@${DOMAIN} 2>/dev/null && \
    echo "SSL ok: https://${DOMAIN}" || \
    echo "SSL no disponible (DNS apuntando? puerto 80 abierto?)"

echo "archivos en: ${SITE_DIR}"