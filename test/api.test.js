const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const pkg = require('../package.json');

let serverProcess;
const FAIL_TRIGGER = path.resolve(__dirname, '.fail-next-connection');

before(async () => {
  try {
    fs.unlinkSync(FAIL_TRIGGER);
  } catch {}
  fs.writeFileSync(FAIL_TRIGGER, 'bootstrap');
  const mockPath = path.resolve(__dirname, 'mock-db.js');
  serverProcess = spawn('node', ['-r', mockPath, 'server.js'], {
    cwd: __dirname + '/..',
    env: {
      ...process.env,
      PORT: '3000',
      APP_VERSION: 'test-1.2.3',
      BUILD_NUMBER: '42',
      MOCK_DB_FAIL_ONCE_FILE: FAIL_TRIGGER,
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server start timeout')), 10000);
    serverProcess.stdout.on('data', (data) => {
      if (data.toString().includes('API listening')) {
        clearTimeout(timer);
        resolve();
      }
    });
    serverProcess.on('exit', (code) => {
      clearTimeout(timer);
      reject(new Error('server exited with code ' + code));
    });
  });
});

after(() => {
  if (serverProcess) {
    serverProcess.kill();
  }
});

const endpoints = [
  { method: 'GET', path: '/health' },
  { method: 'POST', path: '/actors', body: { name: 'Tester' }, expect: 201 },
  { method: 'GET', path: '/actors' },
  { method: 'GET', path: '/actors/1', expect: 404 },
  { method: 'PUT', path: '/actors/1', body: { name: 'Updated' }, expect: 404 },
  { method: 'DELETE', path: '/actors/1', expect: 404 },

  { method: 'POST', path: '/shows', body: { title: 'Show', description: 'Desc', year: 2020 }, expect: 201 },
  { method: 'GET', path: '/shows' },
  { method: 'GET', path: '/shows/1', expect: 404 },
  { method: 'PUT', path: '/shows/1', body: { title: 'Updated', description: 'Desc', year: 2021 }, expect: 404 },
  { method: 'DELETE', path: '/shows/1', expect: 404 },

  { method: 'POST', path: '/shows/1/seasons', body: { season_number: 1, year: 2020 }, expect: 404 },
  { method: 'GET', path: '/shows/1/seasons', expect: 200 },
  { method: 'GET', path: '/seasons/1', expect: 404 },
  { method: 'PUT', path: '/seasons/1', body: { show_id: 1, season_number: 1, year: 2020 }, expect: 404 },
  { method: 'DELETE', path: '/seasons/1', expect: 404 },

  { method: 'POST', path: '/shows/1/episodes', body: { season_id: 1, air_date: null, title: 'Ep', description: 'Desc' }, expect: 400 },
  { method: 'GET', path: '/shows/1/episodes', expect: 200 },
  { method: 'GET', path: '/seasons/1/episodes', expect: 404 },
  { method: 'GET', path: '/shows/1/seasons/1/episodes', expect: 404 },
  { method: 'GET', path: '/episodes/1', expect: 404 },
  { method: 'PUT', path: '/episodes/1', body: { season_id: 1, show_id: 1, air_date: null, title: 'Ep', description: 'Desc' }, expect: 404 },
  { method: 'DELETE', path: '/episodes/1', expect: 404 },

  { method: 'POST', path: '/shows/1/characters', body: { name: 'Char', actor_id: null }, expect: 404 },
  { method: 'GET', path: '/shows/1/characters', expect: 200 },
  { method: 'GET', path: '/characters/1', expect: 404 },
  { method: 'PUT', path: '/characters/1', body: { show_id: 1, name: 'Char', actor_id: null }, expect: 404 },
  { method: 'DELETE', path: '/characters/1', expect: 404 },

  // New include-based nested retrievals
  { method: 'GET', path: '/shows?include=seasons' },
  { method: 'GET', path: '/shows/1/episodes?include=characters.actor', expect: 200 },
  { method: 'GET', path: '/shows/1/characters?include=actor', expect: 200 },
  { method: 'GET', path: '/episodes/1?include=characters.actor', expect: 404 },
  { method: 'GET', path: '/episodes/1/characters?include=actor', expect: 404 },

  { method: 'POST', path: '/episodes/1/characters', body: { character_id: 1 }, expect: 404 },
  { method: 'GET', path: '/episodes/1/characters', expect: 404 },
  { method: 'DELETE', path: '/episodes/1/characters/1', expect: 404 },

  { method: 'POST', path: '/shows/query-jobs', body: {}, expect: 202 },
  { method: 'POST', path: '/seasons/query-jobs', body: {}, expect: 202 },
  { method: 'POST', path: '/episodes/query-jobs', body: {}, expect: 202 },
  { method: 'POST', path: '/characters/query-jobs', body: {}, expect: 202 },
  { method: 'POST', path: '/actors/query-jobs', body: {}, expect: 202 },

  { method: 'GET', path: '/jobs/1', expect: 404 },
  { method: 'GET', path: '/jobs/1/download', expect: 404 },
  { method: 'DELETE', path: '/jobs/1', expect: 404 },
];

for (const ep of endpoints) {
  test(`${ep.method} ${ep.path}`, async () => {
    const opts = { method: ep.method, headers: { 'Content-Type': 'application/json' } };
    if (ep.body) {
      opts.body = JSON.stringify(ep.body);
    }

    try {
      const res = await fetch(`http://localhost:3000${ep.path}`, opts);
      const expected = ep.expect ?? 200;
      assert.strictEqual(res.status, expected);
    } catch (err) {
      assert.fail(err);
    }
  });
}

test('database administration endpoints', async (t) => {
  await t.test('POST /init retries after transient connection failure', async () => {
    fs.writeFileSync(FAIL_TRIGGER, 'retry');
    const res = await fetch('http://localhost:3000/init', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    });
    assert.strictEqual(res.status, 200);
  });

  await t.test('POST /admin/reset-database', async () => {
    const res = await fetch('http://localhost:3000/admin/reset-database', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    });
    assert.strictEqual(res.status, 200);
  });

  await t.test('GET /admin/database-dump returns full dataset', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.deepStrictEqual(body, {
      actors: [],
      shows: [],
      seasons: [],
      episodes: [],
      characters: [],
      episodeCharacters: []
    });
  });

  await t.test('GET /admin/database-dump supports limit and offset', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump?limit=5&offset=0');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.ok(Array.isArray(body.actors));
    assert.ok(Array.isArray(body.shows));
    assert.ok(Array.isArray(body.seasons));
    assert.ok(Array.isArray(body.episodes));
    assert.ok(Array.isArray(body.characters));
    assert.ok(Array.isArray(body.episodeCharacters));
  });

  await t.test('GET /admin/database-dump rejects offset without limit', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump?offset=10');
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    assert.deepStrictEqual(body, { error: 'offset requires limit to be set' });
  });

  await t.test('GET /admin/database-dump rejects out-of-range end date', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump?end=9999-12-31T23:59:59+00:00');
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    assert.deepStrictEqual(body, {
      error: 'end must be on or before 2038-01-19T03:14:07.000Z',
    });
  });

  await t.test('GET /admin/database-dump rejects invalid showIds filter', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump?showIds=foo');
    assert.strictEqual(res.status, 400);
    const body = await res.json();
    assert.deepStrictEqual(body, { error: 'showIds must contain positive integers' });
  });

  await t.test('GET /admin/database-dump accepts showIds filter', async () => {
    const res = await fetch('http://localhost:3000/admin/database-dump?showIds=1,2');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.ok(Array.isArray(body.shows));
    assert.ok(Array.isArray(body.seasons));
    assert.ok(Array.isArray(body.episodes));
    assert.ok(Array.isArray(body.characters));
    assert.ok(Array.isArray(body.actors));
  });

  await t.test('GET /admin/database-dump recovers from closed pool', async () => {
    const trigger = path.resolve(__dirname, '.pool-closed-next');
    fs.writeFileSync(trigger, '1');
    const res = await fetch('http://localhost:3000/admin/database-dump');
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.deepStrictEqual(body, {
      actors: [],
      shows: [],
      seasons: [],
      episodes: [],
      characters: [],
      episodeCharacters: []
    });
  });

  await t.test('GET /admin/database-dump reports database outage', async () => {
    const trigger = path.resolve(__dirname, '.execute-conn-refused');
    fs.writeFileSync(trigger, '1');
    const res = await fetch('http://localhost:3000/admin/database-dump');
    assert.strictEqual(res.status, 503);
    const body = await res.json();
    assert.deepStrictEqual(body, { error: 'database temporarily unavailable' });
  });

  await t.test('POST /admin/database-import upserts payload', async () => {
    const payload = {
      actors: [{ id: 1, name: 'Importer', created_at: '2025-01-01T00:00:00.000Z' }],
      shows: [{
        id: 1,
        title: 'Imported Show',
        description: 'Imported description',
        year: 2025,
        created_at: '2025-01-02T00:00:00.000Z'
      }],
      seasons: [{
        id: 1,
        show_id: 1,
        season_number: 1,
        year: 2025,
        created_at: '2025-01-03T00:00:00.000Z'
      }],
      episodes: [{
        id: 1,
        season_id: 1,
        air_date: '2025-01-15',
        title: 'Imported Pilot',
        description: 'Episode description',
        created_at: '2025-01-04T00:00:00.000Z'
      }],
      characters: [{
        id: 1,
        show_id: 1,
        name: 'Imported Hero',
        actor_id: 1,
        created_at: '2025-01-05T00:00:00.000Z'
      }],
      episodeCharacters: [{
        id: 1,
        episode_id: 1,
        character_id: 1,
        created_at: '2025-01-06T00:00:00.000Z'
      }]
    };
    const res = await fetch('http://localhost:3000/admin/database-import', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    assert.strictEqual(res.status, 200);
    const body = await res.json();
    assert.deepStrictEqual(body, {
      status: 'imported',
      counts: {
        actors: 1,
        shows: 1,
        seasons: 1,
        episodes: 1,
        characters: 1,
        episodeCharacters: 1
      }
    });
  });
});

test('GET /deployment-version returns deployment metadata', async () => {
  const res = await fetch('http://localhost:3000/deployment-version');
  assert.strictEqual(res.status, 200);
  const body = await res.json();
  assert.deepStrictEqual(body, {
    appVersion: 'test-1.2.3',
    buildNumber: '42',
    packageVersion: pkg.version
  });
});
