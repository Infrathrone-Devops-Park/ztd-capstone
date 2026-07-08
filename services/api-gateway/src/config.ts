/**
 * Environment-only configuration (12-factor). No secrets in code; every
 * value has a sane local-dev default matching .env.example.
 */
export interface Config {
  port: number;
  catalogUrl: string;
  ordersUrl: string;
  otelServiceName: string;
  otelExporterOtlpEndpoint: string;
}

/**
 * Builds a Config from an environment-like record. Pure function (no
 * process.env side effects) so tests can construct isolated configs
 * pointing at mock downstreams without mutating global state.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    port: Number(env.PORT ?? '8080'),
    catalogUrl: env.CATALOG_URL ?? 'http://catalog:8080',
    ordersUrl: env.ORDERS_URL ?? 'http://orders:8080',
    otelServiceName: env.OTEL_SERVICE_NAME ?? 'api-gateway',
    otelExporterOtlpEndpoint: env.OTEL_EXPORTER_OTLP_ENDPOINT ?? 'http://localhost:4318',
  };
}

/** Default process-wide config, read from the real environment. */
export const config: Config = loadConfig();
