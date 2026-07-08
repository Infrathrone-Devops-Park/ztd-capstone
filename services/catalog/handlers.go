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

// newRouter wires all routes. Every route is GET-only (405 otherwise) and is
// wrapped with instrument for request-duration metrics + per-request JSON
// access logging. /metrics exposes the Prometheus registry.
func newRouter() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/products", instrument("/products", getOnly(handleProducts)))
	mux.HandleFunc("/products/", instrument("/products/:id", getOnly(handleProducts)))
	mux.HandleFunc("/healthz", instrument("/healthz", getOnly(handleHealthz)))
	mux.HandleFunc("/readyz", instrument("/readyz", getOnly(handleReadyz)))
	mux.HandleFunc("/metrics", instrument("/metrics", getOnly(metricsHandler().ServeHTTP)))

	return mux
}
