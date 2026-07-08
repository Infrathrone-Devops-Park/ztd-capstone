package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGetProducts(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/products", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var products []Product
	if err := json.Unmarshal(rec.Body.Bytes(), &products); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}

	if len(products) < 5 {
		t.Fatalf("expected at least 5 products, got %d", len(products))
	}
}

func TestGetProductByID_Found(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/products/p1", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var product Product
	if err := json.Unmarshal(rec.Body.Bytes(), &product); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}

	if product.ID != "p1" {
		t.Fatalf("expected id p1, got %s", product.ID)
	}
}

func TestGetProductByID_NotFound(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/products/nope", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}

	if body["error"] != "not found" {
		t.Fatalf("expected error 'not found', got %q", body["error"])
	}
}

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	if !strings.Contains(rec.Body.String(), "ok") {
		t.Fatalf("expected body to contain 'ok', got %q", rec.Body.String())
	}
}

func TestReadyz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestPostProductsMethodNotAllowed(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/products", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", rec.Code)
	}
	if got := rec.Header().Get("Allow"); got != http.MethodGet {
		t.Fatalf("expected Allow header GET, got %q", got)
	}
}

// TestBestEffortTracingBadEndpoint verifies that a bogus OTLP endpoint does
// not crash startup: initTracingBestEffort returns without aborting the
// process, and the router still serves /healthz with 200. (initTracingBestEffort
// swallows any init error and returns nil rather than calling os.Exit.)
func TestBestEffortTracingBadEndpoint(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://%%%bad-endpoint")

	tp := initTracingBestEffort(context.Background())
	if tp != nil {
		// If the SDK tolerated the endpoint and built a provider, clean it up.
		_ = tp.Shutdown(context.Background())
	}

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected /healthz 200 even with bad OTLP endpoint, got %d", rec.Code)
	}
}

func TestMetrics(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()

	newRouter().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	if !strings.Contains(rec.Body.String(), "http_request_duration_seconds") {
		t.Fatalf("expected metrics body to contain http_request_duration_seconds")
	}
}
