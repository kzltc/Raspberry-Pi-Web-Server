# Raspberry Pi Web Server

Web server ultraligero para Raspberry Pi 4. 400MB RAM idle, panel de control, anti-DDoS automático, con SSL gratis Corre en 2GB

nginx + Flask + fail2ban + iptables. Añade sitios con un comando.

## stack

nginx-light · Flask + Waitress · fail2ban · iptables · certbot · ZRAM

Sin Docker. Sin MySQL. Sin Node.

## qué incluye

- Panel de control web (RAM, CPU, disco, conexiones, IPs baneadas)
- Modo defensa DDoS (manual o automático, baja a 2 req/s por IP)
- SSL automático con Let's Encrypt
- Script para añadir sitios (estático o proxy)
- Healthcheck cada 5 minutos con autorecuperación
- Logs en RAM (tmpfs) para no quemar la SD
- Firewall iptables con deny por defecto
- ZRAM 512MB comprimido con zstd

## instalación

```bash
git clone https://github.com/kzltc/Raspberry-Pi-Web-Server.git
cd Raspberry-Pi-Web-Server