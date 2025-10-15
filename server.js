/**
 * TV Shows CRUD API (Express + MySQL)
 * - CRUD for shows, seasons, episodes, characters, actors
 * - Many-to-many: episodes <-> characters
 * - Simulated long-running "query jobs" with polling + download
 * - Automatic database creation & schema initialization on server start (reads schema.sql)
 * - OpenAPI discovery endpoint + optional Swagger UI
 *
 * Usage:
 *   npm i
 *   npm start
 *
 * Env:
 *   PORT=3000
 *   DB_HOST=localhost
 *   DB_PORT=3306
 *   DB_USER=root
 *   DB_PASSWORD=yourpassword
 *   DB_NAME=tvdb
 */

const express = require('express');
const morgan = require('morgan');
const mysql = require('mysql2/promise');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');
const { parseGraphQLQuery } = require('./lib/graphqlParser');
const { buildCharacterUpsert } = require('./lib/characterUpsert');
require('dotenv').config();
const pkg = require('./package.json');

const originalLog = console.log;
const originalError = console.error;

const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const DB_HOST = process.env.DB_HOST || 'localhost';
const DB_PORT = process.env.DB_PORT ? Number(process.env.DB_PORT) : 3306;
const DB_USER = process.env.DB_USER || 'root';
const DB_PASSWORD = process.env.DB_PASSWORD || '';
const DB_NAME = process.env.DB_NAME || 'tvdb';
const APP_VERSION = process.env.APP_VERSION || pkg.version;
const BUILD_NUMBER = process.env.BUILD_NUMBER ?? null;
// Prepend version/build tag to all log lines
const logVersionTag = BUILD_NUMBER != null ? `${APP_VERSION}.${BUILD_NUMBER}` : APP_VERSION;
console.log = (...args) => originalLog(`[${logVersionTag}]`, ...args);
console.error = (...args) => originalError(`[${logVersionTag}]`, ...args);
const ENABLE_ADMIN_UI = process.env.ENABLE_ADMIN_UI != null
  ? process.env.ENABLE_ADMIN_UI === 'true'
  : process.env.NODE_ENV !== 'production';
const ADMIN_USERNAME = process.env.ADMIN_USERNAME || null;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || null;
const API_TOKEN = process.env.API_TOKEN || null;
const JOB_TTL_MS = (() => {
  const raw = Number(process.env.JOB_TTL_MS);
  if (Number.isFinite(raw) && raw >= 0) return raw;
  return 10 * 60 * 1000;
})();
const MAX_JOB_HISTORY = (() => {
  const raw = Number(process.env.MAX_JOB_HISTORY);
  if (Number.isFinite(raw) && raw > 0) return Math.floor(raw);
  return 100;
})();

const DB_RETRY_ATTEMPTS = (() => {
  const raw = Number(process.env.DB_RETRY_ATTEMPTS);
  if (Number.isFinite(raw) && raw > 0) return Math.floor(raw);
  return 3;
})();

const DB_RETRY_DELAY_MS = (() => {
  const raw = Number(process.env.DB_RETRY_DELAY_MS);
  if (Number.isFinite(raw) && raw >= 0) return Math.floor(raw);
  return 200;
})();

const jobs = new Map();

const RETRIABLE_DB_ERROR_CODES = new Set([
  'ECONNRESET',
  'ECONNREFUSED',
  'PROTOCOL_CONNECTION_LOST',
  'EPIPE',
  'ETIMEDOUT',
  'EHOSTUNREACH',
  'ENETUNREACH',
  'POOL_CLOSED',
]);

function isRetriableDbError(err) {
  if (!err) return false;
  if (err.fatal === true) return true;
  if (RETRIABLE_DB_ERROR_CODES.has(err.code)) return true;
  const message = typeof err.message === 'string' ? err.message.toLowerCase() : '';
  if (message.includes('pool is closed')) return true;
  return false;
}

async function runWithDbRetry(fn, { attempts = DB_RETRY_ATTEMPTS, delayMs = DB_RETRY_DELAY_MS } = {}) {
  const maxAttempts = Math.max(1, attempts);
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const retriable = isRetriableDbError(err);
      if (!retriable || attempt === maxAttempts - 1) {
        throw err;
      }
      const label = err.code || err.message || 'unknown error';
      console.error(
        `[db] Operation failed with ${label}; retrying in ${delayMs}ms (attempt ${attempt + 1}/${maxAttempts})`
      );
      if (delayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      }
    }
  }
}

async function initDatabase() {
  await runWithDbRetry(async () => {
    const conn = await mysql.createConnection({
      host: DB_HOST,
      port: DB_PORT,
      user: DB_USER,
      password: DB_PASSWORD,
      multipleStatements: true,
    });
    try {
      await conn.query(
        `CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`
      );
      await conn.changeUser({ database: DB_NAME });
      const schemaPath = path.resolve(__dirname, 'schema.sql');
      const schemaSQL = fs.readFileSync(schemaPath, 'utf8');
      await conn.query(schemaSQL);
      console.log('[init] Database and schema ensured');
    } finally {
      await conn.end();
    }
  });
}

async function resetDatabase() {
  console.log('[reset] Dropping database before reinitializing');
  await runWithDbRetry(async () => {
    const conn = await mysql.createConnection({
      host: DB_HOST,
      port: DB_PORT,
      user: DB_USER,
      password: DB_PASSWORD,
    });
    try {
      const escapedName = DB_NAME.replace(/`/g, '``');
      await conn.query(`DROP DATABASE IF EXISTS \`${escapedName}\``);
    } finally {
      await conn.end();
    }
  });
  await initDatabase();
  console.log('[reset] Database dropped and schema reapplied');
}

function createDbPool() {
  return mysql.createPool({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_USER,
    password: DB_PASSWORD,
    database: DB_NAME,
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
  });
}

let pool;

async function ensurePool() {
  if (!pool) {
    pool = createDbPool();
  }
  return pool;
}

async function closePool(target) {
  const current = target || pool;
  if (!current) return;
  if (current === pool) {
    pool = null;
  }
  try {
    await current.end();
  } catch (err) {
    const label = err && (err.code || err.message) ? (err.code || err.message) : err;
    console.warn(`[db] Failed to close pool cleanly: ${label}`);
  }
}

async function refreshPool() {
  await closePool();
  return ensurePool();
}

async function dbCall(method, sql, params, attempt = 0, options = {}) {
  const client = await ensurePool();
  try {
    return await client[method](sql, params);
  } catch (err) {
    const retriable = options.retry !== false && isRetriableDbError(err);
    if (retriable && attempt < 2) {
      console.error(
        `[db] ${method} failed with ${err.code || err.message}; rebuilding pool (attempt ${attempt + 1})`
      );
      await closePool(client);
      return dbCall(method, sql, params, attempt + 1, options);
    }
    throw err;
  }
}

const dbExecute = (sql, params, options) => dbCall('execute', sql, params, 0, options);
const dbQuery = (sql, params, options) => dbCall('query', sql, params, 0, options);

const app = express();
app.use(express.json());
app.use(morgan('dev', {
  stream: {
    write: msg => console.log(msg.trim())
  }
}));
if (ENABLE_ADMIN_UI) {
  const adminHandlers = [];
  if (ADMIN_USERNAME && ADMIN_PASSWORD) {
    adminHandlers.push(adminAuthMiddleware);
  }
  adminHandlers.push(express.static(path.join(__dirname, 'public')));
  app.use('/admin', ...adminHandlers);
} else {
  console.log('[admin] Admin UI disabled (set ENABLE_ADMIN_UI=true to enable)');
}

app.use('/explorer', express.static(path.join(__dirname, 'public', 'explorer')));

const PUBLIC_AUTH_PATHS = [
  /^\/docs(?:\/|$)/,
  /^\/openapi\.json$/,
  /^\/spec$/,
  /^\/\.well-known\/openapi\.json$/,
  /^\/deployment-version$/
];
function isPublicAuthPath(pathname) {
  return PUBLIC_AUTH_PATHS.some((pattern) => pattern.test(pathname));
}
if (API_TOKEN) {
  console.log('[auth] API token authentication enabled');
}
app.use((req, res, next) => {
  if (isPublicAuthPath(req.path)) return next();
  return apiTokenMiddleware(req, res, next);
});

function httpError(res, code, message) { return res.status(code).json({ error: message }); }
function exposedError(message) {
  const err = new Error(message);
  err.expose = true;
  return err;
}
const asyncH = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const MYSQL_TIMESTAMP_MIN = new Date('1970-01-01T00:00:01Z');
const MYSQL_TIMESTAMP_MAX = new Date('2038-01-19T03:14:07Z');
const DATE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:?\d{2})$/;

function normalizeDateInput(value) {
  if (value == null) return value;
  const trimmed = String(value).trim();
  if (!trimmed) return trimmed;
  const spaceIndex = trimmed.indexOf(' ');
  const tIndex = trimmed.indexOf('T');
  if (spaceIndex > tIndex && tIndex >= 0) {
    return trimmed.slice(0, spaceIndex) + '+' + trimmed.slice(spaceIndex + 1);
  }
  return trimmed;
}

function parseDateRange(req, res) {
  const startRaw = normalizeDateInput(req.query.start);
  const endRaw = normalizeDateInput(req.query.end);
  const earliest = MYSQL_TIMESTAMP_MIN;
  const latest = MYSQL_TIMESTAMP_MAX;
  let startDate = earliest;
  let endDate = latest;
  if (startRaw) {
    if (!DATE_RE.test(startRaw) || isNaN(Date.parse(startRaw))) {
      httpError(res, 400, 'invalid start date');
      return null;
    }
    startDate = new Date(startRaw);
    if (startDate < earliest) {
      httpError(res, 400, `start must be on or after ${earliest.toISOString()}`);
      return null;
    }
    if (startDate > latest) {
      httpError(res, 400, `start must be on or before ${latest.toISOString()}`);
      return null;
    }
  }
  if (endRaw) {
    if (!DATE_RE.test(endRaw) || isNaN(Date.parse(endRaw))) {
      httpError(res, 400, 'invalid end date');
      return null;
    }
    endDate = new Date(endRaw);
    if (endDate < earliest) {
      httpError(res, 400, `end must be on or after ${earliest.toISOString()}`);
      return null;
    }
    if (endDate > latest) {
      httpError(res, 400, `end must be on or before ${latest.toISOString()}`);
      return null;
    }
  }
  if (startDate > endDate) {
    httpError(res, 400, 'start must be before end');
    return null;
  }
  return {
    start: startDate,
    end: endDate,
    startSql: startDate.toISOString().slice(0, 19).replace('T', ' '),
    endSql: endDate.toISOString().slice(0, 19).replace('T', ' '),
  };
}

function parseIncludeParam(val) {
  const result = {};
  if (!val) return result;
  const items = Array.isArray(val) ? val : String(val).split(',');
  for (const item of items) {
    const segs = item.split('.').map(s => s.trim()).filter(Boolean);
    let cur = result;
    for (const seg of segs) {
      cur[seg] = cur[seg] || {};
      cur = cur[seg];
    }
  }
  return result;
}

const PAGE_INFO_VERSION = 1;

