#!/bin/sh
# One-time Let's Encrypt certificate issuance using the DNS-01 challenge
# against DuckDNS. This needs NO inbound port at all -- it works purely
# by setting a TXT record on your DuckDNS domain via their API, which is
# exactly why it works even though this VPS can't choose its own
# global-facing port number (HTTP-01/TLS-ALPN-01 would need a specific
# global port 80/443, which isn't available here; DNS-01 sidesteps that
# entirely).
#
# Run this once. For renewals, use scripts/renew-cert.sh instead.
set -e

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found -- copy .env.example to .env and fill in DUCKDNS_DOMAIN, DUCKDNS_TOKEN, CERT_EMAIL first."
  exit 1
fi
# shellcheck disable=SC1091
. ./.env

: "${DUCKDNS_DOMAIN:?Set DUCKDNS_DOMAIN in .env (e.g. av1bridge.duckdns.org)}"
: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN in .env (from your DuckDNS dashboard)}"
: "${CERT_EMAIL:?Set CERT_EMAIL in .env (contact address for Let's Encrypt expiry notices)}"

mkdir -p letsencrypt

echo "Requesting a certificate for ${DUCKDNS_DOMAIN} via DNS-01..."
docker run --rm \
  -v "$(pwd)/letsencrypt:/etc/letsencrypt" \
  infinityofspace/certbot_dns_duckdns:latest \
  certonly \
  --non-interactive --agree-tos \
  --email "${CERT_EMAIL}" \
  --preferred-challenges dns \
  --authenticator dns-duckdns \
  --dns-duckdns-token "${DUCKDNS_TOKEN}" \
  --dns-duckdns-propagation-seconds 60 \
  -d "${DUCKDNS_DOMAIN}"

echo "Deploying certificate into ./certs and reloading the relay..."
# The certbot container runs as root, so everything it wrote under
# ./letsencrypt is root-owned on the host. Reclaim it so this script
# (and cron, for renew-cert.sh) can read it without sudo going forward.
sudo chown -R "$(id -u):$(id -g)" letsencrypt
cp "letsencrypt/live/${DUCKDNS_DOMAIN}/fullchain.pem" certs/server.crt
cp "letsencrypt/live/${DUCKDNS_DOMAIN}/privkey.pem" certs/server.key
docker compose restart relay

echo "Done. OBS should now connect to rtmps://${DUCKDNS_DOMAIN}:<your INGEST_PORT>/home"
echo "without any certificate warning."
echo
echo "Reminder: Let's Encrypt certs expire in 90 days. Set up a cron job"
echo "for scripts/renew-cert.sh -- see README.md."
