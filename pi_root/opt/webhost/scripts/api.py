#!/usr/bin/env python3
"""
api de monitoreo - backend del panel
kzltc | github.com/kzltc
correr con: /opt/webhost/venv/bin/python api.py
"""
import os, re, subprocess, time
from functools import wraps
from flask import Flask, request, jsonify

app = Flask(__name__)

# cambia esto con el token que genero install.sh
API_TOKEN = "CHANGE_ME"
NGINX_LOG = "/var/log/nginx/access.log"
DEFENSE_FILE = "/opt/webhost/config/defense_active"

_cache = {}

def cached(seconds=5):
    """cache en memoria, la pi sufre si le pegas 50 requests/seg"""
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            key = f.__name__
            now = time.time()
            if key in _cache and (now - _cache[key]["t"]) < seconds:
                return jsonify(_cache[key]["d"])
            data = f(*args, **kwargs)
            _cache[key] = {"d": data, "t": now}
            return jsonify(data)
        return wrapper
    return decorator

def check_token(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if request.headers.get("X-API-Token", "") != API_TOKEN:
            return jsonify({"e": "token invalido"}), 401
        return f(*args, **kwargs)
    return wrapper

@app.route("/api/stats")
@check_token
@cached(5)
def stats():
    try:
        with open("/proc/stat") as f:
            p = f.readline().split()
        idle = int(p[4])
        total = sum(int(x) for x in p[1:8])
        cpu = round(100 - (idle/total*100), 1) if total > 0 else 0
    except:
        cpu = 0

    try:
        with open("/proc/meminfo") as f:
            m = f.read()
        ram_total = int(re.search(r"MemTotal:\s+(\d+)", m).group(1)) // 1024
        ram_avail = int(re.search(r"MemAvailable:\s+(\d+)", m).group(1)) // 1024
        ram_used = ram_total - ram_avail
    except:
        ram_total = ram_avail = ram_used = 0

    try:
        s = os.statvfs("/")
        disk_total = (s.f_frsize * s.f_blocks) // (1024**3)
        disk_free = (s.f_frsize * s.f_bavail) // (1024**3)
    except:
        disk_total = disk_free = 0

    return {
        "cpu": cpu,
        "ram_total": ram_total, "ram_free": ram_avail, "ram_used": ram_used,
        "disk_total": disk_total, "disk_free": disk_free
    }

@app.route("/api/connections")
@check_token
@cached(5)
def connections():
    try:
        # ss -tn filtra tcp, state established solo las activas
        out = subprocess.check_output(
            "ss -tn state established | tail -n +2 | wc -l",
            shell=True, timeout=2
        ).decode().strip()
        count = int(out) if out.isdigit() else 0
    except:
        count = 0
    return {"connections": count}

@app.route("/api/banned")
@check_token
@cached(10)
def banned():
    try:
        # saco las ips baneadas de iptables, mas fiable que fail2ban-client
        out = subprocess.check_output(
            "iptables -L INPUT -n | grep DROP | awk '{print $4}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u",
            shell=True, timeout=2
        ).decode().strip()
        ips = [ip for ip in out.split("\n") if ip]
    except:
        ips = []
    return {"count": len(ips), "ips": ips}

@app.route("/api/attacks")
@check_token
@cached(10)
def attacks():
    try:
        # ultimos 403, 405, o bloqueos del log
        out = subprocess.check_output(
            "grep -E ' (403|405) ' /var/log/nginx/access.log | tail -5",
            shell=True, timeout=2
        ).decode().strip()
        lines = out.split("\n") if out else []
    except:
        lines = []
    return {"last": lines}

@app.route("/api/defense/status")
@check_token
def defense_status():
    return {"active": os.path.exists(DEFENSE_FILE)}

@app.route("/api/defense/toggle")
@check_token
def defense_toggle():
    if os.path.exists(DEFENSE_FILE):
        os.remove(DEFENSE_FILE)
        # restaurar zona normal
        subprocess.run(
            "sed -i 's/zone=defense/zone=normal/g' /etc/nginx/sites-available/default",
            shell=True, timeout=2
        )
        subprocess.run(["nginx", "-s", "reload"], timeout=3)
        return {"active": False}
    else:
        with open(DEFENSE_FILE, "w") as f:
            f.write("1")
        # activar zona defense (2 req/s en vez de 5)
        subprocess.run(
            "sed -i 's/zone=normal/zone=defense/g' /etc/nginx/sites-available/default",
            shell=True, timeout=2
        )
        subprocess.run(["nginx", "-s", "reload"], timeout=3)
        return {"active": True}

if __name__ == "__main__":
    from waitress import serve
    print("api en 127.0.0.1:5000")
    serve(app, host="127.0.0.1", port=5000, threads=4)