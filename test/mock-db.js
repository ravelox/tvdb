const Module = require('module');

const stub = {
  createConnection: async () => ({
    query: async () => [[], []],
    changeUser: async () => {},
    end: async () => {},
  }),
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
