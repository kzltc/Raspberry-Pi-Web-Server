#!/usr/bin/env python3
"""
defensa anti-ddos ligera
kzltc | github.com/kzltc
correr con nohup o systemd, background
"""
import os, time, subprocess
from collections import defaultdict

NGINX_LOG = "/var/log/nginx/access.log"
WHITELIST = "/opt/webhost/config/whitelist.txt"
DEFENSE_FILE = "/opt/webhost/config/defense_active"
BLOCK_TIME = 1800      # 30 min
CHECK_EVERY = 10       # segundos entre chequeos
STORM_LIMIT = 30       # ips unicas en 60s = activar defensa
ABUSE_LIMIT = 10       # requests en 10s de una sola ip = ban

def load_whitelist():
    ips = set()
    try:
        if os.path.exists(WHITELIST):
            with open(WHITELIST) as f:
                for line in f:
                    ip = line.strip()
                    if ip and not ip.startswith("#"):
                        ips.add(ip)
    except:
        pass
    return ips

def recent_ips(seconds=60):
    """cuenta cuantas ips unicas hay en las ultimas N segundos"""
    cutoff = time.time() - seconds
    ips = set()
    hits = defaultdict(int)
    try:
        with open(NGINX_LOG) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 4:
                    continue
                ip = parts[0]
                try:
                    # timestamp iso8601 en pos 1, formato 2024-01-15T03:22:11+00:00
                    ts_str = parts[1].split("+")[0]
                    ts = time.mktime(time.strptime(ts_str, "%Y-%m-%dT%H:%M:%S"))
                    if ts >= cutoff:
                        ips.add(ip)
                        hits[ip] += 1
                except:
                    pass
    except:
        pass
    return ips, hits

def ban(ip):
    subprocess.run(["iptables", "-A", "INPUT", "-s", ip, "-j", "DROP"], timeout=2)
    subprocess.Popen(
        f"sleep {BLOCK_TIME} && iptables -D INPUT -s {ip} -j DROP",
        shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

def defense_on():
    if not os.path.exists(DEFENSE_FILE):
        with open(DEFENSE_FILE, "w") as f:
            f.write("auto")
    subprocess.run(
        "sed -i 's/zone=normal/zone=defense/g' /etc/nginx/sites-available/default",
        shell=True, timeout=2
    )
    subprocess.run(["nginx", "-s", "reload"], timeout=3)

def defense_off():
    if os.path.exists(DEFENSE_FILE):
        os.remove(DEFENSE_FILE)
    subprocess.run(
        "sed -i 's/zone=defense/zone=normal/g' /etc/nginx/sites-available/default",
        shell=True, timeout=2
    )
    subprocess.run(["nginx", "-s", "reload"], timeout=3)

def check_ram():
    """si la ram se dispara, limpia cache y trunca logs"""
    try:
        with open("/proc/meminfo") as f:
            m = f.read()
        total = int(re.search(r"MemTotal:\s+(\d+)", m).group(1))
        avail = int(re.search(r"MemAvailable:\s+(\d+)", m).group(1))
        if (total - avail) > 1572864:  # 1.5GB en KB
            subprocess.run(["sync"], timeout=5)
            with open("/proc/sys/vm/drop_caches", "w") as f:
                f.write("3")
            subprocess.run(["truncate", "-s", "0", NGINX_LOG], timeout=2)
    except:
        pass

whitelist = load_whitelist()
was_under_attack = False

while True:
    try:
        ips, hits = recent_ips(60)
        unique_count = len(ips)

        # tormenta de ips -> defensa global
        if unique_count > STORM_LIMIT and not was_under_attack:
            defense_on()
            was_under_attack = True
        elif unique_count <= STORM_LIMIT and was_under_attack:
            defense_off()
            was_under_attack = False

        # abusadores individuales (>10 peticiones en ventana de 10s)
        ips_10s, hits_10s = recent_ips(10)
        for ip, count in hits_10s.items():
            if ip in whitelist:
                continue
            if count > ABUSE_LIMIT:
                ban(ip)

        check_ram()
    except:
        pass

    time.sleep(CHECK_EVERY)