#!/bin/sh
set -eu

: "${API_GATEWAY_URL:=http://api-gateway:8080}"

# Derive the DNS resolver from the container's own resolv.conf so the same
# image works in Docker (embedded DNS 127.0.0.11) and in a Kubernetes pod
# (CoreDNS cluster IP). Fall back to Docker's embedded DNS if none found.
: "${RESOLVER_ADDR:=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)}"
: "${RESOLVER_ADDR:=127.0.0.11}"
export RESOLVER_ADDR

envsubst '${API_GATEWAY_URL} ${RESOLVER_ADDR}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/conf.d/default.conf

exec "$@"
