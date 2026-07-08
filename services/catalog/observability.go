package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.opentelemetry.io/otel/trace"
)

// logger is the shared structured JSON logger used across the service for
// startup/shutdown and per-request access logs.
var logger = newLogger()

// httpRequestDuration is the shared HTTP request duration histogram exposed
// at /metrics as http_request_duration_seconds, labeled by method, route and
// status per the observability contract.
var httpRequestDuration = promauto.NewHistogramVec(
	prometheus.HistogramOpts{
		Name: "http_request_duration_seconds",
		Help: "Duration of HTTP requests in seconds.",
	},
	[]string{"method", "route", "status"},
)

// newLogger returns a structured JSON logger writing to stdout, including
// timestamp, level and msg on every line per the logging contract.
func newLogger() *slog.Logger {
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	return slog.New(handler)
}

// initTracerProvider configures an OTLP/HTTP trace exporter using
// OTEL_EXPORTER_OTLP_ENDPOINT (default http://localhost:4318) and
// OTEL_SERVICE_NAME, and installs it as the global tracer provider along
// with a W3C trace-context propagator.
func initTracerProvider(ctx context.Context) (*sdktrace.TracerProvider, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		endpoint = "http://localhost:4318"
	}
	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "catalog"
	}

	exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(endpoint))
	if err != nil {
		return nil, err
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp, nil
}

// initTracingBestEffort initializes the tracer provider but never aborts the
// process on failure. On error it logs a JSON warning and returns nil, leaving
// the default no-op tracer provider in place so the service keeps serving even
// when OTEL_EXPORTER_OTLP_ENDPOINT is malformed or unreachable.
func initTracingBestEffort(ctx context.Context) *sdktrace.TracerProvider {
	tp, err := initTracerProvider(ctx)
	if err != nil {
		logger.Warn("tracing disabled: failed to initialize tracer provider", "error", err.Error())
		return nil
	}
	return tp
}

// metricsHandler exposes the Prometheus registry (default process metrics +
// the http_request_duration_seconds histogram) at /metrics.
func metricsHandler() http.Handler {
	return promhttp.Handler()
}

// statusRecorder wraps http.ResponseWriter to capture the status code
// written by downstream handlers.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// getOnly enforces that a route only accepts GET, responding 405 with a JSON
// error (and an Allow header) for any other method. The 405 still flows
// through instrument so it is recorded and access-logged.
func getOnly(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		next(w, r)
	}
}

// instrument wraps a handler to (1) record request duration against
// httpRequestDuration labeled by method, route and status, and (2) emit one
// structured JSON access-log line per request to stdout including method,
// route (the template, not the raw path), status, duration_ms and — when a
// valid span context is present — the trace_id, enabling log<->trace
// correlation in Loki/Tempo.
func instrument(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next(rec, r)

		dur := time.Since(start)
		httpRequestDuration.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).
			Observe(dur.Seconds())

		attrs := []any{
			"method", r.Method,
			"route", route,
			"status", rec.status,
			"duration_ms", float64(dur.Microseconds()) / 1000.0,
		}
		if sc := trace.SpanContextFromContext(r.Context()); sc.HasTraceID() {
			attrs = append(attrs, "trace_id", sc.TraceID().String())
		}
		logger.Info("http_request", attrs...)
	}
}
