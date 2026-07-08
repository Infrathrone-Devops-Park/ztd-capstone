import { initTracing, shutdownTracing, logger } from './observability';

/**
 * Process entrypoint. Starts the OTel NodeSDK BEFORE the Fastify app module
 * is ever required, so http/undici auto-instrumentation can patch the
 * runtime ahead of anything capturing references to it. ./server is
 * imported dynamically (not via a static `import`) specifically so its
 * require() happens after initTracing() runs, not hoisted before it.
 */
async function main(): Promise<void> {
  initTracing();

  const { buildApp } = await import('./server');
  const { config } = await import('./config');

  const app = buildApp(config);

  try {
    await app.listen({ host: '0.0.0.0', port: config.port });
    logger.info({ msg: 'api-gateway listening', port: config.port });
  } catch (err) {
    logger.error({ msg: 'failed to start server', error: err instanceof Error ? err.message : String(err) });
    process.exit(1);
  }

  const shutdown = (signal: string) => {
    logger.info({ msg: 'shutting down', signal });
    void app
      .close()
      .then(() => shutdownTracing())
      .then(() => process.exit(0))
      .catch((err) => {
        logger.error({ msg: 'graceful shutdown failed', error: err instanceof Error ? err.message : String(err) });
        process.exit(1);
      });
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
