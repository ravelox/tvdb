const fs = require('node:fs');
const path = require('node:path');
const Module = require('module');

const TRIGGER_FILE = path.resolve(
  process.env.MOCK_DB_FAIL_ONCE_FILE || path.join(__dirname, '.fail-next-connection')
);
const POOL_CLOSED_TRIGGER = path.resolve(__dirname, '.pool-closed-next');
const EXECUTE_REFUSED_TRIGGER = path.resolve(__dirname, '.execute-conn-refused');

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
  createPool: () => {
    let closed = false;

    const maybeTripClosed = () => {
      if (fs.existsSync(POOL_CLOSED_TRIGGER)) {
        try {
          fs.unlinkSync(POOL_CLOSED_TRIGGER);
        } catch {}
        closed = true;
      }
      if (closed) {
        const err = new Error('Pool is closed.');
        err.code = 'POOL_CLOSED';
        err.fatal = true;
        throw err;
      }
    };

    const maybeTripExecuteFailure = () => {
      if (fs.existsSync(EXECUTE_REFUSED_TRIGGER)) {
        try {
          fs.unlinkSync(EXECUTE_REFUSED_TRIGGER);
        } catch {}
        const err = new Error('connect ECONNREFUSED 127.0.0.1:3306');
        err.code = 'ECONNREFUSED';
        err.fatal = true;
        throw err;
      }
    };

    const execute = async (sql, params) => {
      maybeTripClosed();
       maybeTripExecuteFailure();
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
    };
    const query = async (sql, params) => {
      maybeTripClosed();
      maybeTripExecuteFailure();
      const upper = sql.trim().toUpperCase();
      if (upper.includes('SELECT 1 AS OK')) {
        return [[{ ok: 1 }], []];
      }
      return [[]];
    };
    return {
      execute,
      query,
      end: async () => { closed = true; },
      getConnection: async () => ({
        execute,
        query,
        beginTransaction: async () => {},
        commit: async () => {},
        rollback: async () => {},
        release: () => {},
      }),
    };
  },
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === 'mysql2/promise') {
    return stub;
  }
  return originalLoad(request, parent, isMain);
};
