import Fastify, { type FastifyInstance } from 'fastify';
import sensible from '@fastify/sensible';
import type pino from 'pino';
import { config as defaultConfig, type Config } from './config';
import { logger as defaultLogger, register, httpRequestDuration, currentTraceId } from './observability';
import { registerRoutes } from './routes';

const DEPENDENCY_CHECK_TIMEOUT_MS = 2000;

/** Best-effort reachability check against a downstream's /healthz. */
async function isReachable(baseUrl: string): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DEPENDENCY_CHECK_TIMEOUT_MS);
  try {
    const res = await fetch(`${baseUrl}/healthz`, { signal: controller.signal });
    return res.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Builds the Fastify app. Registers /healthz, /readyz (503 if catalog or
 * orders is unreachable), /metrics, and the /api/* proxy routes. Fastify's
 * built-in request logging is disabled in favor of a single structured JSON
 * access-log line per request (emitted here via onResponse) that includes
 * trace_id, so Loki correlation works and logging is never a no-op.
 */
export function buildApp(cfg: Config = defaultConfig, accessLogger: pino.Logger = defaultLogger): FastifyInstance {
  const app = Fastify({ logger: false });
  const logger = accessLogger;

  void app.register(sensible);

  app.addHook('onResponse', async (request, reply) => {
    const route = request.routeOptions.url ?? request.url;
    const durationSeconds = reply.elapsedTime / 1000;
    httpRequestDuration
      .labels(request.method, route, String(reply.statusCode))
      .observe(durationSeconds);

    const traceId = currentTraceId();
    const line: Record<string, unknown> = {
      msg: 'http_request',
      method: request.method,
      route,
      status: reply.statusCode,
      duration_ms: Number((reply.elapsedTime).toFixed(3)),
    };
    if (traceId) {
      line.trace_id = traceId;
    }
    logger.info(line);
  });

  app.route({
    method: 'GET',
    url: '/healthz',
    handler: async (_req, reply) => {
      reply.send({ status: 'ok' });
    },
  });
  app.route({
    method: ['POST', 'PUT', 'PATCH', 'DELETE'],
    url: '/healthz',
    handler: async (_req, reply) => {
      reply.header('allow', 'GET').code(405).send({ error: 'method not allowed' });
    },
  });

  app.route({
    method: 'GET',
    url: '/readyz',
    handler: async (_req, reply) => {
      const [catalogOk, ordersOk] = await Promise.all([
        isReachable(cfg.catalogUrl),
        isReachable(cfg.ordersUrl),
      ]);
      if (catalogOk && ordersOk) {
        reply.send({ status: 'ok' });
        return;
      }
      reply.code(503).send({
        status: 'unavailable',
        catalog: catalogOk ? 'ok' : 'unreachable',
        orders: ordersOk ? 'ok' : 'unreachable',
      });
    },
  });
  app.route({
    method: ['POST', 'PUT', 'PATCH', 'DELETE'],
    url: '/readyz',
    handler: async (_req, reply) => {
      reply.header('allow', 'GET').code(405).send({ error: 'method not allowed' });
    },
  });

  app.route({
    method: 'GET',
    url: '/metrics',
    handler: async (_req, reply) => {
      reply.header('content-type', register.contentType);
      reply.send(await register.metrics());
    },
  });
  app.route({
    method: ['POST', 'PUT', 'PATCH', 'DELETE'],
    url: '/metrics',
    handler: async (_req, reply) => {
      reply.header('allow', 'GET').code(405).send({ error: 'method not allowed' });
    },
  });

  registerRoutes(app, cfg);

  return app;
}
