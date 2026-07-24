const request = require('supertest');
const { app, pool } = require('./index');

afterAll(async () => {
  await pool.end();
});

describe('GET /health', () => {
  it('returns 200 and status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});

describe('POST /api/items', () => {
  it('rejects a request with no name', async () => {
    const res = await request(app).post('/api/items').send({ description: 'no name here' });
    expect(res.statusCode).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  it('rejects a request with a blank name', async () => {
    const res = await request(app).post('/api/items').send({ name: '   ' });
    expect(res.statusCode).toBe(400);
  });
});

describe('DELETE /api/items/:id', () => {
  it('rejects a non-numeric id', async () => {
    const res = await request(app).delete('/api/items/not-a-number');
    expect(res.statusCode).toBe(400);
  });
});
