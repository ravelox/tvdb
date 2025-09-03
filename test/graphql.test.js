const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');

let serverProcess;

before(async () => {
  const mockPath = path.resolve(__dirname, 'mock-db.js');
  serverProcess = spawn('node', ['-r', mockPath, 'server.js'], {
    cwd: __dirname + '/..',
    env: { ...process.env, PORT: '3001' },
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
  if (serverProcess) serverProcess.kill();
});

test('GraphQL discovery', async () => {
  const res = await fetch('http://localhost:3001/graphql.json');
  const json = await res.json();
  assert.strictEqual(res.status, 200);
  assert.ok(json.operations && json.operations.health);
});

test('GraphQL health', async () => {
  const res = await fetch('http://localhost:3001/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: '{ health { ok db } }' })
  });
  const json = await res.json();
  assert.strictEqual(res.status, 200);
  assert.ok(json.data && json.data.health);
});

test('GraphQL createActor', async () => {
  const res = await fetch('http://localhost:3001/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: 'mutation { createActor(name:"Tester"){ id name } }' })
  });
  const json = await res.json();
  assert.strictEqual(res.status, 200);
  assert.ok('createActor' in json.data);
});
