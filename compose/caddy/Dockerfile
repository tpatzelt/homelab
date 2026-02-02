# Custom Caddy build with Cloudflare DNS module
# Required for ACME DNS-01 challenge (wildcard certs without exposing port 80)
FROM caddy:2.10.2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy