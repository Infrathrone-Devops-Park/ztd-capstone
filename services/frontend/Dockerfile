# --- Stage 1: build the SPA ---
FROM node:20 AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

# --- Stage 2: serve with unprivileged Nginx ---
FROM nginxinc/nginx-unprivileged:alpine

USER root
# Clear fixable Alpine OS-package CVEs (e.g. CVE-2026-33630 in c-ares) that
# land in the base image over time — keeps the Trivy HIGH/CRITICAL gate green.
RUN apk update && apk upgrade --no-cache
RUN rm -f /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
USER nginx

ENV API_GATEWAY_URL=http://api-gateway:8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
