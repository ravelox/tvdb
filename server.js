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
require('dotenv').config();

const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const DB_HOST = process.env.DB_HOST || 'localhost';
const DB_PORT = process.env.DB_PORT ? Number(process.env.DB_PORT) : 3306;
const DB_USER = process.env.DB_USER || 'root';
const DB_PASSWORD = process.env.DB_PASSWORD || '';
const DB_NAME = process.env.DB_NAME || 'tvdb';

async function initDatabase() {
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
}

let pool;

const app = express();
app.use(express.json());
app.use(morgan('dev'));

function httpError(res, code, message) { return res.status(code).json({ error: message }); }
const asyncH = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const DATE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:?\d{2})$/;
function parseDateRange(req, res) {
  const { start, end } = req.query;
  const earliest = new Date('1000-01-01T00:00:00+00:00');
  const latest = new Date('9999-12-31T23:59:59+00:00');
  let startDate = earliest;
  let endDate = latest;
  if (start) {
    if (!DATE_RE.test(start) || isNaN(Date.parse(start))) return httpError(res, 400, 'invalid start date');
    startDate = new Date(start);
  }
  if (end) {
    if (!DATE_RE.test(end) || isNaN(Date.parse(end))) return httpError(res, 400, 'invalid end date');
    endDate = new Date(end);
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

// --------------------------- OpenAPI discovery ---------------------------
const openapiBase = {
  openapi: '3.0.3',
  info: {
    title: 'TV Shows API',
    version: '1.0.5',
    description: 'CRUD for shows/seasons/episodes/characters/actors, episode↔character links, and query jobs.'
  },
  servers: [], // populated dynamically per request
  tags: [
    { name: 'health' }, { name: 'actors' }, { name: 'shows' }, { name: 'seasons' },
    { name: 'episodes' }, { name: 'characters' }, { name: 'links' }, { name: 'jobs' }
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
    '/init': { post: { tags:['health'], summary:'Initialize DB/schema', responses:{ '200':{ description:'Initialized' } } } },

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
for (const ops of Object.values(openapiBase.paths)) {
  for (const [method, op] of Object.entries(ops)) {
    if (method === 'get') {
      op.parameters = [...(op.parameters || []), ...dateRangeParams, includeParam];
    }
  }
}

app.get(['/openapi.json', '/spec', '/.well-known/openapi.json'], (req, res) => {
  const base = `${req.protocol}://${req.get('host')}`;
  const doc = { ...openapiBase, servers: [{ url: base }] };
  res.json(doc);
});

try {
  const swaggerUi = require('swagger-ui-express');
  app.use('/docs', swaggerUi.serve, swaggerUi.setup(null, {
    explorer: true,
    swaggerOptions: { url: '/openapi.json' }
  }));
  console.log('[docs] Swagger UI available at /docs');
} catch (e) {
  console.log('[docs] Install swagger-ui-express to enable /docs');
}

// --------------------------- Health ---------------------------
app.get('/health', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  try {
    const [rows] = await pool.query('SELECT 1 AS ok');
    res.json({ ok: true, db: rows[0].ok === 1 });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
}));

app.post('/init', asyncH(async (_req, res) => {
  await initDatabase();
  pool = mysql.createPool({
    host: DB_HOST, port: DB_PORT, user: DB_USER, password: DB_PASSWORD, database: DB_NAME,
    waitForConnections: true, connectionLimit: 10, queueLimit: 0
  });
  res.json({ status: 'initialized' });
}));

// --------------------------- ACTORS ---------------------------
app.post('/actors', asyncH(async (req, res) => {
  const { name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');
  const [result] = await pool.execute(
    'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
    [name]
  );
  const [rows] = await pool.execute('SELECT * FROM actors WHERE id = ?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.get('/actors', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await pool.execute('SELECT * FROM actors WHERE created_at BETWEEN ? AND ? ORDER BY name', [range.startSql, range.endSql]);
  res.json(rows);
}));

app.get('/actors/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await pool.execute('SELECT * FROM actors WHERE id = ? AND created_at BETWEEN ? AND ?', [req.params.id, range.startSql, range.endSql]);
  if (!rows.length) return httpError(res, 404, 'actor not found');
  res.json(rows[0]);
}));

app.put('/actors/:id', asyncH(async (req, res) => {
  const { name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');
  const [r] = await pool.execute('UPDATE actors SET name=? WHERE id=?', [name, req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'actor not found');
  const [rows] = await pool.execute('SELECT * FROM actors WHERE id = ?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/actors/:id', asyncH(async (req, res) => {
  const [r] = await pool.execute('DELETE FROM actors WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'actor not found');
  res.status(204).send();
}));

// --------------------------- SHOWS ---------------------------
app.post('/shows', asyncH(async (req, res) => {
  const { title, description, year } = req.body;
  if (!title) return httpError(res, 400, 'title is required');
  const [result] = await pool.execute(
    'INSERT INTO shows (title, description, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE description=VALUES(description), year=VALUES(year), id=LAST_INSERT_ID(id)',
    [title, description || null, year || null]
  );
  const [rows] = await pool.execute('SELECT * FROM shows WHERE id = ?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.get('/shows', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const include = parseIncludeParam(req.query.include);
  const rows = await runShowQuery({ startSql: range.startSql, endSql: range.endSql }, include);
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
  const [r] = await pool.execute(
    'UPDATE shows SET title=?, description=?, year=? WHERE id=?',
    [title, description || null, year || null, req.params.id]
  );
  if (!r.affectedRows) return httpError(res, 404, 'show not found');
  const [rows] = await pool.execute('SELECT * FROM shows WHERE id = ?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/shows/:id', asyncH(async (req, res) => {
  const [r] = await pool.execute('DELETE FROM shows WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'show not found');
  res.status(204).send();
}));

// --------------------------- SEASONS ---------------------------
app.post('/shows/:showId/seasons', asyncH(async (req, res) => {
  const { season_number, year } = req.body;
  if (season_number == null) return httpError(res, 400, 'season_number is required');
  const [show] = await pool.execute('SELECT id FROM shows WHERE id=?', [req.params.showId]);
  if (!show.length) return httpError(res, 404, 'show not found');
  const [result] = await pool.execute(
    'INSERT INTO seasons (show_id, season_number, year) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE year=VALUES(year), id=LAST_INSERT_ID(id)',
    [req.params.showId, season_number, year || null]
  );
  const [rows] = await pool.execute('SELECT * FROM seasons WHERE id=?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.get('/shows/:showId/seasons', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await pool.execute(
    'SELECT * FROM seasons WHERE show_id=? AND created_at BETWEEN ? AND ? ORDER BY season_number',
    [req.params.showId, range.startSql, range.endSql]
  );
  res.json(rows);
}));

app.get('/seasons/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [rows] = await pool.execute('SELECT * FROM seasons WHERE id=? AND created_at BETWEEN ? AND ?', [req.params.id, range.startSql, range.endSql]);
  if (!rows.length) return httpError(res, 404, 'season not found');
  res.json(rows[0]);
}));

app.put('/seasons/:id', asyncH(async (req, res) => {
  const { season_number, year } = req.body;
  if (season_number == null) return httpError(res, 400, 'season_number is required');
  const [r] = await pool.execute(
    'UPDATE seasons SET season_number=?, year=? WHERE id=?',
    [season_number, year || null, req.params.id]
  );
  if (!r.affectedRows) return httpError(res, 404, 'season not found');
  const [rows] = await pool.execute('SELECT * FROM seasons WHERE id=?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/seasons/:id', asyncH(async (req, res) => {
  const [r] = await pool.execute('DELETE FROM seasons WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'season not found');
  res.status(204).send();
}));

// --------------------------- EPISODES ---------------------------
async function getSeasonIdByShowAndNumber(showId, seasonNumber) {
  const [rows] = await pool.execute(
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
  const [result] = await pool.execute(
    'INSERT INTO episodes (season_id, air_date, title, description) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE air_date=VALUES(air_date), description=VALUES(description), id=LAST_INSERT_ID(id)',
    [seasonId, air_date || null, title, description || null]
  );
  const [rows] = await pool.execute(
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
  const rows = await runEpisodeQuery({ show_id: req.params.showId, startSql: range.startSql, endSql: range.endSql }, include);
  res.json(rows);
}));

// list episodes in a specific season by season id
app.get('/seasons/:id/episodes', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const [season] = await pool.execute('SELECT id FROM seasons WHERE id=?', [req.params.id]);
  if (!season.length) return httpError(res, 404, 'season not found');
  const include = parseIncludeParam(req.query.include);
  const rows = await runEpisodeQuery({ season_id: req.params.id, startSql: range.startSql, endSql: range.endSql }, include);
  res.json(rows);
}));

// list episodes via show id + season_number
app.get('/shows/:showId/seasons/:seasonNumber/episodes', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const seasonId = await getSeasonIdByShowAndNumber(req.params.showId, req.params.seasonNumber);
  if (!seasonId) return httpError(res, 404, 'season not found for this show');
  const include = parseIncludeParam(req.query.include);
  const rows = await runEpisodeQuery({ season_id: seasonId, startSql: range.startSql, endSql: range.endSql }, include);
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
    const [cur] = await pool.execute(
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
  const [r] = await pool.execute(`UPDATE episodes SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) return httpError(res, 404, 'episode not found');
  const [rows] = await pool.execute(
    `SELECT e.*, s.season_number, s.show_id FROM episodes e JOIN seasons s ON s.id=e.season_id WHERE e.id=?`,
    [req.params.id]
  );
  res.json(rows[0]);
}));

app.delete('/episodes/:id', asyncH(async (req, res) => {
  const [r] = await pool.execute('DELETE FROM episodes WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'episode not found');
  res.status(204).send();
}));

// --------------------------- CHARACTERS ---------------------------
app.post('/shows/:showId/characters', asyncH(async (req, res) => {
  const { name, actor_id, actor_name } = req.body;
  if (!name) return httpError(res, 400, 'name is required');

  const [show] = await pool.execute('SELECT id FROM shows WHERE id=?', [req.params.showId]);
  if (!show.length) return httpError(res, 404, 'show not found');

  let finalActorId = actor_id || null;
  if (!finalActorId && actor_name) {
    const [r] = await pool.execute(
      'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
      [actor_name]
    );
    finalActorId = r.insertId;
  }

  const [result] = await pool.execute(
    'INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)',
    [req.params.showId, name, finalActorId]
  );
  const [created] = await pool.execute(
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
  const rows = await runCharacterQuery({ show_id: req.params.showId, startSql: range.startSql, endSql: range.endSql }, include);
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
      const [r] = await pool.execute(
        'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
        [actor_name]
      );
      finalActorId = r.insertId;
    }
  }
  if (finalActorId !== undefined) { fields.push('actor_id=?'); params.push(finalActorId); }
  if (!fields.length) return httpError(res, 400, 'no fields to update');
  params.push(req.params.id);
  const [r] = await pool.execute(`UPDATE characters SET ${fields.join(', ')} WHERE id=?`, params);
  if (!r.affectedRows) return httpError(res, 404, 'character not found');
  const [rows] = await pool.execute(
    `SELECT c.*, a.name as actor_name FROM characters c LEFT JOIN actors a ON a.id=c.actor_id WHERE c.id=?`,
    [req.params.id]
  );
  res.json(rows[0]);
}));

app.delete('/characters/:id', asyncH(async (req, res) => {
  const [r] = await pool.execute('DELETE FROM characters WHERE id=?', [req.params.id]);
  if (!r.affectedRows) return httpError(res, 404, 'character not found');
  res.status(204).send();
}));

// --------------------------- EPISODE-CHARACTER LINKS (many-to-many) ---------------------------
async function getEpisodeWithShow(episodeId) {
  const [rows] = await pool.execute(
    `SELECT e.id AS episode_id, s.show_id, s.id AS season_id
     FROM episodes e JOIN seasons s ON s.id = e.season_id
     WHERE e.id = ?`,
    [episodeId]
  );
  return rows[0] || null;
}

async function getCharacterForShow(characterId, showId) {
  const [rows] = await pool.execute(
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
    let finalActorId = actor_id || null;
    if (!finalActorId && actor_name) {
      const [aRows] = await pool.execute('SELECT id FROM actors WHERE name=?', [actor_name]);
      if (aRows.length) finalActorId = aRows[0].id;
      else {
        const [ins] = await pool.execute(
          'INSERT INTO actors (name) VALUES (?) ON DUPLICATE KEY UPDATE name=VALUES(name), id=LAST_INSERT_ID(id)',
          [actor_name]
        );
        finalActorId = ins.insertId;
      }
    }
    const [insChar] = await pool.execute(
      'INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)',
      [ep.show_id, character_name, finalActorId]
    );
    charId = insChar.insertId;
  } else {
    return httpError(res, 400, 'character_id or character_name is required');
  }

  try {
    const [result] = await pool.execute(
      'INSERT INTO episode_characters (episode_id, character_id) VALUES (?, ?) ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)',
      [ep.episode_id, charId]
    );
    const [rows] = await pool.execute(
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
  const [rows] = await pool.execute(
    `SELECT c.id, c.show_id, c.name, c.actor_id, a.name AS actor_name
     FROM episode_characters ec
     JOIN characters c ON c.id = ec.character_id
     LEFT JOIN actors a ON a.id = c.actor_id
     WHERE ec.episode_id = ? AND ec.created_at BETWEEN ? AND ?
     ORDER BY c.name`,
    [ep.episode_id, range.startSql, range.endSql]
  );
  if (include.actor) {
    const actorIds = [...new Set(rows.map(r => r.actor_id).filter(Boolean))];
    let actorsMap = {};
    if (actorIds.length) {
      const [actors] = await pool.query(`SELECT id, name FROM actors WHERE id IN (${actorIds.map(() => '?').join(',')})`, actorIds);
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
  const [r] = await pool.execute(
    'DELETE FROM episode_characters WHERE episode_id=? AND character_id=?',
    [ep.episode_id, req.params.characterId]
  );
  if (!r.affectedRows) return httpError(res, 404, 'link not found');
  res.status(204).send();
}));

// --------------------------- JOBS ---------------------------
const jobs = new Map();
function nowISO(){ return new Date().toISOString(); }
async function runShowQuery(filters = {}, include = {}) {
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
  const sql = `SELECT id, title, description, year FROM shows ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY year IS NULL, year, title`;
  const [rows] = await pool.execute(sql, params);
  if (include.episodes) {
    for (const show of rows) {
      show.episodes = await runEpisodeQuery({ show_id: show.id }, include.episodes);
    }
  }
  return rows;
}

async function runSeasonQuery(filters){
  const where = [];
  const params = [];
  if (filters.show_id != null) { where.push('show_id = ?'); params.push(filters.show_id); }
  if (filters.season_number != null) { where.push('season_number = ?'); params.push(filters.season_number); }
  if (filters.year_min != null) { where.push('year >= ?'); params.push(filters.year_min); }
  if (filters.year_max != null) { where.push('year <= ?'); params.push(filters.year_max); }
  const sql = `SELECT id, show_id, season_number, year FROM seasons ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY show_id, season_number`;
  const [rows] = await pool.execute(sql, params);
  return rows;
}

async function runEpisodeQuery(filters = {}, include = {}) {
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
  const sql = `SELECT e.id, e.season_id, s.show_id, s.season_number, e.air_date, e.title, e.description FROM episodes e JOIN seasons s ON s.id = e.season_id ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY e.air_date IS NULL, e.air_date, e.id`;
  const [rows] = await pool.execute(sql, params);
  if (include.characters && rows.length) {
    const episodeIds = rows.map(r => r.id);
    const [chars] = await pool.query(
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
    for (const ep of rows) {
      ep.characters = grouped[ep.id] || [];
    }
  }
  return rows;
}

async function runCharacterQuery(filters = {}, include = {}) {
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
  const sql = `SELECT c.id, c.show_id, c.name, c.actor_id, a.name AS actor_name FROM characters c LEFT JOIN actors a ON a.id=c.actor_id ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY c.name`;
  const [rows] = await pool.execute(sql, params);
  if (include.actor && rows.length) {
    const actorIds = [...new Set(rows.map(r => r.actor_id).filter(Boolean))];
    let actorsMap = {};
    if (actorIds.length) {
      const [actors] = await pool.query(`SELECT id, name FROM actors WHERE id IN (${actorIds.map(() => '?').join(',')})`, actorIds);
      actorsMap = Object.fromEntries(actors.map(a => [a.id, a]));
    }
    for (const r of rows) {
      r.actor = r.actor_id ? actorsMap[r.actor_id] || { id: r.actor_id, name: r.actor_name } : null;
    }
  }
  return rows;
}

async function runActorQuery(filters){
  const where = [];
  const params = [];
  if (filters.name) { where.push('name LIKE ?'); params.push(`%${filters.name}%`); }
  const sql = `SELECT id, name FROM actors ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY name`;
  const [rows] = await pool.execute(sql, params);
  return rows;
}

app.post('/shows/query-jobs', asyncH(async (req, res) => {
  const { title, year_min, year_max, episode_title, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const jobId = randomUUID();
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = { id: jobId, status: 'queued', created_at: nowISO(), updated_at: nowISO(), eta_ms: delay, result: null, rowsCount: null, error: null, filename: `shows_query_${jobId}.json` };
  jobs.set(jobId, job);
  setTimeout(async () => {
    const j = jobs.get(jobId); if (!j) return;
    j.status = 'running'; j.updated_at = nowISO();
    try {
      const rows = await runShowQuery({ title, year_min, year_max, episode_title }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { title, year_min, year_max, episode_title, include }, count: rows.length, rows }, null, 2));
      j.result = payload; j.rowsCount = rows.length; j.status = 'completed'; j.updated_at = nowISO();
    } catch (e) {
      j.status = 'failed'; j.error = e && e.message ? e.message : 'unknown error'; j.updated_at = nowISO();
    }
  }, delay);
  res.status(202).json({ job_id: jobId, status: job.status, eta_ms: job.eta_ms, poll_url: `/jobs/${jobId}`, download_url: `/jobs/${jobId}/download` });
}));

app.post('/seasons/query-jobs', asyncH(async (req, res) => {
  const { show_id, season_number, year_min, year_max, delay_ms } = req.body || {};
  const jobId = randomUUID();
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = { id: jobId, status: 'queued', created_at: nowISO(), updated_at: nowISO(), eta_ms: delay, result: null, rowsCount: null, error: null, filename: `seasons_query_${jobId}.json` };
  jobs.set(jobId, job);
  setTimeout(async () => {
    const j = jobs.get(jobId); if (!j) return;
    j.status = 'running'; j.updated_at = nowISO();
    try {
      const rows = await runSeasonQuery({ show_id, season_number, year_min, year_max });
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, season_number, year_min, year_max }, count: rows.length, rows }, null, 2));
      j.result = payload; j.rowsCount = rows.length; j.status = 'completed'; j.updated_at = nowISO();
    } catch (e) {
      j.status = 'failed'; j.error = e && e.message ? e.message : 'unknown error'; j.updated_at = nowISO();
    }
  }, delay);
  res.status(202).json({ job_id: jobId, status: job.status, eta_ms: job.eta_ms, poll_url: `/jobs/${jobId}`, download_url: `/jobs/${jobId}/download` });
}));

app.post('/episodes/query-jobs', asyncH(async (req, res) => {
  const { show_id, season_number, title, character_name, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const jobId = randomUUID();
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = { id: jobId, status: 'queued', created_at: nowISO(), updated_at: nowISO(), eta_ms: delay, result: null, rowsCount: null, error: null, filename: `episodes_query_${jobId}.json` };
  jobs.set(jobId, job);
  setTimeout(async () => {
    const j = jobs.get(jobId); if (!j) return;
    j.status = 'running'; j.updated_at = nowISO();
    try {
      const rows = await runEpisodeQuery({ show_id, season_number, title, character_name }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, season_number, title, character_name, include }, count: rows.length, rows }, null, 2));
      j.result = payload; j.rowsCount = rows.length; j.status = 'completed'; j.updated_at = nowISO();
    } catch (e) {
      j.status = 'failed'; j.error = e && e.message ? e.message : 'unknown error'; j.updated_at = nowISO();
    }
  }, delay);
  res.status(202).json({ job_id: jobId, status: job.status, eta_ms: job.eta_ms, poll_url: `/jobs/${jobId}`, download_url: `/jobs/${jobId}/download` });
}));

app.post('/characters/query-jobs', asyncH(async (req, res) => {
  const { show_id, name, actor_id, actor_name, include, delay_ms } = req.body || {};
  const includeTree = parseIncludeParam(include);
  const jobId = randomUUID();
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = { id: jobId, status: 'queued', created_at: nowISO(), updated_at: nowISO(), eta_ms: delay, result: null, rowsCount: null, error: null, filename: `characters_query_${jobId}.json` };
  jobs.set(jobId, job);
  setTimeout(async () => {
    const j = jobs.get(jobId); if (!j) return;
    j.status = 'running'; j.updated_at = nowISO();
    try {
      const rows = await runCharacterQuery({ show_id, name, actor_id, actor_name }, includeTree);
      const payload = Buffer.from(JSON.stringify({ filters: { show_id, name, actor_id, actor_name, include }, count: rows.length, rows }, null, 2));
      j.result = payload; j.rowsCount = rows.length; j.status = 'completed'; j.updated_at = nowISO();
    } catch (e) {
      j.status = 'failed'; j.error = e && e.message ? e.message : 'unknown error'; j.updated_at = nowISO();
    }
  }, delay);
  res.status(202).json({ job_id: jobId, status: job.status, eta_ms: job.eta_ms, poll_url: `/jobs/${jobId}`, download_url: `/jobs/${jobId}/download` });
}));

app.post('/actors/query-jobs', asyncH(async (req, res) => {
  const { name, delay_ms } = req.body || {};
  const jobId = randomUUID();
  const delay = Number.isFinite(delay_ms) ? Math.max(500, Math.min(60000, Number(delay_ms))) : (2000 + Math.floor(Math.random()*6000));
  const job = { id: jobId, status: 'queued', created_at: nowISO(), updated_at: nowISO(), eta_ms: delay, result: null, rowsCount: null, error: null, filename: `actors_query_${jobId}.json` };
  jobs.set(jobId, job);
  setTimeout(async () => {
    const j = jobs.get(jobId); if (!j) return;
    j.status = 'running'; j.updated_at = nowISO();
    try {
      const rows = await runActorQuery({ name });
      const payload = Buffer.from(JSON.stringify({ filters: { name }, count: rows.length, rows }, null, 2));
      j.result = payload; j.rowsCount = rows.length; j.status = 'completed'; j.updated_at = nowISO();
    } catch (e) {
      j.status = 'failed'; j.error = e && e.message ? e.message : 'unknown error'; j.updated_at = nowISO();
    }
  }, delay);
  res.status(202).json({ job_id: jobId, status: job.status, eta_ms: job.eta_ms, poll_url: `/jobs/${jobId}`, download_url: `/jobs/${jobId}/download` });
}));

app.get('/jobs/:id', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const job = jobs.get(req.params.id);
  if (!job) return httpError(res, 404, 'job not found');
  const created = new Date(job.created_at);
  if (created < range.start || created > range.end) return httpError(res, 404, 'job not found');
  res.json({ id: job.id, status: job.status, created_at: job.created_at, updated_at: job.updated_at, eta_ms: job.eta_ms, rows: job.rowsCount, error: job.error, download_url: job.status === 'completed' ? `/jobs/${job.id}/download` : null });
}));

app.get('/jobs/:id/download', asyncH(async (req, res) => {
  const range = parseDateRange(req, res); if (!range) return;
  const job = jobs.get(req.params.id);
  if (!job) return httpError(res, 404, 'job not found');
  const created = new Date(job.created_at);
  if (created < range.start || created > range.end) return httpError(res, 404, 'job not found');
  if (job.status !== 'completed') return httpError(res, 409, `job not ready (status=${job.status})`);
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Content-Disposition', `attachment; filename="${job.filename}"`);
  res.send(job.result);
}));

app.delete('/jobs/:id', asyncH(async (req, res) => {
  if (!jobs.has(req.params.id)) return httpError(res, 404, 'job not found');
  jobs.delete(req.params.id);
  res.status(204).send();
}));

// --------------------------- bootstrap ---------------------------
(async () => {
  try {
    await initDatabase();
    pool = mysql.createPool({
      host: DB_HOST, port: DB_PORT, user: DB_USER, password: DB_PASSWORD, database: DB_NAME,
      waitForConnections: true, connectionLimit: 10, queueLimit: 0
    });
    app.listen(PORT, () => { console.log(`API listening on http://localhost:${PORT}`); });
  } catch (err) {
    console.error('Failed to initialize database', err);
    process.exit(1);
  }
})();
