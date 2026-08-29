#!/bin/sh
# Renews the Let's Encrypt certificate (if it's due) and redeploys it.
# Intended to be run periodically via cron -- certbot itself only
# renews when the cert is within 30 days of expiry, so running this
# daily is safe and normal.
#
# Example crontab entry (edit with `crontab -e`):
#   0 4 * * * /home/debian/AV1Bridge/scripts/renew-cert.sh >> /home/debian/AV1Bridge/renew.log 2>&1
set -e

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found -- run scripts/issue-cert.sh first."
  exit 1
fi
# shellcheck disable=SC1091
. ./.env

: "${DUCKDNS_DOMAIN:?Set DUCKDNS_DOMAIN in .env}"

# certbot stores every option used at issuance time (including the
# DuckDNS plugin credentials) in letsencrypt/renewal/<domain>.conf, so a
# plain `renew` reproduces the original DNS-01 challenge without needing
# any arguments repeated here.
echo "Checking for renewal (only renews if within 30 days of expiry)..."
docker run --rm \
  -v "$(pwd)/letsencrypt:/etc/letsencrypt" \
  infinityofspace/certbot_dns_duckdns:latest \
  renew --quiet

# The certbot container runs as root, so reclaim ownership before
# touching these files as the regular host user (needed whether or not
# a renewal actually happened this run).
sudo chown -R "$(id -u):$(id -g)" letsencrypt

# Only redeploy if the live cert is actually newer than what's currently
# in ./certs -- avoids restarting the stream on every no-op cron run.
if [ "letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem" -nt "certs/server.crt" ]; then
  echo "Certificate was renewed -- deploying and reloading the relay."
  cp "letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem" certs/server.crt
  cp "letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem" certs/server.key
  docker compose restart relay
else
  echo "No renewal needed yet."
fi
