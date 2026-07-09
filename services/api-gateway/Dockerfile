# syntax=docker/dockerfile:1

# ---- Stage 1: build ----
FROM --platform=linux/amd64 node:20 AS build
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Prune dev dependencies out of node_modules for the runtime stage.
RUN npm prune --omit=dev

# ---- Stage 2: runtime ----
FROM --platform=linux/amd64 node:20-slim AS runtime
# Pull in all available Debian security updates so the runtime image does not
# ship fixable OS-package CVEs (the Trivy image gate in ci.yml/pr-checks
# blocks on HIGH/CRITICAL). Anything left after this is genuinely unfixable
# (no upstream Debian patch yet) and is enumerated, with justification, in
# the repo-root .trivyignore.
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get -y --purge autoremove \
    && rm -rf /var/lib/apt/lists/*
# The runtime only runs `node dist/index.js` — it never invokes the npm CLI.
# node:20-slim bundles the npm CLI (/usr/local/lib/node_modules/npm), which
# drags in a large tree of npm-internal deps (tar, minimatch, glob,
# cross-spawn, sigstore, ...) that carry their own CVEs and are impossible to
# patch independently of the base image. Removing it shrinks the runtime
# attack surface and drops those findings entirely (they aren't our app deps).
RUN rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/bin/npm \
    /usr/local/bin/npx
WORKDIR /app
ENV NODE_ENV=production

COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

USER node

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz', res => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "dist/index.js"]
