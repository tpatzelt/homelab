FROM caddy:2.10.2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/zhangjiayin/caddy-geoip2 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --with github.com/hslatman/caddy-crowdsec-bouncer/layer4

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy