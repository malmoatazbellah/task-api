const express = require('express');
const client = require('prom-client');

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequests = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
  registers: [register],
});

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2],
  registers: [register],
});

// ---------------------------------------------------------------------------
// App factory (exported so tests can create a fresh instance)
// ---------------------------------------------------------------------------
function createApp() {
  const app = express();
  app.use(express.json());

  // In-memory store. Each pod has its own copy (a good discussion point:
  // why is this a problem when you scale to 3 replicas?).
  const tasks = new Map();
  let nextId = 1;
  let ready = true;

  app.locals.setReady = (value) => {
    ready = value;
  };

  // Metrics middleware
  app.use((req, res, next) => {
    const end = httpDuration.startTimer();
    res.on('finish', () => {
      const route = req.route ? req.baseUrl + req.route.path : 'unmatched';
      const labels = { method: req.method, route, status: res.statusCode };
      httpRequests.inc(labels);
      end(labels);
    });
    next();
  });

  // ----- Platform endpoints -------------------------------------------------
  app.get('/', (req, res) => {
    res.json({
      service: 'task-api',
      version: process.env.APP_VERSION || 'dev',
      environment: process.env.APP_ENV || 'local',
      hostname: require('os').hostname(), // shows which pod answered
      message: process.env.WELCOME_MESSAGE || 'Hello from the DevOps capstone!',
      deployedBy: 'GitHub Actions',
    });
  });

  // Liveness: is the process alive?
  app.get('/does-not-exist', (req, res) => res.json({ status: 'ok' }));

  // Readiness: should this pod receive traffic?
  app.get('/readyz', (req, res) => {
    if (!ready) return res.status(503).json({ status: 'shutting-down' });
    res.json({ status: 'ready' });
  });

  app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });

  // ----- Tasks API ----------------------------------------------------------
  app.get('/api/tasks', (req, res) => {
    res.json([...tasks.values()]);
  });

  app.get('/api/tasks/:id', (req, res) => {
    const task = tasks.get(Number(req.params.id));
    if (!task) return res.status(404).json({ error: 'Task not found' });
    res.json(task);
  });

  app.post('/api/tasks', (req, res) => {
    const { title } = req.body || {};
    if (typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: '"title" is required' });
    }
    const task = {
      id: nextId++,
      title: title.trim(),
      done: false,
      createdAt: new Date().toISOString(),
    };
    tasks.set(task.id, task);
    res.status(201).json(task);
  });

  app.patch('/api/tasks/:id', (req, res) => {
    const task = tasks.get(Number(req.params.id));
    if (!task) return res.status(404).json({ error: 'Task not found' });
    const { title, done } = req.body || {};
    if (title !== undefined) task.title = String(title).trim();
    if (done !== undefined) task.done = Boolean(done);
    res.json(task);
  });

  app.delete('/api/tasks/:id', (req, res) => {
    if (!tasks.delete(Number(req.params.id))) {
      return res.status(404).json({ error: 'Task not found' });
    }
    res.status(204).end();
  });

  // 404 fallback
  app.use((req, res) => res.status(404).json({ error: 'Not found' }));

  return app;
}

module.exports = { createApp, register };
