FROM caddy:2.10.2-builder AS builder

# Plugin versions pinned to what the running host image was built with
# (`caddy build-info`) — unpinned, the latest crowdsec-bouncer requires a
# newer caddy than the 2.10.2 pinned here and the build fails.
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.3 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http@v0.10.0 \
    --with github.com/hslatman/caddy-crowdsec-bouncer/layer4@v0.10.0

FROM caddy:2.10.2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy