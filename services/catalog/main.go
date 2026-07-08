package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Support a lightweight healthcheck mode for the container HEALTHCHECK
	// instruction, since the distroless base image has no shell or curl.
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		runHealthcheck(port)
		return
	}

	logger := newLogger()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tp, err := initTracerProvider(ctx)
	if err != nil {
		logger.Error("failed to initialize tracer provider", "error", err.Error())
		os.Exit(1)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(shutdownCtx); err != nil {
			logger.Error("failed to shut down tracer provider", "error", err.Error())
		}
	}()

	handler := otelhttp.NewHandler(newRouter(), "catalog")

	srv := &http.Server{
		Addr:    ":" + port,
		Handler: handler,
	}

	go func() {
		logger.Info("starting catalog service", "port", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server error", "error", err.Error())
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "error", err.Error())
	}
}

// runHealthcheck performs a local GET /healthz and exits 0 on success, 1
// otherwise. Used by the container HEALTHCHECK instruction.
func runHealthcheck(port string) {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		os.Exit(1)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		os.Exit(1)
	}
	os.Exit(0)
}
