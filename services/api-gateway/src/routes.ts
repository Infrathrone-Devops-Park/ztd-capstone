import type { FastifyInstance, FastifyReply, FastifyRequest, HTTPMethods } from 'fastify';
import type { Config } from './config';

const DOWNSTREAM_TIMEOUT_MS = 5000;

/** Fetches a URL with a bounded timeout, best-effort. */
async function fetchWithTimeout(url: string, init: RequestInit = {}): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DOWNSTREAM_TIMEOUT_MS);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** Proxies a downstream JSON response onto the Fastify reply verbatim. */
async function relay(reply: FastifyReply, upstream: Response): Promise<void> {
  const contentType = upstream.headers.get('content-type') ?? 'application/json';
  const body = await upstream.text();
  reply.code(upstream.status);
  reply.header('content-type', contentType);
  reply.send(body);
}

/** Sends a 502 when a downstream call fails outright (network/timeout). */
function sendBadGateway(reply: FastifyReply, dependency: string, err: unknown): void {
  reply.code(502).send({
    error: `upstream ${dependency} unreachable`,
    detail: err instanceof Error ? err.message : String(err),
  });
}

/** Sends a 405 with an Allow header for a method not supported on a route. */
function methodNotAllowed(allow: string) {
  return async (_req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    reply.header('allow', allow).code(405).send({ error: 'method not allowed' });
  };
}

/**
 * Registers the /api/* proxy routes onto the Fastify app. Every route
 * enforces its allowed method (405 for anything else) per the lessons
 * learned reviewing catalog. Downstream calls use global fetch (undici),
 * which OpenTelemetry's auto-instrumentation patches to propagate the W3C
 * traceparent header automatically when tracing is initialized.
 */
export function registerRoutes(app: FastifyInstance, cfg: Config): void {
  const otherMethods = (allowed: HTTPMethods): HTTPMethods[] =>
    (['GET', 'POST', 'PUT', 'PATCH', 'DELETE'] as HTTPMethods[]).filter((m) => m !== allowed);

  // GET /api/products -> catalog GET /products
  app.route({
    method: 'GET',
    url: '/api/products',
    handler: async (_req, reply) => {
      try {
        const upstream = await fetchWithTimeout(`${cfg.catalogUrl}/products`);
        await relay(reply, upstream);
      } catch (err) {
        sendBadGateway(reply, 'catalog', err);
      }
    },
  });
  app.route({
    method: otherMethods('GET'),
    url: '/api/products',
    handler: methodNotAllowed('GET'),
  });

  // GET /api/products/:id -> catalog GET /products/{id}
  app.route({
    method: 'GET',
    url: '/api/products/:id',
    handler: async (req, reply) => {
      const { id } = req.params as { id: string };
      try {
        const upstream = await fetchWithTimeout(`${cfg.catalogUrl}/products/${encodeURIComponent(id)}`);
        await relay(reply, upstream);
      } catch (err) {
        sendBadGateway(reply, 'catalog', err);
      }
    },
  });
  app.route({
    method: otherMethods('GET'),
    url: '/api/products/:id',
    handler: methodNotAllowed('GET'),
  });

  // /api/orders supports both GET (list) and POST (create); every other
  // method gets a single 405 guard registered below.
  app.route({
    method: 'POST',
    url: '/api/orders',
    handler: async (req, reply) => {
      try {
        const upstream = await fetchWithTimeout(`${cfg.ordersUrl}/orders`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(req.body ?? {}),
        });
        await relay(reply, upstream);
      } catch (err) {
        sendBadGateway(reply, 'orders', err);
      }
    },
  });

  app.route({
    method: 'GET',
    url: '/api/orders',
    handler: async (_req, reply) => {
      try {
        const upstream = await fetchWithTimeout(`${cfg.ordersUrl}/orders`);
        await relay(reply, upstream);
      } catch (err) {
        sendBadGateway(reply, 'orders', err);
      }
    },
  });

  app.route({
    method: ['PUT', 'PATCH', 'DELETE'],
    url: '/api/orders',
    handler: methodNotAllowed('GET, POST'),
  });
}
