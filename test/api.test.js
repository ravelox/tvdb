const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');

let serverProcess;

before(async () => {
  serverProcess = spawn('node', ['server.js'], {
    cwd: __dirname + '/..',
    env: { ...process.env, PORT: '3000' },
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
  { method: 'POST', path: '/init' },
  { method: 'POST', path: '/actors', body: { name: 'Tester' } },
  { method: 'GET', path: '/actors' },
  { method: 'GET', path: '/actors/1', expect: 404 },
  { method: 'PUT', path: '/actors/1', body: { name: 'Updated' }, expect: 404 },
  { method: 'DELETE', path: '/actors/1', expect: 404 },

  { method: 'POST', path: '/shows', body: { title: 'Show', description: 'Desc', year: 2020 } },
  { method: 'GET', path: '/shows' },
  { method: 'GET', path: '/shows/1', expect: 404 },
  { method: 'PUT', path: '/shows/1', body: { title: 'Updated', description: 'Desc', year: 2021 }, expect: 404 },
  { method: 'DELETE', path: '/shows/1', expect: 404 },

  { method: 'POST', path: '/shows/1/seasons', body: { season_number: 1, year: 2020 }, expect: 404 },
  { method: 'GET', path: '/shows/1/seasons', expect: 404 },
  { method: 'GET', path: '/seasons/1', expect: 404 },
  { method: 'PUT', path: '/seasons/1', body: { show_id: 1, season_number: 1, year: 2020 }, expect: 404 },
  { method: 'DELETE', path: '/seasons/1', expect: 404 },

  { method: 'POST', path: '/shows/1/episodes', body: { season_id: 1, air_date: null, title: 'Ep', description: 'Desc' }, expect: 404 },
  { method: 'GET', path: '/shows/1/episodes', expect: 404 },
  { method: 'GET', path: '/seasons/1/episodes', expect: 404 },
  { method: 'GET', path: '/shows/1/seasons/1/episodes', expect: 404 },
  { method: 'GET', path: '/episodes/1', expect: 404 },
  { method: 'PUT', path: '/episodes/1', body: { season_id: 1, show_id: 1, air_date: null, title: 'Ep', description: 'Desc' }, expect: 404 },
  { method: 'DELETE', path: '/episodes/1', expect: 404 },

  { method: 'POST', path: '/shows/1/characters', body: { name: 'Char', actor_id: null }, expect: 404 },
  { method: 'GET', path: '/shows/1/characters', expect: 404 },
  { method: 'GET', path: '/characters/1', expect: 404 },
  { method: 'PUT', path: '/characters/1', body: { show_id: 1, name: 'Char', actor_id: null }, expect: 404 },
  { method: 'DELETE', path: '/characters/1', expect: 404 },

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

