#!/bin/sh
# Generates a self-signed certificate/key pair for the RTMPS listener.
#
# A self-signed cert is fine here: OBS's RTMPS client does not validate
# the certificate chain against a public CA the way a browser does, and
# the whole point of this leg is just to wrap the AV1 stream + publish
# credentials in TLS so they aren't sent in cleartext over the internet.
#
# Run this once, before the first `docker compose up`.
set -e

cd "$(dirname "$0")/.."
mkdir -p certs

if [ -f certs/server.key ] || [ -f certs/server.crt ]; then
  echo "certs/server.key or certs/server.crt already exists -- refusing to overwrite."
  echo "Delete them manually first if you really want to regenerate."
  exit 1
fi

openssl genrsa -out certs/server.key 2048
openssl req -new -x509 -sha256 \
  -key certs/server.key \
  -out certs/server.crt \
  -days 3650 \
  -subj "/CN=av1-relay"

chmod 600 certs/server.key
echo "Generated certs/server.key and certs/server.crt (valid 10 years)."
