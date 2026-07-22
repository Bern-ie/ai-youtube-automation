import express from 'express';
import { randomUUID } from 'node:crypto';
import { logger } from './logger.js';
import { testEchoSchema } from './schema.js';

const PORT = Number(process.env.PORT || 3000);
const app = express();

app.disable('x-powered-by');
app.use(express.json({ limit: '1mb' }));

app.use((req, res, next) => {
  req.correlationId = req.get('x-correlation-id') || randomUUID();
  res.set('x-correlation-id', req.correlationId);
  const start = Date.now();
  res.on('finish', () => {
    logger.info('request completed', {
      correlation_id: req.correlationId,
      method: req.method,
      path: req.path,
      status: res.statusCode,
      duration_ms: Date.now() - start,
    });
  });
  next();
});

app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', service: 'approval-api' });
});

// Development/test endpoint only — proves identifier propagation and
// strict validation. Does not persist anything; the real approval-domain
// logic lands in a later step.
app.post('/internal/test/echo-identifiers', (req, res) => {
  const parsed = testEchoSchema.safeParse(req.body);
  if (!parsed.success) {
    logger.warn('validation failed', {
      correlation_id: req.correlationId,
      issues: parsed.error.issues,
    });
    res.status(400).json({ error: 'validation_failed', issues: parsed.error.issues });
    return;
  }

  const { channel_id, content_project_id, workflow_run_id, correlation_id } = parsed.data;
  res.status(200).json({
    channel_id,
    content_project_id,
    workflow_run_id,
    correlation_id: correlation_id || req.correlationId,
    received_at: new Date().toISOString(),
  });
});

app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, _next) => {
  logger.error('unhandled request error', {
    correlation_id: req.correlationId,
    error: err.message,
  });
  res.status(400).json({ error: 'bad_request' });
});

const server = app.listen(PORT, () => {
  logger.info('approval-api listening', { port: PORT });
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info('shutdown signal received', { signal });
    server.close(() => {
      logger.info('server closed');
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}
