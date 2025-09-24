const { test, before, after } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');
const pkg = require('../package.json');

let serverProcess;

before(async () => {
  const mockPath = path.resolve(__dirname, 'mock-db.js');
  serverProcess = spawn('node', ['-r', mockPath, 'server.js'], {
    cwd: path.resolve(__dirname, '..'),
    env: {
      ...process.env,
      PORT: '3002',
      API_TOKEN: 'version-test-token',
      APP_VERSION: 'public-4.5.6',
      BUILD_NUMBER: '99'
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

test('GET /deployment-version is public even when API token is required', async () => {
  const res = await fetch('http://localhost:3002/deployment-version');
  assert.strictEqual(res.status, 200);
  const body = await res.json();
  assert.deepStrictEqual(body, {
    appVersion: 'public-4.5.6',
    buildNumber: '99',
    packageVersion: pkg.version
  });
});