function base64UrlEncode(value) {
  return Buffer.from(value, 'utf8')
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function base64UrlDecode(value) {
  const normalized = String(value).replace(/-/g, '+').replace(/_/g, '/');
  const paddingLength = (4 - (normalized.length % 4)) % 4;
  const padded = normalized + '='.repeat(paddingLength);
  return Buffer.from(padded, 'base64').toString('utf8');
}

function encodePageInfoPayload(payload) {
  return base64UrlEncode(JSON.stringify(payload));
}

function decodePageInfoPayload(raw) {
  try {
    const decoded = base64UrlDecode(raw);
    return JSON.parse(decoded);
  } catch (err) {
    return null;
  }
}

function parsePagination(req, res) {
  const hasLimit = req.query.limit !== undefined;
  const hasOffset = req.query.offset !== undefined;
  let limit = null;
  let offset = 0;
  if (hasLimit) {
    const parsed = Number(req.query.limit);
    if (!Number.isInteger(parsed) || parsed <= 0) {
      httpError(res, 400, 'limit must be a positive integer');
      return null;
    }
    limit = parsed;
  }
  if (hasOffset) {
    const parsed = Number(req.query.offset);
    if (!Number.isInteger(parsed) || parsed < 0) {
      httpError(res, 400, 'offset must be a non-negative integer');
      return null;
    }
    if (!hasLimit) {
      httpError(res, 400, 'offset requires limit to be set');
      return null;
    }
    offset = parsed;
  }

  let cursorValues = null;
  let cursorDirection = null;
  let rawPageInfo = null;
  if (req.query.page_info !== undefined) {
    rawPageInfo = String(req.query.page_info || '');
    const payload = decodePageInfoPayload(rawPageInfo);
    if (!payload || payload.v !== PAGE_INFO_VERSION || typeof payload.values !== 'object' || !payload.dir) {
      httpError(res, 400, 'page_info is invalid');
      return null;
    }
    cursorDirection = payload.dir === 'prev' ? 'prev' : 'next';
    cursorValues = payload.values || {};
    if (payload.limit != null) {
      const parsedLimit = Number(payload.limit);
      if (!Number.isInteger(parsedLimit) || parsedLimit <= 0) {
        httpError(res, 400, 'page_info limit is invalid');
        return null;
      }
      if (limit != null && limit !== parsedLimit) {
        httpError(res, 400, 'limit must match the value embedded in page_info');
        return null;
      }
      limit = parsedLimit;
    } else if (limit == null) {
      httpError(res, 400, 'limit is required when using page_info');
      return null;
    }
  }

  if (cursorValues && hasOffset) {
    httpError(res, 400, 'offset cannot be combined with page_info');
    return null;
  }

  return {
    limit,
    offset,
    cursorValues,
    cursorDirection,
    rawPageInfo,
    usingPageInfo: cursorValues != null,
  };
}

function parseIdListParam(rawValue, fieldLabel, res) {
  if (rawValue == null) return [];
  const values = Array.isArray(rawValue) ? rawValue : String(rawValue).split(',');
  const ids = new Set();
  for (const raw of values) {
    const trimmed = String(raw).trim();
    if (!trimmed) continue;
    const num = Number(trimmed);
    if (!Number.isInteger(num) || num <= 0) {
      httpError(res, 400, `${fieldLabel} must contain positive integers`);
      return null;
    }
    ids.add(num);
  }
  return Array.from(ids);
}

function flipSortDirection(direction = 'ASC') {
  return String(direction).toUpperCase() === 'DESC' ? 'ASC' : 'DESC';
}

function comparatorForCursor(cursorDirection, sortDirection = 'ASC') {
  const dir = String(sortDirection).toUpperCase() === 'DESC' ? 'DESC' : 'ASC';
  if (cursorDirection === 'prev') {
    return dir === 'DESC' ? '>' : '<';
  }
  return dir === 'DESC' ? '<' : '>';
}

function wrapSqlExpression(expr) {
  const trimmed = expr.trim();
  if (!trimmed.startsWith('(') && !trimmed.endsWith(')') && /[\s+]/.test(trimmed)) {
    return `(${trimmed})`;
  }
  return trimmed;
}

function toSqlComparable(entry, rawValue) {
  const transformer = entry && entry.toSqlValue ? entry.toSqlValue : ((value) => value);
  return transformer(rawValue);
}

function buildCursorCondition(order, cursorValues, cursorDirection) {
  if (!cursorValues) return null;
  if (!order || !order.length) return null;
  const sqlValues = order.map((entry) => {
    if (!Object.prototype.hasOwnProperty.call(cursorValues, entry.name)) {
      throw exposedError('page_info is invalid for this resource');
    }
    return toSqlComparable(entry, cursorValues[entry.name]);
  });
  const clauses = [];
  const params = [];
  for (let i = 0; i < order.length; i++) {
    const entry = order[i];
    const cmp = comparatorForCursor(cursorDirection, entry.direction);
    const parts = [];
    for (let j = 0; j < i; j++) {
      parts.push(`${wrapSqlExpression(order[j].expression)} = ?`);
      params.push(sqlValues[j]);
    }
    parts.push(`${wrapSqlExpression(entry.expression)} ${cmp} ?`);
    params.push(sqlValues[i]);
    clauses.push(`(${parts.join(' AND ')})`);
  }
  if (!clauses.length) return null;
  return {
    sql: `(${clauses.join(' OR ')})`,
    params,
  };
}

function encodePageInfoFromValues(direction, limit, values) {
  const payload = { v: PAGE_INFO_VERSION, dir: direction, values: values || {} };
  if (limit != null) {
    payload.limit = limit;
  }
  return encodePageInfoPayload(payload);
}

function encodePageInfoFromRow(direction, limit, order, row) {
  const values = {};
  for (const entry of order) {
    if (typeof entry.getValue !== 'function') {
      throw new Error(`Order entry '${entry.name}' is missing getValue()`);
    }
    values[entry.name] = entry.getValue(row);
  }
  return encodePageInfoFromValues(direction, limit, values);
}

function createPaginatedQuery({ select, where = [], params = [], order = [], pagination = {} }) {
  const clauses = [...where];
  const queryParams = [...params];
  const limit = pagination.limit != null ? pagination.limit : null;
  let cursorDirection = null;
  let usedCursor = false;

  if (pagination.cursorValues) {
    usedCursor = true;
    cursorDirection = pagination.cursorDirection || 'next';
    const cursorCondition = buildCursorCondition(order, pagination.cursorValues, cursorDirection);
    if (cursorCondition) {
      clauses.push(cursorCondition.sql);
      queryParams.push(...cursorCondition.params);
    }
  }

  const orderSpec = cursorDirection === 'prev'
    ? order.map((entry) => ({ ...entry, direction: flipSortDirection(entry.direction || 'ASC') }))
    : order;

  let sql = select;
  if (clauses.length) {
    sql += ` WHERE ${clauses.join(' AND ')}`;
  }
  if (orderSpec.length) {
    const orderClause = orderSpec
      .map((entry) => `${entry.expression} ${(entry.direction || 'ASC')}`)
      .join(', ');
    sql += ` ORDER BY ${orderClause}`;
  }

  if (limit != null) {
    const effectiveLimit = limit + 1;
    sql += ` LIMIT ${effectiveLimit}`;
    if (!usedCursor && pagination.offset != null) {
      const offsetValue = Math.max(0, Number(pagination.offset) || 0);
      sql += ` OFFSET ${offsetValue}`;
    }
  }

  return { sql, params: queryParams, limit, cursorDirection, usedCursor };
}

function buildPaginationLinks({ req, limit, items, hasExtra, cursorDirection, usedCursor, pagination, order }) {
  if (!items.length || limit == null) return [];

  const baseParams = new URLSearchParams();
  const originalQuery = req.query || {};
  for (const [key, value] of Object.entries(originalQuery)) {
    if (key === 'page_info' || key === 'offset' || key === 'limit') continue;
    if (Array.isArray(value)) {
      for (const v of value) {
        if (v != null) baseParams.append(key, String(v));
      }
    } else if (value != null) {
      baseParams.append(key, String(value));
    }
  }
  baseParams.set('limit', String(limit));

  let hasPrevLink = false;
  let hasNextLink = false;
  if (!usedCursor) {
    hasPrevLink = pagination.offset != null && pagination.offset > 0;
    hasNextLink = hasExtra;
  } else if (cursorDirection === 'next') {
    hasPrevLink = true;
    hasNextLink = hasExtra;
  } else if (cursorDirection === 'prev') {
    hasPrevLink = hasExtra;
    hasNextLink = true;
  } else {
    hasNextLink = hasExtra;
  }

  const links = [];
  const path = `${req.baseUrl || ''}${req.path}`;

  if (hasPrevLink && items.length) {
    const token = encodePageInfoFromRow('prev', limit, order, items[0]);
    const params = new URLSearchParams(baseParams.toString());
    params.set('page_info', token);
    const qs = params.toString();
    links.push(`${path}${qs ? `?${qs}` : ''}; rel="previous"`);
  }
  if (hasNextLink && items.length) {
    const token = encodePageInfoFromRow('next', limit, order, items[items.length - 1]);
    const params = new URLSearchParams(baseParams.toString());
    params.set('page_info', token);
    const qs = params.toString();
    links.push(`${path}${qs ? `?${qs}` : ''}; rel="next"`);
  }
  return links;
}

function applyPaginationResult({ req, res, rows, limit, cursorDirection, usedCursor, pagination = {}, order }) {
  if (limit == null) {
    return rows;
  }
  const hasExtra = rows.length > limit;
  let items = rows.slice(0, limit);
  if (cursorDirection === 'prev') {
    items = items.reverse();
  }
  if (res) {
    const links = buildPaginationLinks({
      req,
      limit,
      items,
      hasExtra,
      cursorDirection,
      usedCursor,
      pagination,
      order,
    });
    if (links.length) {
      res.set('Link', links.join(', '));
    }
  }
  return items;
}

function formatDateTime(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())}`;
}

function formatDateOnly(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
}

function toSqlTimestamp(value, fieldPath) {
  if (value == null || value === '') return null;
  if (value instanceof Date) return formatDateTime(value);
  if (typeof value === 'number') {
    const fromNumber = new Date(value);
    if (!Number.isNaN(fromNumber.getTime())) return formatDateTime(fromNumber);
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) return null;
    if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(trimmed)) return trimmed;
    const normalized = trimmed.includes(' ') && !trimmed.includes('T') ? trimmed.replace(' ', 'T') : trimmed;
    const parsed = new Date(normalized);
    if (!Number.isNaN(parsed.getTime())) return formatDateTime(parsed);
    const fallback = new Date(trimmed);
    if (!Number.isNaN(fallback.getTime())) return formatDateTime(fallback);
  }
  throw exposedError(`${fieldPath} must be a valid timestamp`);
}

function toSqlDate(value, fieldPath) {
  if (value == null || value === '') return null;
  if (value instanceof Date) return formatDateOnly(value);
  if (typeof value === 'number') {
    const fromNumber = new Date(value);
    if (!Number.isNaN(fromNumber.getTime())) return formatDateOnly(fromNumber);
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) return null;
    if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return trimmed;
    const normalized = trimmed.includes(' ') && !trimmed.includes('T') ? trimmed.replace(' ', 'T') : trimmed;
    const parsed = new Date(normalized);
    if (!Number.isNaN(parsed.getTime())) return formatDateOnly(parsed);
    const fallback = new Date(trimmed);
    if (!Number.isNaN(fallback.getTime())) return formatDateOnly(fallback);
  }
  throw exposedError(`${fieldPath} must be a valid ISO date (YYYY-MM-DD)`);
}

function toPositiveInt(value, fieldPath) {
  const num = Number(value);
  if (!Number.isInteger(num) || num <= 0) {
    throw exposedError(`${fieldPath} must be a positive integer`);
  }
  return num;
}

function toNonNegativeInt(value, fieldPath) {
  const num = Number(value);
  if (!Number.isInteger(num) || num < 0) {
    throw exposedError(`${fieldPath} must be a non-negative integer`);
  }
  return num;
}

function toOptionalPositiveInt(value, fieldPath) {
  if (value == null || value === '') return null;
  return toPositiveInt(value, fieldPath);
}

function toOptionalInteger(value, fieldPath) {
  if (value == null || value === '') return null;
  const num = Number(value);
  if (!Number.isInteger(num)) {
    throw exposedError(`${fieldPath} must be an integer`);
  }
  return num;
}

function requireString(value, fieldPath) {
  if (typeof value !== 'string' || !value.trim()) {
    throw exposedError(`${fieldPath} is required`);
  }
  return value;
}

function adminAuthMiddleware(req, res, next) {
  if (!ADMIN_USERNAME || !ADMIN_PASSWORD) return next();
  const header = req.headers.authorization || '';
  if (header.startsWith('Basic ')) {
    const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
    const separatorIndex = decoded.indexOf(':');
    const username = separatorIndex >= 0 ? decoded.slice(0, separatorIndex) : decoded;
    const password = separatorIndex >= 0 ? decoded.slice(separatorIndex + 1) : '';
    if (username === ADMIN_USERNAME && password === ADMIN_PASSWORD) {
      return next();
    }
  }
  res.set('WWW-Authenticate', 'Basic realm="TVDB Admin"');
  return res.status(401).send('Authentication required');
}

function apiTokenMiddleware(req, res, next) {
  if (!API_TOKEN) return next();
  let token = req.get('x-api-token');
  if (!token) {
    const authHeader = req.get('authorization');
    if (authHeader && authHeader.startsWith('Bearer ')) {
      token = authHeader.slice(7);
    }
  }
  if (token === API_TOKEN) return next();
  return res.status(401).json({ error: 'invalid api token' });
}

// --------------------------- OpenAPI discovery ---------------------------
const openapiBase = {
  openapi: '3.0.3',
  info: {
    title: 'TV Shows API',
    version: pkg.version,
    description: 'CRUD for shows/seasons/episodes/characters/actors, episode↔character links, and query jobs.'
  },
  servers: [], // populated dynamically per request
  tags: [
    { name: 'health' }, { name: 'actors' }, { name: 'shows' }, { name: 'seasons' },
    { name: 'episodes' }, { name: 'characters' }, { name: 'links' }, { name: 'jobs' },
    { name: 'admin' }
  ],
  components: {
    schemas: {
      Actor: { type: 'object', properties: { id:{type:'integer'}, name:{type:'string'} } },
      Show:  { type: 'object', properties: { id:{type:'integer'}, title:{type:'string'}, description:{type:'string'}, year:{type:'integer', nullable:true} } },
      Season:{ type: 'object', properties: { id:{type:'integer'}, show_id:{type:'integer'}, season_number:{type:'integer'}, year:{type:'integer', nullable:true} } },
      Episode:{ type: 'object', properties: { id:{type:'integer'}, season_id:{type:'integer'}, show_id:{type:'integer'}, air_date:{type:'string', format:'date', nullable:true}, title:{type:'string'}, description:{type:'string', nullable:true} } },
      Character:{ type: 'object', properties: { id:{type:'integer'}, show_id:{type:'integer'}, name:{type:'string'}, actor_id:{type:'integer', nullable:true} } },
      JobStatus: { type:'object', properties: { id:{type:'string'}, status:{type:'string'}, eta_ms:{type:'integer'}, download_url:{type:'string', nullable:true} } }
    }
  },
  paths: {
    '/health': { get: { tags:['health'], summary:'Service/DB health', responses:{ '200':{ description:'OK' } } } },
    '/deployment-version': { get: { tags:['health'], summary:'Get app deployment version', responses:{ '200':{ description:'Deployment version' } } } },
    '/init': { post: { tags:['health'], summary:'Initialize DB/schema', responses:{ '200':{ description:'Initialized' } } } },
    '/admin/reset-database': { post: { tags:['admin'], summary:'Reset database schema via API', responses:{ '200':{ description:'Reset' } } } },
    '/admin/database-dump': { get: { tags:['admin'], summary:'Export entire database contents', responses:{ '200':{ description:'Database dump' } } } },
    '/admin/database-import': { post: { tags:['admin'], summary:'Import database dump (upsert)', responses:{ '200':{ description:'Import completed' } } } },

    '/actors': { get:{ tags:['actors'], summary:'List actors' }, post:{ tags:['actors'], summary:'Create actor' } },
    '/actors/{id}': { get:{ tags:['actors'], summary:'Get actor' }, put:{ tags:['actors'], summary:'Update actor' }, delete:{ tags:['actors'], summary:'Delete actor' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }] },

    '/shows': { get:{ tags:['shows'], summary:'List shows' }, post:{ tags:['shows'], summary:'Create show' } },
    '/shows/{id}': { get:{ tags:['shows'], summary:'Get show' }, put:{ tags:['shows'], summary:'Update show' }, delete:{ tags:['shows'], summary:'Delete show' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }] },

    '/shows/{showId}/seasons': { get:{ tags:['seasons'], summary:'List seasons for show' }, post:{ tags:['seasons'], summary:'Create season for show' }, parameters:[{ name:'showId', in:'path', required:true, schema:{type:'integer'} }] },
    '/seasons/{id}': { get:{ tags:['seasons'], summary:'Get season' }, put:{ tags:['seasons'], summary:'Update season' }, delete:{ tags:['seasons'], summary:'Delete season' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }] },

    '/shows/{showId}/episodes': { get:{ tags:['episodes'], summary:'List episodes for show' }, post:{ tags:['episodes'], summary:'Create episode under a season by season_number' }, parameters:[{ name:'showId', in:'path', required:true, schema:{type:'integer'} }] },
    '/episodes/{id}': { get:{ tags:['episodes'], summary:'Get episode (includes characters array)' }, put:{ tags:['episodes'], summary:'Update episode' }, delete:{ tags:['episodes'], summary:'Delete episode' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }] },

    '/shows/{showId}/characters': { get:{ tags:['characters'], summary:'List characters for show' }, post:{ tags:['characters'], summary:'Create character for show' }, parameters:[{ name:'showId', in:'path', required:true, schema:{type:'integer'} }] },
    '/characters/{id}': { get:{ tags:['characters'], summary:'Get character' }, put:{ tags:['characters'], summary:'Update character' }, delete:{ tags:['characters'], summary:'Delete character' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }] },

    '/episodes/{episodeId}/characters': { get:{ tags:['links'], summary:'List characters in episode' }, post:{ tags:['links'], summary:'Link (or create+link) character to episode' }, parameters:[{ name:'episodeId', in:'path', required:true, schema:{type:'integer'} }] },
    '/episodes/{episodeId}/characters/{characterId}': { delete:{ tags:['links'], summary:'Unlink character from episode' }, parameters:[{ name:'episodeId', in:'path', required:true, schema:{type:'integer'} }, { name:'characterId', in:'path', required:true, schema:{type:'integer'} }] },

    '/shows/query-jobs': { post:{ tags:['jobs'], summary:'Start simulated long‑running TV show query' } },
    '/seasons/query-jobs': { post:{ tags:['jobs'], summary:'Start simulated long‑running season query' } },
    '/episodes/query-jobs': { post:{ tags:['jobs'], summary:'Start simulated long‑running episode query' } },
    '/characters/query-jobs': { post:{ tags:['jobs'], summary:'Start simulated long‑running character query' } },
    '/actors/query-jobs': { post:{ tags:['jobs'], summary:'Start simulated long‑running actor query' } },
    '/jobs/{id}': { get:{ tags:['jobs'], summary:'Poll job status' }, delete:{ tags:['jobs'], summary:'Delete job' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'string'} }] },
    '/jobs/{id}/download': { get:{ tags:['jobs'], summary:'Download job results (JSON)' }, parameters:[{ name:'id', in:'path', required:true, schema:{type:'string'} }] },

    // Episodes in a season
    '/seasons/{id}/episodes': {
      get: {
        tags:['episodes'], summary:'List episodes for a specific season',
        parameters:[{ name:'id', in:'path', required:true, schema:{type:'integer'} }]
      }
    },
    '/shows/{showId}/seasons/{seasonNumber}/episodes': {
      get: {
        tags:['episodes'], summary:'List episodes by show+season_number',
        parameters:[
          { name:'showId', in:'path', required:true, schema:{type:'integer'} },
          { name:'seasonNumber', in:'path', required:true, schema:{type:'integer'} }
        ]
      }
    }
  }
};

const dateRangeParams = [
  { name:'start', in:'query', required:false, schema:{ type:'string', format:'date-time' }, description:'Filter results with created_at >= start' },
  { name:'end', in:'query', required:false, schema:{ type:'string', format:'date-time' }, description:'Filter results with created_at <= end (default limitless)' }
];
const includeParam = { name:'include', in:'query', required:false, schema:{ type:'string' }, description:'Comma separated list of sub-resources to include, e.g. episodes,episodes.characters' };
const paginationParams = [
  { name:'limit', in:'query', required:false, schema:{ type:'integer', minimum:1 }, description:'Maximum number of rows to return; omit to return all rows' },
  { name:'offset', in:'query', required:false, schema:{ type:'integer', minimum:0, default:0 }, description:'Number of rows to skip before returning results (requires limit to be set)' },
  { name:'page_info', in:'query', required:false, schema:{ type:'string' }, description:'Opaque pagination cursor returned via Link headers (Shopify-style page_info parameter)' }
];
const dumpFilterParams = [
  { name:'showIds', in:'query', required:false, schema:{ type:'string' }, description:'Comma-separated list of show IDs to include (related seasons, episodes, characters, and actors are scoped automatically)' },
  { name:'seasonIds', in:'query', required:false, schema:{ type:'string' }, description:'Comma-separated list of season IDs to include (their parent shows are pulled into the export)' },
  { name:'episodeIds', in:'query', required:false, schema:{ type:'string' }, description:'Comma-separated list of episode IDs to include along with their parent seasons, shows, and related characters' },
  { name:'characterIds', in:'query', required:false, schema:{ type:'string' }, description:'Comma-separated list of character IDs to include along with their shows and actors' },
  { name:'actorIds', in:'query', required:false, schema:{ type:'string' }, description:'Comma-separated list of actor IDs to include; combine with other filters for precise exports' }
];
const defaultQueryParamSkipPaths = new Set(['/deployment-version', '/admin/database-dump']);
for (const [path, ops] of Object.entries(openapiBase.paths)) {
  for (const [method, op] of Object.entries(ops)) {
    if (method === 'get' && !defaultQueryParamSkipPaths.has(path)) {
      op.parameters = [...(op.parameters || []), ...dateRangeParams, includeParam, ...paginationParams];
    }
  }
}
openapiBase.paths['/admin/database-dump'].get.parameters = [
  ...dateRangeParams,
  ...paginationParams,
  ...dumpFilterParams,
];

app.get(['/openapi.json', '/spec', '/.well-known/openapi.json'], (req, res) => {
  const base = `${req.protocol}://${req.get('host')}`;
  const doc = { ...openapiBase, servers: [{ url: base }] };
  res.json(doc);
});

