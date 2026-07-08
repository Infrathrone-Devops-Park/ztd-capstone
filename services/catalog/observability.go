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
)

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

// withMetrics wraps a handler, recording request duration against
// httpRequestDuration labeled by method, route and status.
func withMetrics(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next(rec, r)

		httpRequestDuration.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).
			Observe(time.Since(start).Seconds())
	}
}
