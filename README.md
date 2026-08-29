# AV1Bridge

Accepts an AV1 stream (over RTMPS) from a low-upload-bandwidth home
connection, transcodes it in software to H.264 on a cloud relay server
with plenty of bandwidth, and pushes the result to Twitch in real time.

```
[home: OBS, SVT-AV1] --RTMPS(auth)--> [cloud: MediaMTX + ffmpeg] --RTMP--> [Twitch]
```

AV1 encodes noticeably more efficiently than H.264 at the same visual
quality, which makes it a good fit for the home→cloud leg when upload
bandwidth is the bottleneck. Twitch does not (yet) accept AV1 ingest,
so the cloud relay decodes the incoming AV1 and re-encodes it to H.264
before forwarding it on — all in software, so both legs can run on a
cloud instance with only a CPU (no GPU) allocated to it.

Only **one** inbound port is required on the relay: the RTMPS ingest
port. The push to Twitch is outbound, so it needs no firewall rule at
all — this was designed around a shared-IPv4 cloud plan that only
allows two open ports besides SSH.

## Files in this project

| File                          | Purpose                                                         |
|-------------------------------|------------------------------------------------------------------|
| `Dockerfile`                  | Builds one image containing both MediaMTX and FFmpeg              |
| `mediamtx.yml`                | Server config: RTMPS ingest, auth, the AV1→H.264 transcode hook   |
| `docker-compose.yml`          | Runs the image, publishes exactly one port                        |
| `.env.example`                | Template for secrets/tuning values — copy to `.env`               |
| `scripts/generate-certs.sh`   | Self-signed cert generator — local testing fallback only (not for OBS) |
| `scripts/issue-cert.sh`       | One-time Let's Encrypt cert issuance via DuckDNS DNS-01                |
| `scripts/renew-cert.sh`       | Cron-friendly cert renewal + redeploy                              |
| `scripts/verify-setup.sh`     | Post-deploy sanity checks (codecs, stream status, live speed=)    |

## 1. Deploy

Recommended host OS: **Debian 13 (Trixie)**. Ubuntu 26.04 works
identically. AlmaLinux/Rocky/CentOS Stream 10 also work, but SELinux is
enforcing by default and may need an extra policy adjustment for the
container's published port. Alpine can run Docker but is less common
as a Docker *host* OS, so expect rougher edges. FreeBSD/OpenBSD cannot
run Docker at all and are not supported by this setup.

```bash
# Install Docker (Debian/Ubuntu)
curl -fsSL https://get.docker.com | sh

# Clone this repo onto the server, then:
cd AV1Bridge
cp .env.example .env
nano .env   # fill in TWITCH_STREAM_KEY, MTX_PUBLISH_USER, MTX_PUBLISH_PASS,
            # DUCKDNS_DOMAIN, DUCKDNS_TOKEN, CERT_EMAIL

./scripts/issue-cert.sh       # one-time: gets a real Let's Encrypt cert via DuckDNS DNS-01

docker compose up -d --build
./scripts/verify-setup.sh     # confirms AV1 decode/H.264 encode support, then tails logs
```

### About the TLS certificate

