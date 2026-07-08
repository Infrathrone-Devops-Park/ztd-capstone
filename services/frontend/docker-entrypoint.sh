#!/bin/sh
set -eu

: "${API_GATEWAY_URL:=http://api-gateway:8080}"

envsubst '${API_GATEWAY_URL}' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/conf.d/default.conf

exec "$@"
