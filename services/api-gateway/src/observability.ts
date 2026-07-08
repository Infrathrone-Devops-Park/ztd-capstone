import pino from 'pino';
import { Registry, Histogram, collectDefaultMetrics } from 'prom-client';
import { trace } from '@opentelemetry/api';

/**
 * logger is the shared structured JSON logger used for startup/shutdown
 * messages and per-request access logs. pino writes one JSON object per
 * line to stdout by default, satisfying the logging contract.
 */
export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  base: undefined,
});

/**
 * register is the dedicated Prometheus registry for this service, exposed
 * verbatim at GET /metrics. Default process metrics are collected onto it.
 */
export const register = new Registry();
collectDefaultMetrics({ register });

/**
 * httpRequestDuration is the HTTP request duration histogram required by
 * the metrics contract: http_request_duration_seconds, labeled by method,
 * route (the route TEMPLATE, never the raw path/id, to avoid cardinality
 * blowup) and status.
 */
export const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds.',
  labelNames: ['method', 'route', 'status'] as const,
  registers: [register],
});

/** Returns the active span's trace id as a hex string, if any. */
export function currentTraceId(): string | undefined {
  const span = trace.getActiveSpan();
  const spanContext = span?.spanContext();
  if (spanContext && trace.isSpanContextValid(spanContext)) {
    return spanContext.traceId;
  }
  return undefined;
}

let sdkHandle: { shutdown: () => Promise<void> } | undefined;

/**
 * Starts the OpenTelemetry NodeSDK (OTLP/HTTP trace exporter + http/undici
 * auto-instrumentation for W3C traceparent propagation) BEST-EFFORT: any
 * failure (malformed endpoint, missing packages, unreachable collector) is
 * logged and swallowed so the service still serves /healthz and the proxy
 * routes. Must be called before ./server is imported so instrumentation can
 * patch http/fetch ahead of any module capturing references to them.
 */
export function initTracing(): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { NodeSDK } = require('@opentelemetry/sdk-node');
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { Resource } = require('@opentelemetry/resources');
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { ATTR_SERVICE_NAME } = require('@opentelemetry/semantic-conventions');

    const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4318';
    const serviceName = process.env.OTEL_SERVICE_NAME ?? 'api-gateway';

    const exporter = new OTLPTraceExporter({
      url: `${endpoint.replace(/\/$/, '')}/v1/traces`,
    });

    const sdk = new NodeSDK({
      resource: new Resource({ [ATTR_SERVICE_NAME]: serviceName }),
      traceExporter: exporter,
      instrumentations: [getNodeAutoInstrumentations()],
    });

    sdk.start();
    sdkHandle = sdk;
    logger.info({ msg: 'tracing initialized', endpoint, serviceName });
  } catch (err) {
    logger.warn({
      msg: 'tracing disabled: failed to initialize tracer provider',
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

/** Best-effort graceful shutdown of the tracer provider, if started. */
export async function shutdownTracing(): Promise<void> {
  if (!sdkHandle) {
    return;
  }
  try {
    await sdkHandle.shutdown();
  } catch (err) {
    logger.warn({
      msg: 'error shutting down tracer provider',
      error: err instanceof Error ? err.message : String(err),
    });
  }
}
