import express from 'express';
import { randomUUID } from 'node:crypto';
import { logger } from './logger.js';
import { audioRouter } from './routes-audio.js';
import { visualRouter } from './routes-visual.js';
import { renderRouter } from './routes-render.js';

const PORT = Number(process.env.PORT || 3000);
const MAX_CONCURRENCY = Number(process.env.RENDERER_MAX_CONCURRENCY || 1);
const app = express();

app.disable('x-powered-by');

app.use((req, res, next) => {
  req.correlationId = req.get('x-correlation-id') || randomUUID();
  res.set('x-correlation-id', req.correlationId);
  next();
});

app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', service: 'renderer' });
});

app.use(audioRouter);
app.use(visualRouter);
app.use(renderRouter);

app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

const server = app.listen(PORT, () => {
  // Job intake/processing is not implemented yet — this step only proves
  // the container, health endpoint, and FFmpeg capability (see
  // ffmpeg-capability-test.js). RENDERER_MAX_CONCURRENCY is reserved here
  // and will gate actual concurrent FFmpeg jobs once job processing is
  // implemented, so a free-tier VM is never handed more encodes than it
  // can absorb.
  logger.info('renderer listening', { port: PORT, max_concurrency: MAX_CONCURRENCY });
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    logger.info('shutdown signal received', { signal });
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}
