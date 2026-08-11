const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const client = require('prom-client');

const PORT = process.env.PORT || 3000;
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';

client.register.setDefaultLabels({ app: 'item-manager-backend' });
client.collectDefaultMetrics();

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status'],
});

const httpRequestDurationSeconds = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
});

const httpErrorsTotal = new client.Counter({
  name: 'http_errors_total',
  help: 'Total HTTP responses with a 4xx or 5xx status',
  labelNames: ['method', 'route', 'status'],
});

const httpActiveConnections = new client.Gauge({
  name: 'http_active_connections',
  help: 'In-flight HTTP requests',
});

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT) || 5432,
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD || 'postgres',
  database: process.env.PGDATABASE || 'itemsdb',
});

pool.on('error', (err) => {
  console.error('Unexpected error on idle database client', err);
});

const app = express();
app.use(cors({ origin: CORS_ORIGIN }));
app.use(express.json());

app.use((req, res, next) => {
  httpActiveConnections.inc();
  const endTimer = httpRequestDurationSeconds.startTimer();

  res.on('finish', () => {
    // req.route.path is only set once Express matches a route (e.g. /api/items/:id) —
    // falls back to the raw path for 404s so those still get counted somewhere.
    const route = req.route ? req.route.path : req.path;
    const labels = { method: req.method, route, status: res.statusCode };

    httpRequestsTotal.inc(labels);
    endTimer(labels);
    if (res.statusCode >= 400) {
      httpErrorsTotal.inc(labels);
    }
    httpActiveConnections.dec();
  });

  next();
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', client.register.contentType);
  res.end(await client.register.metrics());
});

app.get('/api/items', async (req, res) => {
  try {
    const result = await pool.query('SELECT id, name, description, created_at FROM items ORDER BY id');
    res.status(200).json(result.rows);
  } catch (err) {
    console.error('Failed to fetch items', err);
    res.status(500).json({ error: 'Failed to fetch items' });
  }
});

app.post('/api/items', async (req, res) => {
  const { name, description } = req.body || {};
  if (!name || typeof name !== 'string' || !name.trim()) {
    return res.status(400).json({ error: 'name is required' });
  }
  try {
    const result = await pool.query(
      'INSERT INTO items (name, description) VALUES ($1, $2) RETURNING id, name, description, created_at',
      [name.trim(), description || null]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    console.error('Failed to create item', err);
    res.status(500).json({ error: 'Failed to create item' });
  }
});

app.delete('/api/items/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) {
    return res.status(400).json({ error: 'invalid id' });
  }
  try {
    const result = await pool.query('DELETE FROM items WHERE id = $1', [id]);
    if (result.rowCount === 0) {
      return res.status(404).json({ error: 'item not found' });
    }
    res.status(204).send();
  } catch (err) {
    console.error('Failed to delete item', err);
    res.status(500).json({ error: 'Failed to delete item' });
  }
});

async function initDb(retries = 10, delayMs = 3000) {
  for (let attempt = 1; attempt <= retries; attempt += 1) {
    try {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS items (
          id SERIAL PRIMARY KEY,
          name TEXT NOT NULL,
          description TEXT,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      `);
      return;
    } catch (err) {
      if (attempt === retries) throw err;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

if (require.main === module) {
  initDb()
    .then(() => {
      app.listen(PORT, () => {
        console.log(`stanley-item-manager backend listening on port ${PORT}`);
      });
    })
    .catch((err) => {
      console.error('Failed to initialize database', err);
      process.exit(1);
    });
}

module.exports = { app, pool };