try {
  const swaggerUi = require('swagger-ui-express');
  const docsMiddleware = [swaggerUi.serve, swaggerUi.setup(null, {
    explorer: true,
    swaggerOptions: { url: '/openapi.json' }
  })];
  app.use('/docs', ...docsMiddleware);
  console.log('[docs] Swagger UI available at /docs');
} catch (e) {
  console.log('[docs] Install swagger-ui-express to enable /docs');
}

// --------------------------- Health ---------------------------
app.get('/health', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  try {
    const [rows] = await dbQuery('SELECT 1 AS ok');
    res.json({ ok: true, db: rows[0].ok === 1 });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
}));

app.get('/deployment-version', asyncH(async (_req, res) => {
  res.json({
    appVersion: APP_VERSION,
    buildNumber: BUILD_NUMBER,
    packageVersion: pkg.version
  });
}));

app.post('/init', asyncH(async (_req, res) => {
  await initDatabase();
  await refreshPool();
  res.json({ status: 'initialized' });
}));

app.post('/admin/reset-database', asyncH(async (_req, res) => {
  await closePool();
  await resetDatabase();
  await refreshPool();
  res.json({ status: 'reset' });
}));

app.get('/admin/database-dump', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const pagination = parsePagination(req, res); if (!pagination) return;
  const showIdList = parseIdListParam(req.query.showIds ?? req.query.show_ids ?? req.query.shows, 'showIds', res); if (showIdList == null) return;
  const seasonIdList = parseIdListParam(req.query.seasonIds ?? req.query.season_ids ?? req.query.seasons, 'seasonIds', res); if (seasonIdList == null) return;
  const episodeIdList = parseIdListParam(req.query.episodeIds ?? req.query.episode_ids ?? req.query.episodes, 'episodeIds', res); if (episodeIdList == null) return;
  const characterIdList = parseIdListParam(req.query.characterIds ?? req.query.character_ids ?? req.query.characters, 'characterIds', res); if (characterIdList == null) return;
  const actorIdList = parseIdListParam(req.query.actorIds ?? req.query.actor_ids ?? req.query.actors, 'actorIds', res); if (actorIdList == null) return;

  const filters = {
    showIds: new Set(showIdList),
    seasonIds: new Set(seasonIdList),
    episodeIds: new Set(episodeIdList),
    characterIds: new Set(characterIdList),
    actorIds: new Set(actorIdList),
  };

  const addAll = (set, values) => {
    for (const value of values) {
      if (value != null) {
        set.add(value);
      }
    }
  };

  // Derive related identifiers so parent/child records stay consistent.
  if (filters.seasonIds.size) {
    const placeholders = Array.from(filters.seasonIds).map(() => '?').join(',');
    const [rows] = await dbQuery(
      `SELECT id, show_id FROM seasons WHERE id IN (${placeholders})`,
      Array.from(filters.seasonIds)
    );
    for (const row of rows) {
      addAll(filters.showIds, [row.show_id]);
    }
  }

  if (filters.episodeIds.size) {
    const episodeValues = Array.from(filters.episodeIds);
    const placeholders = episodeValues.map(() => '?').join(',');
    const [rows] = await dbQuery(
      `SELECT e.id, e.season_id, s.show_id
       FROM episodes e
       JOIN seasons s ON s.id = e.season_id
       WHERE e.id IN (${placeholders})`,
      episodeValues
    );
    for (const row of rows) {
      addAll(filters.seasonIds, [row.season_id]);
      addAll(filters.showIds, [row.show_id]);
    }
    const [episodeCharacterRows] = await dbQuery(
      `SELECT DISTINCT character_id FROM episode_characters WHERE episode_id IN (${placeholders})`,
      episodeValues
    );
    addAll(filters.characterIds, episodeCharacterRows.map((row) => row.character_id));
  }

  if (filters.characterIds.size) {
    const characterValues = Array.from(filters.characterIds);
    const placeholders = characterValues.map(() => '?').join(',');
    const [rows] = await dbQuery(
      `SELECT id, show_id, actor_id FROM characters WHERE id IN (${placeholders})`,
      characterValues
    );
    for (const row of rows) {
      addAll(filters.showIds, [row.show_id]);
      if (row.actor_id != null) {
        filters.actorIds.add(row.actor_id);
      }
    }
  }

  let offset = pagination.offset ?? 0;
  if (pagination.cursorValues && Object.prototype.hasOwnProperty.call(pagination.cursorValues, 'offset')) {
    const cursorOffset = Number(pagination.cursorValues.offset);
    if (!Number.isInteger(cursorOffset) || cursorOffset < 0) {
      return httpError(res, 400, 'page_info is invalid for this resource');
    }
    offset = cursorOffset;
  }
  try {
    const entries = [];
    let hasMore = false;
    const showIds = Array.from(filters.showIds);
    const seasonIds = Array.from(filters.seasonIds);
    const episodeIds = Array.from(filters.episodeIds);
    const characterIds = Array.from(filters.characterIds);
    const actorIds = Array.from(filters.actorIds);

    const appendInCondition = (conditions, params, column, values) => {
      if (!values || !values.length) return;
      conditions.push(`${column} IN (${values.map(() => '?').join(',')})`);
      params.push(...values);
    };

    const datasetOrder = ['shows', 'seasons', 'episodes', 'characters', 'actors', 'episodeCharacters'];
    for (const key of datasetOrder) {
      let sql;
      const params = [];
      if (key === 'shows') {
        sql = 'SELECT * FROM shows';
        const conditions = ['created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        appendInCondition(conditions, params, 'id', showIds);
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY id';
      } else if (key === 'seasons') {
        sql = 'SELECT * FROM seasons';
        const conditions = ['created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        appendInCondition(conditions, params, 'show_id', showIds);
        appendInCondition(conditions, params, 'id', seasonIds);
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY id';
      } else if (key === 'episodes') {
        sql = 'SELECT e.* FROM episodes e JOIN seasons s ON s.id = e.season_id';
        const conditions = ['e.created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        appendInCondition(conditions, params, 's.show_id', showIds);
        appendInCondition(conditions, params, 'e.season_id', seasonIds);
        appendInCondition(conditions, params, 'e.id', episodeIds);
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY e.id';
      } else if (key === 'characters') {
        sql = 'SELECT * FROM characters';
        const conditions = ['created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        appendInCondition(conditions, params, 'show_id', showIds);
        appendInCondition(conditions, params, 'id', characterIds);
        appendInCondition(conditions, params, 'actor_id', actorIds);
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY id';
      } else if (key === 'actors') {
        sql = 'SELECT a.* FROM actors a';
        const conditions = ['a.created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        const includeClauses = [];
        if (actorIds.length) {
          includeClauses.push({
            clause: `a.id IN (${actorIds.map(() => '?').join(',')})`,
            values: actorIds
          });
        }
        if (showIds.length) {
          includeClauses.push({
            clause: `EXISTS (SELECT 1 FROM characters c WHERE c.actor_id = a.id AND c.show_id IN (${showIds.map(() => '?').join(',')}))`,
            values: showIds
          });
        }
        if (characterIds.length) {
          includeClauses.push({
            clause: `EXISTS (SELECT 1 FROM characters c WHERE c.actor_id = a.id AND c.id IN (${characterIds.map(() => '?').join(',')}))`,
            values: characterIds
          });
        }
        if (includeClauses.length) {
          const combined = includeClauses.map((entry) => entry.clause).join(' OR ');
          conditions.push(`(${combined})`);
          for (const entry of includeClauses) {
            params.push(...entry.values);
          }
        }
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY a.id';
      } else if (key === 'episodeCharacters') {
        sql = `SELECT ec.*
               FROM episode_characters ec
               JOIN episodes e ON e.id = ec.episode_id
               JOIN seasons s ON s.id = e.season_id`;
        const conditions = ['ec.created_at BETWEEN ? AND ?'];
        params.push(range.startSql, range.endSql);
        appendInCondition(conditions, params, 's.show_id', showIds);
        appendInCondition(conditions, params, 's.id', seasonIds);
        appendInCondition(conditions, params, 'ec.episode_id', episodeIds);
        appendInCondition(conditions, params, 'ec.character_id', characterIds);
        if (conditions.length) {
          sql += ` WHERE ${conditions.join(' AND ')}`;
        }
        sql += ' ORDER BY ec.id';
      } else {
        continue;
      }

      if (pagination.limit != null) {
        const effectiveLimit = pagination.limit + 1;
        sql += ` LIMIT ${effectiveLimit}`;
        if (!pagination.usingPageInfo) {
          sql += ` OFFSET ${offset}`;
        }
      }

      let rows;
      try {
        [rows] = await dbExecute(sql, params, { retry: false });
      } catch (err) {
        if (err && err.code === 'POOL_CLOSED') {
          await refreshPool();
          [rows] = await dbExecute(sql, params, { retry: false });
        } else {
          throw err;
        }
      }
      if (pagination.limit != null && rows.length > pagination.limit) {
        hasMore ||= true;
        entries.push([key, rows.slice(0, pagination.limit)]);
      } else {
        entries.push([key, rows]);
      }
    }
    if (pagination.limit != null) {
      const links = [];
      const baseParams = new URLSearchParams();
      for (const [key, value] of Object.entries(req.query || {})) {
        if (key === 'offset' || key === 'limit' || key === 'page_info') continue;
        if (Array.isArray(value)) {
          for (const v of value) {
            if (v != null) baseParams.append(key, String(v));
          }
        } else if (value != null) {
          baseParams.append(key, String(value));
        }
      }
      baseParams.set('limit', String(pagination.limit));
      const path = `${req.baseUrl || ''}${req.path}`;
      if (offset > 0) {
        const previousOffset = Math.max(offset - pagination.limit, 0);
        const prevToken = encodePageInfoFromValues('prev', pagination.limit, { offset: previousOffset });
        const params = new URLSearchParams(baseParams.toString());
        params.set('page_info', prevToken);
        const qs = params.toString();
        links.push(`${path}${qs ? `?${qs}` : ''}; rel="previous"`);
      }
      if (hasMore) {
        const nextOffset = offset + pagination.limit;
        const nextToken = encodePageInfoFromValues('next', pagination.limit, { offset: nextOffset });
        const params = new URLSearchParams(baseParams.toString());
        params.set('page_info', nextToken);
        const qs = params.toString();
        links.push(`${path}${qs ? `?${qs}` : ''}; rel="next"`);
      }
      if (links.length) {
        res.set('Link', links.join(', '));
      }
    }
    res.json(Object.fromEntries(entries));
  } catch (err) {
    if (isRetriableDbError(err) || err.code === 'ER_ACCESS_DENIED_ERROR') {
      return httpError(res, 503, 'database temporarily unavailable');
    }
    throw err;
  }
}));

app.post('/admin/database-import', asyncH(async (req, res) => {
  if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body)) {
    return httpError(res, 400, 'body must be an object');
  }
  const datasets = {};
  const expectedKeys = ['actors', 'shows', 'seasons', 'episodes', 'characters', 'episodeCharacters'];
  for (const key of expectedKeys) {
    const raw = req.body[key];
    if (raw == null) {
      datasets[key] = [];
    } else if (!Array.isArray(raw)) {
      return httpError(res, 400, `${key} must be an array`);
    } else {
      datasets[key] = raw;
    }
  }

  const normalizeRecords = {
    actors: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`actors[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `actors[${index}].id`),
        name: requireString(row.name, `actors[${index}].name`),
        created_at: toSqlTimestamp(row.created_at, `actors[${index}].created_at`),
      };
    }),
    shows: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`shows[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `shows[${index}].id`),
        title: requireString(row.title, `shows[${index}].title`),
        description: row.description == null ? null : String(row.description),
        year: toOptionalInteger(row.year, `shows[${index}].year`),
        created_at: toSqlTimestamp(row.created_at, `shows[${index}].created_at`),
      };
    }),
    seasons: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`seasons[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `seasons[${index}].id`),
        show_id: toPositiveInt(row.show_id, `seasons[${index}].show_id`),
        season_number: toNonNegativeInt(row.season_number, `seasons[${index}].season_number`),
        year: toOptionalInteger(row.year, `seasons[${index}].year`),
        created_at: toSqlTimestamp(row.created_at, `seasons[${index}].created_at`),
      };
    }),
    episodes: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`episodes[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `episodes[${index}].id`),
        season_id: toPositiveInt(row.season_id, `episodes[${index}].season_id`),
        air_date: toSqlDate(row.air_date, `episodes[${index}].air_date`),
        title: requireString(row.title, `episodes[${index}].title`),
        description: row.description == null ? null : String(row.description),
        created_at: toSqlTimestamp(row.created_at, `episodes[${index}].created_at`),
      };
    }),
    characters: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`characters[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `characters[${index}].id`),
        show_id: toPositiveInt(row.show_id, `characters[${index}].show_id`),
        name: requireString(row.name, `characters[${index}].name`),
        actor_id: toOptionalPositiveInt(row.actor_id, `characters[${index}].actor_id`),
        created_at: toSqlTimestamp(row.created_at, `characters[${index}].created_at`),
      };
    }),
    episodeCharacters: (rows) => rows.map((row, index) => {
      if (!row || typeof row !== 'object' || Array.isArray(row)) {
        throw exposedError(`episodeCharacters[${index}] must be an object`);
      }
      return {
        id: toPositiveInt(row.id, `episodeCharacters[${index}].id`),
        episode_id: toPositiveInt(row.episode_id, `episodeCharacters[${index}].episode_id`),
        character_id: toPositiveInt(row.character_id, `episodeCharacters[${index}].character_id`),
        created_at: toSqlTimestamp(row.created_at, `episodeCharacters[${index}].created_at`),
      };
    }),
  };

  let normalized;
  try {
    normalized = Object.fromEntries(
      expectedKeys.map((key) => [key, normalizeRecords[key](datasets[key])])
    );
  } catch (err) {
    if (err && err.expose) {
      return httpError(res, 400, err.message);
    }
    throw err;
  }

  const counts = Object.fromEntries(
    expectedKeys.map((key) => [key, normalized[key].length])
  );

  await runWithDbRetry(async () => {
    const poolClient = await ensurePool();
    const conn = await poolClient.getConnection();
    try {
      await conn.beginTransaction();

      for (const row of normalized.actors) {
        await conn.execute(
          'INSERT INTO actors (id, name, created_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE name=VALUES(name), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.name, row.created_at]
        );
      }

      for (const row of normalized.shows) {
        await conn.execute(
          'INSERT INTO shows (id, title, description, year, created_at) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE title=VALUES(title), description=VALUES(description), year=VALUES(year), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.title, row.description, row.year, row.created_at]
        );
      }

      for (const row of normalized.seasons) {
        await conn.execute(
          'INSERT INTO seasons (id, show_id, season_number, year, created_at) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE show_id=VALUES(show_id), season_number=VALUES(season_number), year=VALUES(year), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.show_id, row.season_number, row.year, row.created_at]
        );
      }

      for (const row of normalized.episodes) {
        await conn.execute(
          'INSERT INTO episodes (id, season_id, air_date, title, description, created_at) VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE season_id=VALUES(season_id), air_date=VALUES(air_date), title=VALUES(title), description=VALUES(description), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.season_id, row.air_date, row.title, row.description, row.created_at]
        );
      }

      for (const row of normalized.characters) {
        await conn.execute(
          'INSERT INTO characters (id, show_id, name, actor_id, created_at) VALUES (?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE show_id=VALUES(show_id), name=VALUES(name), actor_id=VALUES(actor_id), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.show_id, row.name, row.actor_id, row.created_at]
        );
      }

      for (const row of normalized.episodeCharacters) {
        await conn.execute(
          'INSERT INTO episode_characters (id, episode_id, character_id, created_at) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE episode_id=VALUES(episode_id), character_id=VALUES(character_id), created_at=COALESCE(VALUES(created_at), created_at)',
          [row.id, row.episode_id, row.character_id, row.created_at]
        );
      }

      await conn.commit();
    } catch (err) {
      try {
        await conn.rollback();
      } catch (rollbackErr) {
        console.error('[db] rollback failed after import error', rollbackErr);
      }
      throw err;
    } finally {
      conn.release();
    }
  });

  res.json({ status: 'imported', counts });
}));

// --------------------------- ACTORS ---------------------------
const ACTOR_LIST_ORDER = [
  { name: 'name', expression: 'name', direction: 'ASC', getValue: (row) => row.name ?? '', toSqlValue: (value) => value ?? '' },
  { name: 'id', expression: 'id', direction: 'ASC', getValue: (row) => row.id }
];

app.post('/actors', asyncH(async (req, res) => {
  const { name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');
  const [result] = await dbExecute(
    'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
    [name]
  );
  const [rows] = await dbExecute('SELECT * FROM actors WHERE id = ?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.get('/actors', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const pagination = parsePagination(req, res); if (!pagination) return;
  const queryInfo = createPaginatedQuery({
    select: 'SELECT * FROM actors',
    where: ['created_at BETWEEN ? AND ?'],
    params: [range.startSql, range.endSql],
    order: ACTOR_LIST_ORDER,
    pagination,
  });
  const [rows] = await dbExecute(queryInfo.sql, queryInfo.params);
  const data = applyPaginationResult({
    req,
    res,
    rows,
    limit: queryInfo.limit,
    cursorDirection: queryInfo.cursorDirection,
    usedCursor: queryInfo.usedCursor,
    pagination,
    order: ACTOR_LIST_ORDER,
  });
  res.json(data);
}));

app.get('/actors/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await dbExecute('SELECT * FROM actors WHERE id = ? AND created_at BETWEEN ? AND ?', [req.params.id, range.startSql, range.endSql]);
  if (!rows.length) return httpError(res, 404, 'actor not found');
  res.json(rows[0]);
}));

app.put('/actors/:id', asyncH(async (req, res) => {
  const { name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');
  const [r] = await dbExecute('UPDATE actors SET name=? WHERE id=?', [name, req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'actor not found');
  const [rows] = await dbExecute('SELECT * FROM actors WHERE id = ?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/actors/:id', asyncH(async (req, res) => {
  const [r] = await dbExecute('DELETE FROM actors WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'actor not found');
  res.status(204).send();
}));

// --------------------------- SHOWS ---------------------------
app.post('/shows', asyncH(async (req, res) => {
  const { title, description, year } = req.body;
  if (!title) return httpError(res, 400, 'title is required');
  const [result] = await dbExecute(
    'INSERT INTO shows (title, description, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE description=VALUES(description), year=VALUES(year), id=LAST_INSERT_ID(id)',
    [title, description || null, year || null]
  );
  const [rows] = await dbExecute('SELECT * FROM shows WHERE id = ?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.get('/shows', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const rows = await runShowQuery(
    { startSql: range.startSql, endSql: range.endSql },
    include,
    pagination,
    { req, res }
  );
  res.json(rows);
}));

app.get('/shows/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const rows = await runShowQuery({ id: req.params.id, startSql: range.startSql, endSql: range.endSql }, include);
  if (!rows.length) return httpError(res, 404, 'show not found');
  res.json(rows[0]);
}));

app.put('/shows/:id', asyncH(async (req, res) => {
  const { title, description, year } = req.body;
  if (!title) return httpError(res, 400, 'title is required');
  const [r] = await dbExecute(
    'UPDATE shows SET title=?, description=?, year=? WHERE id=?',
    [title, description || null, year || null, req.params.id]
  );
  if (!r.affectedRows) return httpError(res, 404, 'show not found');
  const [rows] = await dbExecute('SELECT * FROM shows WHERE id = ?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/shows/:id', asyncH(async (req, res) => {
  const [r] = await dbExecute('DELETE FROM shows WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'show not found');
  res.status(204).send();
}));

// --------------------------- SEASONS ---------------------------
app.post('/shows/:showId/seasons', asyncH(async (req, res) => {
  const { season_number, year } = req.body;
  if (season_number == null) return httpError(res, 400, 'season_number is required');
  const [show] = await dbExecute('SELECT id FROM shows WHERE id=?', [req.params.showId]);
  if (!show.length) return httpError(res, 404, 'show not found');
  const [result] = await dbExecute(
    'INSERT INTO seasons (show_id, season_number, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE year=VALUES(year), id=LAST_INSERT_ID(id)',
    [req.params.showId, season_number, year || null]
  );
  const [rows] = await dbExecute('SELECT * FROM seasons WHERE id=?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

const SEASON_LIST_ORDER = [
  { name: 'season_number', expression: 'season_number', direction: 'ASC', getValue: (row) => row.season_number },
  { name: 'id', expression: 'id', direction: 'ASC', getValue: (row) => row.id }
];

app.get('/shows/:showId/seasons', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const pagination = parsePagination(req, res); if (!pagination) return;
  const queryInfo = createPaginatedQuery({
    select: 'SELECT * FROM seasons',
    where: ['show_id=?', 'created_at BETWEEN ? AND ?'],
    params: [req.params.showId, range.startSql, range.endSql],
    order: SEASON_LIST_ORDER,
    pagination,
  });
  const [rows] = await dbExecute(queryInfo.sql, queryInfo.params);
  const data = applyPaginationResult({
    req,
    res,
    rows,
    limit: queryInfo.limit,
    cursorDirection: queryInfo.cursorDirection,
    usedCursor: queryInfo.usedCursor,
    pagination,
    order: SEASON_LIST_ORDER,
  });
  res.json(data);
}));

app.get('/seasons/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await dbExecute('SELECT * FROM seasons WHERE id=? AND created_at BETWEEN ? AND ?', [req.params.id, range.startSql, range.endSql]);
  if (!rows.length) return httpError(res, 404, 'season not found');
  res.json(rows[0]);
}));

app.put('/seasons/:id', asyncH(async (req, res) => {
  const { season_number, year } = req.body;
  if (season_number == null) return httpError(res, 400, 'season_number is required');
  const [r] = await dbExecute(
    'UPDATE seasons SET season_number=?, year=? WHERE id=?',
    [season_number, year || null, req.params.id]
  );
  if (!r.affectedRows) return httpError(res, 404, 'season not found');
  const [rows] = await dbExecute('SELECT * FROM seasons WHERE id=?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/seasons/:id', asyncH(async (req, res) => {
  const [r] = await dbExecute('DELETE FROM seasons WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'season not found');
  res.status(204).send();
}));

// --------------------------- EPISODES ---------------------------
async function getSeasonIdByShowAndNumber(showId, seasonNumber) {
  const [rows] = await dbExecute(
    'SELECT id FROM seasons WHERE show_id=? AND season_number=?',
    [showId, seasonNumber]
  );
  return rows[0]?.id || null;
}

app.post('/shows/:showId/episodes', asyncH(async (req, res) => {
  const { season_number, air_date, title, description } = req.body;
  if (season_number == null) return httpError(res, 400, 'season_number is required');
  if (!title) return httpError(res, 400, 'title is required');
  const seasonId = await getSeasonIdByShowAndNumber(req.params.showId, season_number);
  if (!seasonId) return httpError(res, 400, 'season does not exist for this show');
  const [result] = await dbExecute(
    'INSERT INTO episodes (season_id, air_date, title, description) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE air_date=VALUES(air_date), description=VALUES(description), id=LAST_INSERT_ID(id)',
    [seasonId, air_date || null, title, description || null]
  );
  const [rows] = await dbExecute(
    `SELECT e.*, s.season_number, s.show_id
     FROM episodes e JOIN seasons s ON s.id=e.season_id
     WHERE e.id=?`,
    [result.insertId]
  );
  res.status(201).json(rows[0]);
}));

app.get('/shows/:showId/episodes', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const rows = await runEpisodeQuery(
    { show_id: req.params.showId, startSql: range.startSql, endSql: range.endSql },
    include,
    pagination,
    { req, res }
  );
  res.json(rows);
}));

// list episodes in a specific season by season id
app.get('/seasons/:id/episodes', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [season] = await dbExecute('SELECT id FROM seasons WHERE id=?', [req.params.id]);
  if (!season.length) return httpError(res, 404, 'season not found');
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const rows = await runEpisodeQuery(
    { season_id: req.params.id, startSql: range.startSql, endSql: range.endSql },
    include,
    pagination,
    { req, res }
  );
  res.json(rows);
}));

// list episodes via show id + season_number
app.get('/shows/:showId/seasons/:seasonNumber/episodes', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const seasonId = await getSeasonIdByShowAndNumber(req.params.showId, req.params.seasonNumber);
  if (!seasonId) return httpError(res, 404, 'season not found for this show');
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const rows = await runEpisodeQuery(
    { season_id: seasonId, startSql: range.startSql, endSql: range.endSql },
    include,
    pagination,
    { req, res }
  );
  res.json(rows);
}));

app.get('/episodes/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const rows = await runEpisodeQuery({ id: req.params.id, startSql: range.startSql, endSql: range.endSql }, include);
  if (!rows.length) return httpError(res, 404, 'episode not found');
  res.json(rows[0]);
}));

app.put('/episodes/:id', asyncH(async (req, res) => {
  const { season_number, air_date, title, description } = req.body;
  let seasonId = null;
  if (season_number != null) {
    const [cur] = await dbExecute(
      'SELECT s.show_id FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?',
      [req.params.id]
    );
    if (!cur.length) return httpError(res, 404, 'episode not found');
    seasonId = await getSeasonIdByShowAndNumber(cur[0].show_id, season_number);
    if (!seasonId) return httpError(res, 400, 'season does not exist for this show');
  }
  const fields = [];
  const params = [];
  if (seasonId != null) { fields.push('season_id=?'); params.push(seasonId); }
  if (air_date !== undefined) { fields.push('air_date=?'); params.push(air_date || null); }
  if (title !== undefined) { fields.push('title=?'); params.push(title || null); }
  if (description !== undefined) { fields.push('description=?'); params.push(description || null); }
  if (!fields.length) return httpError(res, 400, 'no fields to update');
  params.push(req.params.id);
  const [r] = await dbExecute(`UPDATE episodes SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) return httpError(res, 404, 'episode not found');
  const [rows] = await dbExecute(
    `SELECT e.*, s.season_number, s.show_id FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?`,
    [req.params.id]
  );
  res.json(rows[0]);
}));

