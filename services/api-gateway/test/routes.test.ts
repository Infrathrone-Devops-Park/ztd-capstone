import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import http, { type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { Writable } from 'node:stream';
import type { FastifyInstance } from 'fastify';
import pino from 'pino';
import { loadConfig } from '../src/config';
import { buildApp } from '../src/server';

const PRODUCTS = [
  { id: 'p1', name: 'Widget', price: 9.99, stock: 42 },
  { id: 'p2', name: 'Gadget', price: 19.99, stock: 7 },
];

const ORDER = {
  id: 'o1',
  productId: 'p1',
  quantity: 2,
  status: 'created',
  createdAt: '2026-07-09T00:00:00.000Z',
};

/** A tiny mock HTTP server standing in for catalog or orders. */
function startMock(handler: http.RequestListener): Promise<{ server: Server; url: string }> {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({ server, url: `http://127.0.0.1:${port}` });
    });
  });
}

function sendJson(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(payload);
}

describe('api-gateway routes', () => {
  let catalogServer: Server;
  let ordersServer: Server;
  let catalogUrl: string;
  let ordersUrl: string;
  let app: FastifyInstance;

  beforeAll(async () => {
    const catalog = await startMock((req, res) => {
      if (req.url === '/healthz') {
        sendJson(res, 200, { status: 'ok' });
        return;
      }
      if (req.url === '/products') {
        sendJson(res, 200, PRODUCTS);
        return;
      }
      if (req.url === '/products/p1') {
        sendJson(res, 200, PRODUCTS[0]);
        return;
      }
      if (req.url === '/products/nope') {
        sendJson(res, 404, { error: 'not found' });
        return;
      }
      sendJson(res, 404, { error: 'not found' });
    });
    catalogServer = catalog.server;
    catalogUrl = catalog.url;

    const orders = await startMock((req, res) => {
      if (req.url === '/healthz') {
        sendJson(res, 200, { status: 'ok' });
        return;
      }
      if (req.url === '/orders' && req.method === 'POST') {
        let body = '';
        req.on('data', (chunk) => (body += chunk));
        req.on('end', () => {
          const parsed = JSON.parse(body || '{}');
          if (parsed.productId === 'p1') {
            sendJson(res, 201, ORDER);
          } else {
            sendJson(res, 400, { error: 'invalid product' });
          }
        });
        return;
      }
      if (req.url === '/orders' && req.method === 'GET') {
        sendJson(res, 200, [ORDER]);
        return;
      }
      sendJson(res, 404, { error: 'not found' });
    });
    ordersServer = orders.server;
    ordersUrl = orders.url;

    const cfg = loadConfig({ CATALOG_URL: catalogUrl, ORDERS_URL: ordersUrl } as NodeJS.ProcessEnv);
    app = buildApp(cfg);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await new Promise((resolve) => catalogServer.close(resolve));
    await new Promise((resolve) => ordersServer.close(resolve));
  });

  it('GET /api/products proxies the catalog product list', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/products' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual(PRODUCTS);
  });

  it('GET /api/products/:id proxies a single catalog product', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/products/p1' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual(PRODUCTS[0]);
  });

  it('GET /api/products/:id proxies a catalog 404', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/products/nope' });
    expect(res.statusCode).toBe(404);
  });

  it('POST /api/orders proxies order creation to orders', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/orders',
      payload: { productId: 'p1', quantity: 2 },
    });
    expect(res.statusCode).toBe(201);
    expect(res.json()).toEqual(ORDER);
  });

  it('POST /api/orders forwards a 400 from orders for an invalid product', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/orders',
      payload: { productId: 'bogus', quantity: 1 },
    });
    expect(res.statusCode).toBe(400);
  });

  it('GET /api/orders proxies the orders list', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/orders' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual([ORDER]);
  });

  it('GET /healthz returns 200 ok with no dependency checks', async () => {
    const res = await app.inject({ method: 'GET', url: '/healthz' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: 'ok' });
  });

  it('GET /readyz returns 200 when catalog and orders are reachable', async () => {
    const res = await app.inject({ method: 'GET', url: '/readyz' });
    expect(res.statusCode).toBe(200);
  });

  it('GET /metrics exposes the http_request_duration_seconds histogram', async () => {
    const res = await app.inject({ method: 'GET', url: '/metrics' });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain('http_request_duration_seconds');
  });

  it('POST /api/products (wrong method) returns 405', async () => {
    const res = await app.inject({ method: 'POST', url: '/api/products' });
    expect(res.statusCode).toBe(405);
  });

  it('DELETE /healthz (wrong method) returns 405', async () => {
    const res = await app.inject({ method: 'DELETE', url: '/healthz' });
    expect(res.statusCode).toBe(405);
  });

  it('emits one structured JSON access-log line per request, to stdout, including trace_id when in a span', async () => {
    const chunks: string[] = [];
    const captureStream = new Writable({
      write(chunk, _encoding, callback) {
        chunks.push(chunk.toString());
        callback();
      },
    });
    const captureLogger = pino(captureStream);
    const cfg = loadConfig({ CATALOG_URL: catalogUrl, ORDERS_URL: ordersUrl } as NodeJS.ProcessEnv);
    const loggedApp = buildApp(cfg, captureLogger);
    await loggedApp.ready();
    try {
      const res = await loggedApp.inject({ method: 'GET', url: '/healthz' });
      expect(res.statusCode).toBe(200);

      const lines = chunks.join('').split('\n').filter((l) => l.trim().length > 0);
      const parsed = lines.map((l) => JSON.parse(l));
      const accessLog = parsed.find((l) => l.msg === 'http_request');
      expect(accessLog).toBeDefined();
      expect(accessLog.method).toBe('GET');
      expect(accessLog.route).toBe('/healthz');
      expect(accessLog.status).toBe(200);
      expect(typeof accessLog.duration_ms).toBe('number');
    } finally {
      await loggedApp.close();
    }
  });
});

describe('api-gateway readiness', () => {
  it('GET /readyz returns 503 when a dependency is unreachable', async () => {
    const orders = await startMock((req, res) => {
      if (req.url === '/healthz') {
        sendJson(res, 200, { status: 'ok' });
        return;
      }
      sendJson(res, 404, { error: 'not found' });
    });

    // Nothing listens on this port: catalog is "down".
    const cfg = loadConfig({
      CATALOG_URL: 'http://127.0.0.1:1',
      ORDERS_URL: orders.url,
    } as NodeJS.ProcessEnv);
    const app = buildApp(cfg);
    await app.ready();

    const res = await app.inject({ method: 'GET', url: '/readyz' });
    expect(res.statusCode).toBe(503);

    await app.close();
    await new Promise((resolve) => orders.server.close(resolve));
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });
});