OBS's RTMPS client validates the server certificate against the system's
trusted CA list, with **no option to accept a self-signed certificate**
(unlike browsers, there's no "proceed anyway" button). A self-signed
cert (as older versions of this README suggested via
`scripts/generate-certs.sh`) will therefore always fail in OBS with
*"The RTMP server sent an invalid SSL certificate."*

`scripts/issue-cert.sh` solves this with a real Let's Encrypt
certificate, obtained via the **DNS-01 challenge** against a free
[DuckDNS](https://www.duckdns.org) subdomain. This matters specifically
because DNS-01 needs **no inbound port at all** — it proves domain
ownership via a DNS TXT record instead of an HTTP request, which is the
only option that works on a shared-IPv4 VPS where you can't choose
which port number gets mapped to you (HTTP-01/TLS-ALPN-01 both require
the *global* port to be exactly 80 or 443, which such plans don't let
you pick).

Prerequisites before running it:
1. Register a free subdomain at duckdns.org (e.g. `av1bridge.duckdns.org`)
   and point it at your VPS's public IP.
2. Put that domain, your DuckDNS token, and a contact email into `.env`
   (`DUCKDNS_DOMAIN`, `DUCKDNS_TOKEN`, `CERT_EMAIL`).

Since Let's Encrypt can't issue certificates for bare IP addresses,
**OBS must connect using the domain name, not the server's IP** — see
step 3 below.

Certificates expire after 90 days. Set up a cron job to renew them
automatically. `renew-cert.sh` calls `sudo` internally (to reclaim
ownership of the files certbot's container writes as root), so it
needs to run from **root's** crontab, not your regular user's:

```bash
sudo crontab -e
# add:
0 4 * * * /home/debian/AV1Bridge/scripts/renew-cert.sh >> /home/debian/AV1Bridge/renew.log 2>&1
```

(If you instead add this to your own user's crontab, the `sudo` call
inside the script will hang waiting for a password that never comes,
since cron has no terminal to prompt on.)

`scripts/generate-certs.sh` (self-signed) is kept in the repo only as a
fallback for local testing with a client that isn't OBS (e.g. `ffplay`
or `ffmpeg` don't validate certs by default) — it will not work for an
actual OBS→relay connection.

## 2. Firewall — open exactly one port

Debian/Ubuntu (ufw):

```bash
ufw allow 22/tcp          # SSH
ufw allow 1936/tcp        # RTMPS ingest (match INGEST_PORT in .env)
ufw enable
```

AlmaLinux/Rocky/CentOS Stream (firewalld):

```bash
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --permanent --add-port=1936/tcp
firewall-cmd --reload
```

Also open port 1936 (or whatever you set `INGEST_PORT` to) in your
cloud provider's own network/security-group panel — on a shared-IPv4
plan, that panel is usually where the "2 ports besides SSH" limit is
actually enforced, not just the OS-level firewall.

**The second port your plan allows is left completely unused.** The
MediaMTX API (`mediamtx.yml`: `apiAddress 127.0.0.1:9997`) is bound to
loopback only, so it never needs a published port — for debugging,
reach it over an SSH tunnel instead:

```bash
ssh -L 9997:127.0.0.1:9997 <user>@<server>
# then, on your own machine:
curl http://127.0.0.1:9997/v3/paths/list
```

That keeps the open-port count at exactly one, and leaves your spare
port free for whatever you need later.

**If your provider uses NAT-style port forwarding** (a shared-IPv4 plan
where you request an internal port and it assigns you an arbitrary
*global* port, e.g. internal `1936` mapped to global `3163`): that's
fine, RTMP/RTMPS doesn't care what port number it runs on. Just use
whatever global port you were assigned when telling OBS where to
connect (see step 3), and be aware this is exactly the situation where
HTTP-01/TLS-ALPN-01 certificate validation would fail — it's why
`scripts/issue-cert.sh` uses the DNS-01 challenge instead (see below).

## 3. Configure OBS (home side)

Requires OBS 29+ for native AV1 encoding (Enhanced RTMP output).

- **Settings → Output → Streaming**
  - Encoder: `SVT-AV1` (software; the only open AV1 encoder fast enough
    for real-time use — `libaom` AV1 is not realtime-capable)
  - Rate Control: CBR
  - Bitrate: ~70–80% of your actual measured upload speed, leaving
    headroom for network jitter
  - Keyframe Interval: 2s
- **Settings → Stream**
  - Service: `Custom...`
  - Server: `rtmps://<your-DUCKDNS_DOMAIN>:<your global/mapped INGEST_PORT>/home`
    (use the domain name, not the server's IP — the certificate is
    issued for the domain, and OBS will reject a domain/cert mismatch
    just as strictly as it rejects a self-signed one)
  - Stream Key: leave blank
  - If OBS shows a "Use Authentication" option: enable it and enter the
    `MTX_PUBLISH_USER` / `MTX_PUBLISH_PASS` values from your `.env`
  - If it doesn't show that option, append the credentials to the
    server URL instead:
    `rtmps://<your-DUCKDNS_DOMAIN>:<port>/home?user=<MTX_PUBLISH_USER>&pass=<MTX_PUBLISH_PASS>`
  - With a real Let's Encrypt certificate, OBS should connect with no
    certificate warning at all.

## 4. Tuning procedure (360p60 → 1080p30)

You'll need to find the ceiling experimentally — here's the loop:

1. Start at the `.env` defaults (a safe 360p60-ish baseline:
   `OUTPUT_VIDEO_BITRATE=2500k`). Set OBS's output resolution/fps to
   match, then start streaming.
2. Watch `docker compose logs -f relay`. FFmpeg prints a `speed=`
   value — as long as it stays at or above `1.0x`, the cloud CPU is
   keeping up in real time. Below `1.0x` means growing latency and
   buffering.
3. Watch cloud CPU with `htop`/`top` alongside it.
4. If `speed=` has headroom, raise `OUTPUT_VIDEO_BITRATE` and/or the
   resolution/fps in `.env` (matching on the OBS side), then:
   ```bash
   docker compose up -d   # picks up the new .env values, restarts ffmpeg via runOnReady
   ```
5. Repeat until `speed=` sits right around `1.0x` with a small margin.
   Software `libx264` encoding is almost always the bottleneck before
   `dav1d` decoding is, so if you run out of headroom, try
   `X264_PRESET=superfast` or `ultrafast` in `.env` before giving up
   resolution/fps.
6. Separately, confirm your home upload isn't the limiter: OBS's Stats
   dock shows dropped frames due to network congestion — that's a
   home-bandwidth problem, not a cloud-CPU one.

`scripts/verify-setup.sh` automates steps 1–2 of this check (codec
sanity + tailing the live `speed=` output) each time you redeploy.

## Notes

- The RTMPS certificate is self-signed on purpose — OBS's RTMP client
  doesn't validate certs against a public CA the way a browser does,
  so there's no benefit to a real one here; it only needs to encrypt
  the home→cloud leg.
- Your Twitch stream key never leaves the cloud container — it's only
  used on the outbound `runOnReady` push, which is why no inbound
  Twitch-facing port is ever needed.
- If your OBS build sends Opus audio instead of AAC under some
  Enhanced RTMP configurations, `-c:a aac` in `mediamtx.yml`'s
  `runOnReady` already re-encodes it. If you confirm it's AAC already,
  switch that to `-c:a copy` to save a little CPU.
- Twitch's non-partner bitrate cap is ~6000 Kbps — keep
  `OUTPUT_VIDEO_BITRATE` under that regardless of what your tuning finds.

## License

Licensed under the [GNU General Public License v3.0](LICENSE).

## Attribution

The design and implementation of this project (architecture, Docker
setup, MediaMTX/FFmpeg configuration, and this documentation) were
created by Claude Sonnet 5, an AI model developed by Anthropic, in
conversation with the repository owner.