app.delete('/episodes/:id', asyncH(async (req, res) => {
  const [r] = await dbExecute('DELETE FROM episodes WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'episode not found');
  res.status(204).send();
}));

// --------------------------- CHARACTERS ---------------------------
app.post('/shows/:showId/characters', asyncH(async (req, res) => {
  const { name, actor_id, actor_name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');

  const [show] = await dbExecute('SELECT id FROM shows WHERE id=?', [req.params.showId]);
  if (!show.length) return httpError(res, 404, 'show not found');

  let finalActorId = actor_id || null;
  if (!finalActorId && actor_name) {
    const [r] = await dbExecute(
      'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
      [actor_name]
    );
    finalActorId = r.insertId;
  }

  const [result] = await dbExecute(
    'INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)',
    [req.params.showId, name, finalActorId]
  );
  const [created] = await dbExecute(
    `SELECT c.*, a.name as actor_name
     FROM characters c LEFT JOIN actors a ON a.id=c.actor_id
     WHERE c.id=?`,
    [result.insertId]
  );
  res.status(201).json(created[0]);
}));

app.get('/shows/:showId/characters', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const rows = await runCharacterQuery(
    { show_id: req.params.showId, startSql: range.startSql, endSql: range.endSql },
    include,
    pagination,
    { req, res }
  );
  res.json(rows);
}));

