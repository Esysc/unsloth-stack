# Build Caddy with required plugins using official builder image
FROM caddy:2-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/greenpau/caddy-security \
    --with github.com/greenpau/caddy-trace

# Runtime image
FROM caddy:2-alpine

# Runtime tools used by entrypoint for user bootstrap and logo fetch
RUN apk add --no-cache bash openssl jq curl

# Replace default Caddy binary with plugin-enabled build
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose ports
EXPOSE 80 443

# Use custom entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
