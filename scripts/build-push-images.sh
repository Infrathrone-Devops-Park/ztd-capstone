#!/usr/bin/env bash
# Build + push the four ztd-capstone service images to ECR as linux/amd64.
#
# Usage:
#   AWS_PROFILE=infrathrone-new ./scripts/build-push-images.sh [TAG]
#
# TAG defaults to sha-<current-git-short-sha>. All four images share the
# same tag. Host may be arm64 (e.g. Apple Silicon); the cluster nodes are
# amd64, so every image is cross-built with buildx --platform linux/amd64.
set -euo pipefail

REGISTRY="514422154867.dkr.ecr.ap-south-1.amazonaws.com"
REGION="ap-south-1"
SERVICES=(frontend api-gateway orders catalog)

TAG="${1:-sha-$(git rev-parse --short HEAD)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Tag: ${TAG}"
echo "==> Registry: ${REGISTRY}"

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"

BUILDER_NAME="ztd-capstone-builder"
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  echo "==> Creating buildx builder ${BUILDER_NAME}..."
  docker buildx create --name "${BUILDER_NAME}" --use
else
  docker buildx use "${BUILDER_NAME}"
fi

for svc in "${SERVICES[@]}"; do
  image="${REGISTRY}/ztd-capstone/${svc}:${TAG}"
  echo "==> Building + pushing ${image} (linux/amd64) from services/${svc}..."
  docker buildx build \
    --platform linux/amd64 \
    -t "${image}" \
    --push \
    "${REPO_ROOT}/services/${svc}"
done

echo "==> Done. Pushed tag: ${TAG}"
for svc in "${SERVICES[@]}"; do
  echo "    ${REGISTRY}/ztd-capstone/${svc}:${TAG}"
done