app.get('/characters/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const rows = await runCharacterQuery({ id: req.params.id, startSql: range.startSql, endSql: range.endSql }, include);
  if (!rows.length) return httpError(res, 404, 'character not found');
  res.json(rows[0]);
}));

app.put('/characters/:id', asyncH(async (req, res) => {
  const { name, actor_id, actor_name } = req.body;
  const fields = [];
  const params = [];
  if (name !== undefined) { fields.push('name=?'); params.push(name || null); }
  let finalActorId = actor_id === undefined ? undefined : actor_id;
  if (finalActorId === undefined && actor_name !== undefined) {
    if (actor_name === null) {
      finalActorId = null;
    } else if (actor_name) {
      const [r] = await dbExecute(
        'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
        [actor_name]
      );
      finalActorId = r.insertId;
    }
  }
  if (finalActorId !== undefined) { fields.push('actor_id=?'); params.push(finalActorId); }
  if (!fields.length) return httpError(res, 400, 'no fields to update');
  params.push(req.params.id);
  const [r] = await dbExecute(`UPDATE characters SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) return httpError(res, 404, 'character not found');
  const [rows] = await dbExecute(
    `SELECT c.*, a.name as actor_name FROM characters c LEFT JOIN actors a ON a.id=c.actor_id WHERE c.id=?`,
    [req.params.id]
  );
  res.json(rows[0]);
}));

app.delete('/characters/:id', asyncH(async (req, res) => {
  const [r] = await dbExecute('DELETE FROM characters WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'character not found');
  res.status(204).send();
}));

// --------------------------- EPISODE-CHARACTER LINKS (many-to-many) ---------------------------
async function getEpisodeWithShow(episodeId) {
  const [rows] = await dbExecute(
    `SELECT e.id AS episode_id, s.show_id, s.id AS season_id
     FROM episodes e JOIN seasons s ON s.id = e.season_id
     WHERE e.id = ?`,
    [episodeId]
  );
  return rows[0] || null;
}

async function getCharacterForShow(characterId, showId) {
  const [rows] = await dbExecute(
    'SELECT * FROM characters WHERE id = ? AND show_id = ?',
    [characterId, showId]
  );
  return rows[0] || null;
}

// Add character to episode
app.post('/episodes/:episodeId/characters', asyncH(async (req, res) => {
  const { character_id, character_name, actor_id, actor_name } = req.body || {};
  const ep = await getEpisodeWithShow(req.params.episodeId);
  if (!ep) return httpError(res, 404, 'episode not found');

  let charId = character_id || null;
  if (charId) {
    const ok = await getCharacterForShow(charId, ep.show_id);
    if (!ok) return httpError(res, 400, 'character does not belong to this show');
  } else if (character_name) {
    let finalActorId = actor_id;
    let shouldUpdateActor = actor_id !== undefined || actor_name !== undefined;
    if (actor_name !== undefined) {
      if (actor_name === null) {
        finalActorId = null;
      } else if (actor_name) {
        const [aRows] = await dbExecute('SELECT id FROM actors WHERE name=?', [actor_name]);
        if (aRows.length) {
          finalActorId = aRows[0].id;
        } else {
          const [ins] = await dbExecute(
            'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
            [actor_name]
          );
          finalActorId = ins.insertId;
        }
      }
    }
    if (finalActorId === undefined && !shouldUpdateActor) {
      finalActorId = null;
    }
    const { sql, params } = buildCharacterUpsert({
      showId: ep.show_id,
      name: character_name,
      actorId: finalActorId,
      shouldUpdateActor,
    });
    const [insChar] = await dbExecute(sql, params);
    charId = insChar.insertId;
  } else {
    return httpError(res, 400, 'character_id or character_name is required');
  }

  try {
    const [result] = await dbExecute(
      'INSERT INTO episode_characters (episode_id, character_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)',
      [ep.episode_id, charId]
    );
    const [rows] = await dbExecute(
      `SELECT ec.id, c.id AS character_id, c.name AS character_name, a.name AS actor_name
       FROM episode_characters ec
       JOIN characters c ON c.id = ec.character_id
       LEFT JOIN actors a ON a.id = c.actor_id
       WHERE ec.id = ?`,
      [result.insertId]
    );
    res.status(201).json(rows[0]);
  } catch (e) {
    if (e && e.code === 'ER_DUP_ENTRY') return httpError(res, 409, 'character already linked to this episode');
    throw e;
  }
}));

// List characters for an episode
app.get('/episodes/:episodeId/characters', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const ep = await getEpisodeWithShow(req.params.episodeId);
  if (!ep) return httpError(res, 404, 'episode not found');
  const include = parseIncludeParam(req.query.include);
  const pagination = parsePagination(req, res); if (!pagination) return;
  const queryInfo = createPaginatedQuery({
    select: `SELECT c.id, c.show_id, c.name, c.actor_id, a.name AS actor_name
     FROM episode_characters ec
     JOIN characters c ON c.id = ec.character_id
     LEFT JOIN actors a ON a.id = c.actor_id`,
    where: ['ec.episode_id = ?', 'ec.created_at BETWEEN ? AND ?'],
    params: [ep.episode_id, range.startSql, range.endSql],
    order: CHARACTER_LIST_ORDER,
    pagination,
  });
  const [rawRows] = await dbExecute(queryInfo.sql, queryInfo.params);
  const rows = applyPaginationResult({
    req,
    res,
    rows: rawRows,
    limit: queryInfo.limit,
    cursorDirection: queryInfo.cursorDirection,
    usedCursor: queryInfo.usedCursor,
    pagination,
    order: CHARACTER_LIST_ORDER,
  });
  if (include.actor) {
    const actorIds = [...new Set(rows.map(r => r.actor_id).filter(Boolean))];
    let actorsMap = {};
    if (actorIds.length) {
      const [actors] = await dbQuery(`SELECT id, name FROM actors WHERE id IN (${actorIds.map(() => '?').join(',')})`, actorIds);
      actorsMap = Object.fromEntries(actors.map(a => [a.id, a]));
    }
    return res.json(rows.map(r => ({ id: r.id, show_id: r.show_id, name: r.name, actor_id: r.actor_id, actor: r.actor_id ? actorsMap[r.actor_id] || { id: r.actor_id, name: r.actor_name } : null })));
  }
  res.json(rows.map(r => ({ id: r.id, show_id: r.show_id, name: r.name, actor_id: r.actor_id, actor_name: r.actor_name })));
}));

// Remove character from episode
app.delete('/episodes/:episodeId/characters/:characterId', asyncH(async (req, res) => {
  const ep = await getEpisodeWithShow(req.params.episodeId);
  if (!ep) return httpError(res, 404, 'episode not found');
  const ok = await getCharacterForShow(req.params.characterId, ep.show_id);
  if (!ok) return httpError(res, 400, 'character does not belong to this show');
  const [r] = await dbExecute(
    'DELETE FROM episode_characters WHERE episode_id=? AND character_id=?',
    [ep.episode_id, req.params.characterId]
  );
  if (!r.affectedRows) return httpError(res, 404, 'link not found');
  res.status(204).send();
}));

// --------------------------- JOBS ---------------------------
function nowISO(){ return new Date().toISOString(); }

function refreshJobExpiry(job) {
  if (JOB_TTL_MS > 0) {
    job.expiresAt = Date.now() + JOB_TTL_MS;
  } else {
    delete job.expiresAt;
  }
}

function pruneJobs() {
  if (JOB_TTL_MS <= 0 || jobs.size === 0) return;
  const cutoff = Date.now();
  for (const [id, job] of jobs) {
    if (job.expiresAt && job.expiresAt <= cutoff) {
      jobs.delete(id);
    }
  }
}

function enforceJobHistoryLimit() {
  if (!(MAX_JOB_HISTORY > 0)) return;
  while (jobs.size > MAX_JOB_HISTORY) {
    let oldestId = null;
    let oldestAt = Infinity;
    for (const [id, job] of jobs) {
      const created = job.createdMs || Date.parse(job.created_at) || 0;
      if (created < oldestAt) {
        oldestAt = created;
        oldestId = id;
      }
    }
    if (oldestId) {
      jobs.delete(oldestId);
    } else {
      break;
    }
  }
}

const jobCleanupInterval = JOB_TTL_MS > 0
  ? setInterval(pruneJobs, Math.max(60000, Math.min(JOB_TTL_MS, 300000)))
  : null;
if (jobCleanupInterval && typeof jobCleanupInterval.unref === 'function') {
  jobCleanupInterval.unref();
}

function createJobRecord(type, delay) {
  pruneJobs();
  const jobId = randomUUID();
  const now = Date.now();
  const iso = new Date(now).toISOString();
  const job = {
    id: jobId,
    type,
    status: 'queued',
    created_at: iso,
    updated_at: iso,
    eta_ms: delay,
    result: null,
    rowsCount: null,
    error: null,
    filename: `${type}_query_${jobId}.json`,
    createdMs: now,
  };
  refreshJobExpiry(job);
  jobs.set(jobId, job);
  enforceJobHistoryLimit();
  return job;
}

function formatJobDownloadUrl(job) {
  return `/jobs/${job.id}/download`;
}

function summarizeJob(job) {
  return {
    id: job.id,
    status: job.status,
    eta_ms: job.eta_ms,
    download_url: job.status === 'completed' ? formatJobDownloadUrl(job) : null,
    error: job.error
  };
}

function enqueueJob({ type, delay, run }) {
  const job = createJobRecord(type, delay);
  setTimeout(async () => {
    const current = jobs.get(job.id);
    if (!current) return;
    current.status = 'running';
    current.updated_at = nowISO();
    refreshJobExpiry(current);
    try {
      const result = await run();
      const rows = Array.isArray(result?.rows) ? result.rows : [];
      current.rowsCount = rows.length;
      current.result = Object.prototype.hasOwnProperty.call(result || {}, 'payload') ? result.payload : null;
      current.error = null;
      current.status = 'completed';
      current.updated_at = nowISO();
      refreshJobExpiry(current);
    } catch (e) {
      current.status = 'failed';
      current.error = e && e.message ? e.message : 'unknown error';
      current.updated_at = nowISO();
      refreshJobExpiry(current);
    }
  }, job.eta_ms);
  return job;
}
const SHOW_LIST_ORDER = [
  {
    name: 'year',
    expression: 'COALESCE(year, 2147483647)',
    direction: 'ASC',
    getValue: (row) => row.year,
    toSqlValue: (value) => (value == null ? 2147483647 : value),
  },
  { name: 'title', expression: 'title', direction: 'ASC', getValue: (row) => row.title ?? '' },
  { name: 'id', expression: 'id', direction: 'ASC', getValue: (row) => row.id }
];

async function runShowQuery(filters = {}, include = {}, pagination, pageContext = null) {
  const where = [];
  const params = [];
  if (filters.id != null) { where.push('id = ?'); params.push(filters.id); }
  if (filters.title) { where.push('title LIKE ?'); params.push(`%${filters.title}%`); }
  if (filters.year_min != null) { where.push('year >= ?'); params.push(filters.year_min); }
  if (filters.year_max != null) { where.push('year <= ?'); params.push(filters.year_max); }
  if (filters.episode_title) {
    where.push(`id IN (SELECT s.show_id FROM seasons s JOIN episodes e ON s.id=e.season_id WHERE e.title LIKE ?)`);
    params.push(`%${filters.episode_title}%`);
  }
  if (filters.startSql && filters.endSql) {
    where.push('created_at BETWEEN ? AND ?');
    params.push(filters.startSql, filters.endSql);
  }
  const paginationInfo = pagination || {};
  const query = createPaginatedQuery({
    select: `SELECT id, title, description, year FROM shows`,
    where,
    params,
    order: SHOW_LIST_ORDER,
    pagination: paginationInfo,
  });
  const [rows] = await dbExecute(query.sql, query.params);
  const pagedRows = applyPaginationResult({
    req: pageContext?.req || null,
    res: pageContext?.res || null,
    rows,
    limit: query.limit,
    cursorDirection: query.cursorDirection,
    usedCursor: query.usedCursor,
    pagination: paginationInfo,
    order: SHOW_LIST_ORDER,
  });
  if (include.episodes && pagedRows.length) {
    for (const show of pagedRows) {
      show.episodes = await runEpisodeQuery({ show_id: show.id }, include.episodes);
    }
  }
  return pagedRows;
}

async function runSeasonQuery(filters){
  const where = [];
  const params = [];
  if (filters.show_id != null) { where.push('show_id = ?'); params.push(filters.show_id); }
  if (filters.season_number != null) { where.push('season_number = ?'); params.push(filters.season_number); }
  if (filters.year_min != null) { where.push('year >= ?'); params.push(filters.year_min); }
  if (filters.year_max != null) { where.push('year <= ?'); params.push(filters.year_max); }
  const sql = `SELECT id, show_id, season_number, year FROM seasons ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY show_id, season_number`;
  const [rows] = await dbExecute(sql, params);
  return rows;
}

const EPISODE_LIST_ORDER = [
  {
    name: 'air_date',
    expression: "COALESCE(e.air_date, '9999-12-31')",
    direction: 'ASC',
    getValue: (row) => row.air_date,
    toSqlValue: (value) => (value == null ? '9999-12-31' : value),
  },
  { name: 'id', expression: 'e.id', direction: 'ASC', getValue: (row) => row.id }
];

async function runEpisodeQuery(filters = {}, include = {}, pagination, pageContext = null) {
  const where = [];
  const params = [];
  if (filters.id != null) { where.push('e.id = ?'); params.push(filters.id); }
  if (filters.show_id != null) { where.push('s.show_id = ?'); params.push(filters.show_id); }
  if (filters.season_id != null) { where.push('e.season_id = ?'); params.push(filters.season_id); }
  if (filters.season_number != null) { where.push('s.season_number = ?'); params.push(filters.season_number); }
  if (filters.title) { where.push('e.title LIKE ?'); params.push(`%${filters.title}%`); }
  if (filters.character_name) {
    where.push(`e.id IN (SELECT ec.episode_id FROM episode_characters ec JOIN characters c2 ON c2.id=ec.character_id WHERE c2.name LIKE ?)`);
    params.push(`%${filters.character_name}%`);
  }
  if (filters.startSql && filters.endSql) {
    where.push('e.created_at BETWEEN ? AND ?');
    params.push(filters.startSql, filters.endSql);
  }
  const paginationInfo = pagination || {};
  const query = createPaginatedQuery({
    select: `SELECT e.id, e.season_id, s.show_id, s.season_number, e.air_date, e.title, e.description FROM episodes e JOIN seasons s ON s.id = e.season_id`,
    where,
    params,
    order: EPISODE_LIST_ORDER,
    pagination: paginationInfo,
  });
  const [rows] = await dbExecute(query.sql, query.params);
  const pagedRows = applyPaginationResult({
    req: pageContext?.req || null,
    res: pageContext?.res || null,
    rows,
    limit: query.limit,
    cursorDirection: query.cursorDirection,
    usedCursor: query.usedCursor,
    pagination: paginationInfo,
    order: EPISODE_LIST_ORDER,
  });
  if (include.characters && pagedRows.length) {
    const episodeIds = pagedRows.map(r => r.id);
    const [chars] = await dbQuery(
      `SELECT ec.episode_id, c.id, c.show_id, c.name, c.actor_id, a.name AS actor_name
       FROM episode_characters ec
       JOIN characters c ON c.id = ec.character_id
       LEFT JOIN actors a ON a.id = c.actor_id
       WHERE ec.episode_id IN (${episodeIds.map(() => '?').join(',')})
       ORDER BY c.name`, episodeIds);
    const grouped = {};
    for (const c of chars) {
      const arr = grouped[c.episode_id] || (grouped[c.episode_id] = []);
      if (include.characters.actor && c.actor_id) {
        arr.push({ id: c.id, show_id: c.show_id, name: c.name, actor_id: c.actor_id, actor: { id: c.actor_id, name: c.actor_name } });
      } else {
        arr.push({ id: c.id, show_id: c.show_id, name: c.name, actor_id: c.actor_id, actor_name: c.actor_name });
      }
    }
    for (const ep of pagedRows) {
      ep.characters = grouped[ep.id] || [];
    }
  }
  return pagedRows;
}

const CHARACTER_LIST_ORDER = [
  { name: 'name', expression: 'c.name', direction: 'ASC', getValue: (row) => row.name ?? '', toSqlValue: (value) => value ?? '' },
  { name: 'id', expression: 'c.id', direction: 'ASC', getValue: (row) => row.id }
];

async function runCharacterQuery(filters = {}, include = {}, pagination, pageContext = null) {
  const where = [];
  const params = [];
  if (filters.id != null) { where.push('c.id = ?'); params.push(filters.id); }
  if (filters.show_id != null) { where.push('c.show_id = ?'); params.push(filters.show_id); }
  if (filters.actor_id != null) { where.push('c.actor_id = ?'); params.push(filters.actor_id); }
  if (filters.name) { where.push('c.name LIKE ?'); params.push(`%${filters.name}%`); }
  if (filters.actor_name) { where.push('a.name LIKE ?'); params.push(`%${filters.actor_name}%`); }
  if (filters.startSql && filters.endSql) {
    where.push('c.created_at BETWEEN ? AND ?');
    params.push(filters.startSql, filters.endSql);
  }
  const paginationInfo = pagination || {};
  const query = createPaginatedQuery({
    select: `SELECT c.id, c.show_id, c.name, c.actor_id, a.name AS actor_name FROM characters c LEFT JOIN actors a ON a.id=c.actor_id`,
    where,
    params,
    order: CHARACTER_LIST_ORDER,
    pagination: paginationInfo,
  });
  const [rows] = await dbExecute(query.sql, query.params);
  const pagedRows = applyPaginationResult({
    req: pageContext?.req || null,
    res: pageContext?.res || null,
    rows,
    limit: query.limit,
    cursorDirection: query.cursorDirection,
    usedCursor: query.usedCursor,
    pagination: paginationInfo,
    order: CHARACTER_LIST_ORDER,
  });
  if (include.actor && pagedRows.length) {
    const actorIds = [...new Set(pagedRows.map(r => r.actor_id).filter(Boolean))];
    let actorsMap = {};
    if (actorIds.length) {
      const [actors] = await dbQuery(`SELECT id, name FROM actors WHERE id IN (${actorIds.map(() => '?').join(',')})`, actorIds);
      actorsMap = Object.fromEntries(actors.map(a => [a.id, a]));
    }
    for (const r of pagedRows) {
      r.actor = r.actor_id ? actorsMap[r.actor_id] || { id: r.actor_id, name: r.actor_name } : null;
    }
  }
  return pagedRows;
}

async function runActorQuery(filters){
  const where = [];
  const params = [];
  if (filters.name) { where.push('name LIKE ?'); params.push(`%${filters.name}%`); }
  const sql = `SELECT id, name FROM actors ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY name`;
  const [rows] = await dbExecute(sql, params);
  return rows;
}

// --------------------------- GraphQL ---------------------------
function mapActor(row) {
  return row ? { id: row.id, name: row.name } : null;
}

function mapCharacter(row) {
  if (!row) return null;
  return {
    ...row,
    actor: async () => {
      if (!row.actor_id) return null;
      const [rows] = await dbExecute('SELECT id, name FROM actors WHERE id=?', [row.actor_id]);
      return mapActor(rows[0]);
    }
  };
}

function mapEpisode(row) {
  if (!row) return null;
  return {
    ...row,
    characters: async () => {
      const [chars] = await dbQuery(
        `SELECT c.id, c.show_id, c.name, c.actor_id
         FROM episode_characters ec
         JOIN characters c ON c.id = ec.character_id
         WHERE ec.episode_id=? ORDER BY c.name`, [row.id]
      );
      return chars.map(mapCharacter);
    }
  };
}

function mapSeason(row) {
  if (!row) return null;
  return {
    ...row,
    episodes: async () => {
      const eps = await runEpisodeQuery({ season_id: row.id });
      return eps.map(mapEpisode);
    }
  };
}

function mapShow(row) {
  if (!row) return null;
  return {
    ...row,
    seasons: async () => {
      const [rows] = await dbExecute('SELECT id, show_id, season_number, year FROM seasons WHERE show_id=? ORDER BY season_number', [row.id]);
      return rows.map(mapSeason);
    },
    episodes: async () => {
      const eps = await runEpisodeQuery({ show_id: row.id });
      return eps.map(mapEpisode);
    },
    characters: async () => {
      const chars = await runCharacterQuery({ show_id: row.id });
      return chars.map(mapCharacter);
    }
  };
}

function rootJobStart(type, input, runner) {
  const { delay_ms, include, ...filters } = input || {};
  const includeTree = parseIncludeParam(include);
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type,
    delay,
    run: async () => {
      const rows = await runner(filters, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { ...filters, include }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  return summarizeJob(job);
}

const graphqlOperations = {};

function registerOperation(name, argNames, resolver) {
  graphqlOperations[name] = { argNames, resolver };
}

registerOperation('health', [], async () => {
  try {
    const [rows] = await dbQuery('SELECT 1 AS ok');
    return { ok: true, db: rows[0].ok === 1 };
  } catch {
    return { ok: false, db: false };
  }
});

registerOperation('actors', [], async () => (await runActorQuery({})).map(mapActor));

registerOperation('actor', ['id'], async ({ id }) => {
  const [rows] = await dbExecute('SELECT id, name FROM actors WHERE id=?', [id]);
  return mapActor(rows[0]);
});

registerOperation('shows', [], async () => (await runShowQuery()).map(mapShow));

registerOperation('show', ['id'], async ({ id }) => mapShow((await runShowQuery({ id }))[0]));

registerOperation('seasons', ['show_id'], async ({ show_id }) => (await runSeasonQuery({ show_id })).map(mapSeason));

registerOperation('season', ['id'], async ({ id }) => {
  const [rows] = await dbExecute('SELECT id, show_id, season_number, year FROM seasons WHERE id=?', [id]);
  return mapSeason(rows[0]);
});

registerOperation('episodes', ['show_id', 'season_id'], async ({ show_id, season_id }) => (await runEpisodeQuery({ show_id, season_id })).map(mapEpisode));

registerOperation('episode', ['id'], async ({ id }) => mapEpisode((await runEpisodeQuery({ id }))[0]));

registerOperation('characters', ['show_id'], async ({ show_id }) => (await runCharacterQuery({ show_id })).map(mapCharacter));

registerOperation('character', ['id'], async ({ id }) => mapCharacter((await runCharacterQuery({ id }))[0]));

registerOperation('job', ['id'], async ({ id }) => {
  pruneJobs();
  const j = jobs.get(id);
  if (!j) return null;
  refreshJobExpiry(j);
  return {
    id: j.id,
    status: j.status,
    eta_ms: j.eta_ms,
    download_url: j.status === 'completed' ? formatJobDownloadUrl(j) : null,
    error: j.error
  };
});

registerOperation('jobResult', ['id'], async ({ id }) => {
  pruneJobs();
  const j = jobs.get(id);
  if (!j || j.status !== 'completed') return null;
  refreshJobExpiry(j);
  return j.result ? j.result.toString() : null;
});

registerOperation('init', [], async () => {
  await initDatabase();
  await refreshPool();
  return true;
});

registerOperation('createActor', ['name'], async ({ name }) => {
  const [result] = await dbExecute(
    'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
    [name]
  );
  const [rows] = await dbExecute('SELECT id, name FROM actors WHERE id=?', [result.insertId]);
  return mapActor(rows[0] || { id: result.insertId, name });
});

registerOperation('updateActor', ['id', 'name'], async ({ id, name }) => {
  const [r] = await dbExecute('UPDATE actors SET name=? WHERE id=?', [name, id]);
  if (!r.affectedRows) throw exposedError('actor not found');
  const [rows] = await dbExecute('SELECT id, name FROM actors WHERE id=?', [id]);
  return mapActor(rows[0] || { id, name });
});

registerOperation('deleteActor', ['id'], async ({ id }) => {
  const [r] = await dbExecute('DELETE FROM actors WHERE id=?', [id]);
  return r.affectedRows > 0;
});

registerOperation('createShow', ['title', 'description', 'year'], async ({ title, description, year }) => {
  const [result] = await dbExecute(
    'INSERT INTO shows (title, description, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE description=VALUES(description), year=VALUES(year), id=LAST_INSERT_ID(id)',
    [title, description || null, year || null]
  );
  const [rows] = await dbExecute('SELECT id, title, description, year FROM shows WHERE id=?', [result.insertId]);
  return mapShow(rows[0] || { id: result.insertId, title, description, year });
});

registerOperation('updateShow', ['id', 'title', 'description', 'year'], async ({ id, title, description, year }) => {
  const [r] = await dbExecute('UPDATE shows SET title=?, description=?, year=? WHERE id=?', [title, description || null, year || null, id]);
  if (!r.affectedRows) throw exposedError('show not found');
  const [rows] = await dbExecute('SELECT id, title, description, year FROM shows WHERE id=?', [id]);
  return mapShow(rows[0] || { id, title, description, year });
});

registerOperation('deleteShow', ['id'], async ({ id }) => {
  const [r] = await dbExecute('DELETE FROM shows WHERE id=?', [id]);
  return r.affectedRows > 0;
});

registerOperation('createSeason', ['show_id', 'season_number', 'year'], async ({ show_id, season_number, year }) => {
  const [show] = await dbExecute('SELECT id FROM shows WHERE id=?', [show_id]);
  if (!show.length) throw exposedError('show not found');
  const [result] = await dbExecute(
    'INSERT INTO seasons (show_id, season_number, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE year=VALUES(year), id=LAST_INSERT_ID(id)',
    [show_id, season_number, year || null]
  );
  const [rows] = await dbExecute('SELECT id, show_id, season_number, year FROM seasons WHERE id=?', [result.insertId]);
  return mapSeason(rows[0] || { id: result.insertId, show_id, season_number, year });
});

registerOperation('updateSeason', ['id', 'season_number', 'year'], async ({ id, season_number, year }) => {
  const [r] = await dbExecute('UPDATE seasons SET season_number=?, year=? WHERE id=?', [season_number, year || null, id]);
  if (!r.affectedRows) throw exposedError('season not found');
  const [rows] = await dbExecute('SELECT id, show_id, season_number, year FROM seasons WHERE id=?', [id]);
  return mapSeason(rows[0] || { id, season_number, year });
});

registerOperation('deleteSeason', ['id'], async ({ id }) => {
  const [r] = await dbExecute('DELETE FROM seasons WHERE id=?', [id]);
  return r.affectedRows > 0;
});

registerOperation('createEpisode', ['show_id', 'season_number', 'air_date', 'title', 'description'], async ({ show_id, season_number, air_date, title, description }) => {
  const seasonId = await getSeasonIdByShowAndNumber(show_id, season_number);
  if (!seasonId) throw exposedError('season does not exist for this show');
  const [result] = await dbExecute(
    'INSERT INTO episodes (season_id, air_date, title, description) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE air_date=VALUES(air_date), description=VALUES(description), id=LAST_INSERT_ID(id)',
    [seasonId, air_date || null, title, description || null]
  );
  const [rows] = await dbExecute(
    `SELECT e.id, e.season_id, s.show_id, s.season_number, e.air_date, e.title, e.description FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?`,
    [result.insertId]
  );
  return mapEpisode(rows[0] || { id: result.insertId, season_id: seasonId, show_id, season_number, air_date, title, description });
});

registerOperation('updateEpisode', ['id', 'season_number', 'air_date', 'title', 'description'], async ({ id, season_number, air_date, title, description }) => {
  let seasonId = null;
  if (season_number != null) {
    const [cur] = await dbExecute('SELECT s.show_id FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?', [id]);
    if (!cur.length) throw exposedError('episode not found');
    seasonId = await getSeasonIdByShowAndNumber(cur[0].show_id, season_number);
    if (!seasonId) throw exposedError('season does not exist for this show');
  }
  const fields = [];
  const params = [];
  if (seasonId != null) { fields.push('season_id=?'); params.push(seasonId); }
  if (air_date !== undefined) { fields.push('air_date=?'); params.push(air_date || null); }
  if (title !== undefined) { fields.push('title=?'); params.push(title || null); }
  if (description !== undefined) { fields.push('description=?'); params.push(description || null); }
  if (!fields.length) throw exposedError('no fields to update');
  params.push(id);
  const [r] = await dbExecute(`UPDATE episodes SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) throw exposedError('episode not found');
  const [rows] = await dbExecute(
    `SELECT e.id, e.season_id, s.show_id, s.season_number, e.air_date, e.title, e.description FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?`,
    [id]
  );
  return mapEpisode(rows[0] || { id, season_id: seasonId, air_date, title, description });
});

registerOperation('deleteEpisode', ['id'], async ({ id }) => {
  const [r] = await dbExecute('DELETE FROM episodes WHERE id=?', [id]);
  return r.affectedRows > 0;
});

registerOperation('createCharacter', ['show_id', 'name', 'actor_id', 'actor_name'], async ({ show_id, name, actor_id, actor_name }) => {
  let finalActorId = actor_id || null;
  if (!finalActorId && actor_name) {
    const [r] = await dbExecute('INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)', [actor_name]);
    finalActorId = r.insertId;
  }
  const [result] = await dbExecute('INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)', [show_id, name, finalActorId]);
  const [rows] = await dbExecute('SELECT c.id, c.show_id, c.name, c.actor_id FROM characters c WHERE c.id=?', [result.insertId]);
  return mapCharacter(rows[0] || { id: result.insertId, show_id, name, actor_id: finalActorId });
});

registerOperation('updateCharacter', ['id', 'name', 'actor_id', 'actor_name'], async ({ id, name, actor_id, actor_name }) => {
  const fields = [];
  const params = [];
  if (name !== undefined) { fields.push('name=?'); params.push(name || null); }
  let finalActorId = actor_id === undefined ? undefined : actor_id;
  if (finalActorId === undefined && actor_name !== undefined) {
    if (actor_name === null) {
      finalActorId = null;
    } else if (actor_name) {
      const [r] = await dbExecute('INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)', [actor_name]);
      finalActorId = r.insertId;
    }
  }
  if (finalActorId !== undefined) { fields.push('actor_id=?'); params.push(finalActorId); }
  if (!fields.length) throw exposedError('no fields to update');
  params.push(id);
  const [r] = await dbExecute(`UPDATE characters SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) throw exposedError('character not found');
  const [rows] = await dbExecute('SELECT c.id, c.show_id, c.name, c.actor_id FROM characters c WHERE c.id=?', [id]);
  return mapCharacter(rows[0] || { id, name, actor_id: finalActorId });
});

registerOperation('deleteCharacter', ['id'], async ({ id }) => {
  const [r] = await dbExecute('DELETE FROM characters WHERE id=?', [id]);
  return r.affectedRows > 0;
});

registerOperation('addCharacterToEpisode', ['episode_id', 'character_id', 'character_name', 'actor_id', 'actor_name'], async ({ episode_id, character_id, character_name, actor_id, actor_name }) => {
  let charId = character_id || null;
  if (!charId) {
    const [ep] = await dbExecute('SELECT s.show_id FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?', [episode_id]);
    if (!ep.length) throw exposedError('episode not found');
    let actId = actor_id || null;
    if (!actId && actor_name) {
      const [r] = await dbExecute('INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)', [actor_name]);
      actId = r.insertId;
    }
    const [cr] = await dbExecute('INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)', [ep[0].show_id, character_name, actId]);
    charId = cr.insertId;
  }
  await dbExecute('INSERT IGNORE INTO episode_characters (episode_id, character_id) VALUES (?, ?)', [episode_id, charId]);
  const [rows] = await dbQuery('SELECT c.id, c.show_id, c.name, c.actor_id FROM characters c WHERE c.id=?', [charId]);
  return mapCharacter(rows[0] || { id: charId });
});

registerOperation('removeCharacterFromEpisode', ['episode_id', 'character_id'], async ({ episode_id, character_id }) => {
  const [r] = await dbExecute('DELETE FROM episode_characters WHERE episode_id=? AND character_id=?', [episode_id, character_id]);
  return r.affectedRows > 0;
});

registerOperation('startShowsJob', ['delay_ms', 'include', 'title', 'year_min', 'year_max', 'episode_title'], async (args) => rootJobStart('shows', args, (filters, includeTree) => runShowQuery(filters, includeTree)));

registerOperation('startSeasonsJob', ['delay_ms', 'show_id', 'season_number', 'year_min', 'year_max'], async (args) => rootJobStart('seasons', args, (filters) => runSeasonQuery(filters)));

registerOperation('startEpisodesJob', ['delay_ms', 'include', 'show_id', 'season_number', 'title', 'character_name'], async (args) => rootJobStart('episodes', args, (filters, includeTree) => runEpisodeQuery(filters, includeTree)));

registerOperation('startCharactersJob', ['delay_ms', 'include', 'show_id', 'name', 'actor_id', 'actor_name'], async (args) => rootJobStart('characters', args, (filters, includeTree) => runCharacterQuery(filters, includeTree)));

registerOperation('startActorsJob', ['delay_ms', 'name'], async (args) => rootJobStart('actors', args, (filters) => runActorQuery(filters)));

registerOperation('deleteJob', ['id'], async ({ id }) => {
  pruneJobs();
  if (!jobs.has(id)) return false;
  jobs.delete(id);
  return true;
});

async function resolveFunctions(val) {
  if (Array.isArray(val)) return Promise.all(val.map(resolveFunctions));
  if (val && typeof val === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(val)) {
      if (typeof v === 'function') {
        out[k] = await resolveFunctions(await v());
      } else {
        out[k] = await resolveFunctions(v);
      }
    }
    return out;
  }
  return val;
}

function parseGraphQL(query) {
  try {
    return parseGraphQLQuery(query);
  } catch (err) {
    if (err && err.expose) throw err;
    const message = err instanceof Error ? err.message : 'Invalid query';
    throw exposedError(message);
  }
}

function formatGraphQLError(err) {
  if (err && err.expose) {
    return { message: err.message };
  }
  console.error('[graphql] internal error', err);
  return { message: 'Internal server error' };
}

app.get(['/graphql.json', '/.well-known/graphql.json'], (req, res) => {
  const operations = {};
  for (const [name, op] of Object.entries(graphqlOperations)) {
    operations[name] = op.argNames;
  }
  res.json({ version: pkg.version, operations });
});

app.post('/graphql', asyncH(async (req, res) => {
  const { query } = req.body || {};
  if (typeof query !== 'string') {
    return res.status(400).json({ errors: [{ message: 'query must be string' }] });
  }
  let parsed;
  try {
    parsed = parseGraphQL(query);
  } catch (err) {
    return res.status(200).json({ data: null, errors: [formatGraphQLError(err)] });
  }
  const operation = graphqlOperations[parsed.field];
  if (!operation) {
    const data = {};
    data[parsed.alias] = null;
    return res.status(200).json({ data, errors: [formatGraphQLError(exposedError(`Unknown field "${parsed.field}"`))] });
  }
  try {
    const result = await operation.resolver(parsed.args || {});
    const data = {};
    data[parsed.alias] = await resolveFunctions(result);
    res.json({ data });
  } catch (err) {
    const data = {};
    data[parsed.alias] = null;
    res.status(200).json({ data, errors: [formatGraphQLError(err)] });
  }
}));

app.post('/shows/query-jobs', asyncH(async (req, res) => {
  const { title, year_min, year_max, episode_title, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type: 'shows',
    delay,
    run: async () => {
      const rows = await runShowQuery({ title, year_min, year_max, episode_title }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { title, year_min, year_max, episode_title, include }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  const summary = summarizeJob(job);
  res.status(202).json({ job_id: summary.id, status: summary.status, eta_ms: summary.eta_ms, poll_url: `/jobs/${job.id}`, download_url: summary.download_url });
}));

app.post('/seasons/query-jobs', asyncH(async (req, res) => {
  const { show_id, season_number, year_min, year_max, delay_ms } = req.body || {};
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type: 'seasons',
    delay,
    run: async () => {
      const rows = await runSeasonQuery({ show_id, season_number, year_min, year_max });
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, season_number, year_min, year_max }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  const summary = summarizeJob(job);
  res.status(202).json({ job_id: summary.id, status: summary.status, eta_ms: summary.eta_ms, poll_url: `/jobs/${job.id}`, download_url: summary.download_url });
}));

app.post('/episodes/query-jobs', asyncH(async (req, res) => {
  const { show_id, season_number, title, character_name, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type: 'episodes',
    delay,
    run: async () => {
      const rows = await runEpisodeQuery({ show_id, season_number, title, character_name }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, season_number, title, character_name, include }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  const summary = summarizeJob(job);
  res.status(202).json({ job_id: summary.id, status: summary.status, eta_ms: summary.eta_ms, poll_url: `/jobs/${job.id}`, download_url: summary.download_url });
}));

app.post('/characters/query-jobs', asyncH(async (req, res) => {
  const { show_id, name, actor_id, actor_name, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type: 'characters',
    delay,
    run: async () => {
      const rows = await runCharacterQuery({ show_id, name, actor_id, actor_name }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, name, actor_id, actor_name, include }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  const summary = summarizeJob(job);
  res.status(202).json({ job_id: summary.id, status: summary.status, eta_ms: summary.eta_ms, poll_url: `/jobs/${job.id}`, download_url: summary.download_url });
}));

app.post('/actors/query-jobs', asyncH(async (req, res) => {
  const { name, delay_ms } = req.body || {};
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = enqueueJob({
    type: 'actors',
    delay,
    run: async () => {
      const rows = await runActorQuery({ name });
      const payload = Buffer.from(JSON.stringify({ filters: { name }, count: rows.length, rows }, null, 2));
      return { rows, payload };
    }
  });
  const summary = summarizeJob(job);
  res.status(202).json({ job_id: summary.id, status: summary.status, eta_ms: summary.eta_ms, poll_url: `/jobs/${job.id}`, download_url: summary.download_url });
}));

app.get('/jobs/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  pruneJobs();
  const job = jobs.get(req.params.id);
  if (!job) return httpError(res, 404, 'job not found');
  const created = new Date(job.created_at);
  if (created < range.start || created > range.end) return httpError(res, 404, 'job not found');
  refreshJobExpiry(job);
  res.json({ id: job.id, status: job.status, created_at: job.created_at, updated_at: job.updated_at, eta_ms: job.eta_ms, rows: job.rowsCount, error: job.error, download_url: job.status === 'completed' ? formatJobDownloadUrl(job) : null });
}));

app.get('/jobs/:id/download', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  pruneJobs();
  const job = jobs.get(req.params.id);
  if (!job) return httpError(res, 404, 'job not found');
  const created = new Date(job.created_at);
  if (created < range.start || created > range.end) return httpError(res, 404, 'job not found');
  if (job.status !== 'completed') return httpError(res, 409, `job not ready (status=${job.status})`);
  refreshJobExpiry(job);
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Disposition', `attachment; filename="${job.filename}"`);
  res.send(job.result);
}));

app.delete('/jobs/:id', asyncH(async (req, res) => {
  pruneJobs();
  if (!jobs.has(req.params.id)) return httpError(res, 404, 'job not found');
  jobs.delete(req.params.id);
  res.status(204).send();
}));

// --------------------------- bootstrap ---------------------------
(async () => {
  try {
    await initDatabase();
    await refreshPool();
    app.listen(PORT, () => { console.log(`API listening on http://localhost:${PORT}`); });
  } catch (err) {
    console.error('Failed to initialize database', err);
    process.exit(1);
  }
})();
