#!/bin/bash
# healthcheck para cron (*/5 * * * *)
# kzltc | github.com/kzltc

LOG="/opt/webhost/logs/health.log"
TS=$(date '+%m-%d %H:%M')

ok=true

# nginx vivo?
if ! pgrep -x nginx >/dev/null; then
    echo "[$TS] nginx muerto, reiniciando" >> "$LOG"
    systemctl restart nginx 2>/dev/null
    ok=false
fi

# api responde?
if ! curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    -H "X-API-Token: $(grep API_TOKEN /opt/webhost/config/creds.env | cut -d= -f2)" \
    http://127.0.0.1:5000/api/stats 2>/dev/null | grep -q 200; then
    echo "[$TS] api caida, reiniciando" >> "$LOG"
    pkill -f "python.*api.py" 2>/dev/null || true
    /opt/webhost/venv/bin/python /opt/webhost/scripts/api.py &
    ok=false
fi

# defense.py corriendo?
if ! pgrep -f defense.py >/dev/null; then
    echo "[$TS] defense.py parado, arrancando" >> "$LOG"
    /opt/webhost/venv/bin/python /opt/webhost/scripts/defense.py &
    ok=false
fi

# disco > 10% libre?
disk_pct=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
if [[ "$disk_pct" -gt 90 ]]; then
    echo "[$TS] DISCO AL ${disk_pct}% - libera espacio YA" >> "$LOG"
    ok=false
fi

# ram > 1.6GB usada?
ram_used=$(free -m | awk '/Mem:/ {print $3}')
if [[ "$ram_used" -gt 1600 ]]; then
    echo "[$TS] RAM ALTA (${ram_used}MB) - limpiando" >> "$LOG"
    sync
    echo 3 > /proc/sys/vm/drop_caches
fi

$ok && echo "[$TS] todo ok" >> "$LOG"

# rota log si crece mucho
tail -n 200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"