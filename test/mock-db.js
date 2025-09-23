const fs = require('node:fs');
const path = require('node:path');
const Module = require('module');

const TRIGGER_FILE = path.resolve(
  process.env.MOCK_DB_FAIL_ONCE_FILE || path.join(__dirname, '.fail-next-connection')
);

function maybeFailConnection() {
  if (!TRIGGER_FILE) return null;
  if (!fs.existsSync(TRIGGER_FILE)) return null;
  try {
    fs.unlinkSync(TRIGGER_FILE);
  } catch {
    // ignore cleanup errors so the failure still triggers
  }
  const err = new Error('Mocked connection failure');
  err.code = 'ECONNREFUSED';
  return err;
}

const stub = {
  createConnection: async () => {
    const failure = maybeFailConnection();
    if (failure) {
      throw failure;
    }
    return {
      query: async () => [[], []],
      changeUser: async () => {},
      end: async () => {},
    };
  },
  createPool: () => ({
    execute: async (sql, params) => {
      const upper = sql.trim().toUpperCase();
      if (upper.includes('SELECT 1 AS OK')) {
        return [[{ ok: 1 }], []];
      }
      if (upper.startsWith('INSERT')) {
        return [{ insertId: 1 }];
      }
      if (upper.startsWith('UPDATE') || upper.startsWith('DELETE')) {
        return [{ affectedRows: 0 }];
      }
      return [[]];
    },
    query: async (sql, params) => {
      const upper = sql.trim().toUpperCase();
      if (upper.includes('SELECT 1 AS OK')) {
        return [[{ ok: 1 }], []];
      }
      return [[]];
    },
    end: async () => {},
  }),
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'mysql2/promise') {
    return stub;
  }
  return originalLoad(request, parent, isMain);
};
