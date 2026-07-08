package main

import (
	"encoding/json"
	"net/http"
	"strings"
)

// writeJSON marshals v as JSON to w with the given status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// handleGetProducts responds with the full product catalog.
func handleGetProducts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, seedProducts)
}

// handleGetProductByID responds with a single product or 404.
func handleGetProductByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/products/")
	product, ok := findProduct(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	writeJSON(w, http.StatusOK, product)
}

// handleHealthz is the liveness probe: always 200, no dependency checks.
func handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz is the readiness probe. catalog has no external dependencies
// so it is always ready.
func handleReadyz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleProducts dispatches /products and /products/{id} based on path.
func handleProducts(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/products" {
		handleGetProducts(w, r)
		return
	}
	handleGetProductByID(w, r)
}

// newRouter wires all routes with the request-duration metrics middleware
// applied to application routes, and /metrics exposing the Prometheus
// registry.
func newRouter() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/products", withMetrics("/products", handleProducts))
	mux.HandleFunc("/products/", withMetrics("/products/:id", handleProducts))
	mux.HandleFunc("/healthz", withMetrics("/healthz", handleHealthz))
	mux.HandleFunc("/readyz", withMetrics("/readyz", handleReadyz))
	mux.Handle("/metrics", metricsHandler())

	return mux
}
