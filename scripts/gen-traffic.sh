#!/usr/bin/env bash
# Generate a burst of mixed traffic against the in-cluster frontend so that
# metrics (Prometheus), logs (Loki), and traces (Tempo) all have real data
# to show for Phase 6's E2E verification.
#
# Usage:
#   kubectl -n dev port-forward svc/frontend 8080:80 &
#   ./scripts/gen-traffic.sh [BASE_URL] [N]
set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
N="${2:-80}"
PRODUCTS=(p1 p2 p3 p4 p5)

echo "==> Health check"
curl -s -o /dev/null -w "healthz: %{http_code}\n" "${BASE_URL}/healthz"

echo "==> Products check"
curl -s "${BASE_URL}/api/products" | head -c 400
echo

echo "==> Generating ${N} mixed requests..."
for i in $(seq 1 "${N}"); do
  product="${PRODUCTS[$((RANDOM % ${#PRODUCTS[@]}))]}"
  qty=$(( (RANDOM % 3) + 1 ))

  case $(( i % 4 )) in
    0)
      curl -s -o /dev/null -w "%{http_code} GET /api/products\n" "${BASE_URL}/api/products"
      ;;
    1)
      curl -s -o /dev/null -w "%{http_code} GET /api/orders\n" "${BASE_URL}/api/orders"
      ;;
    2)
      curl -s -o /dev/null -w "%{http_code} POST /api/orders (${product} x${qty})\n" \
        -X POST "${BASE_URL}/api/orders" \
        -H 'content-type: application/json' \
        -d "{\"productId\":\"${product}\",\"quantity\":${qty}}"
      ;;
    3)
      curl -s -o /dev/null -w "%{http_code} GET /healthz\n" "${BASE_URL}/healthz"
      ;;
  esac
done

echo "==> Done."
