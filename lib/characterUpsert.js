function buildCharacterUpsert({ showId, name, actorId, shouldUpdateActor }) {
  if (!showId) throw new Error('showId is required');
  if (!name) throw new Error('name is required');

  const params = [showId, name, shouldUpdateActor ? (actorId ?? null) : null];
  const sqlBase =
    'INSERT INTO characters (show_id, name, actor_id) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE ';

  const sql = shouldUpdateActor
    ? `${sqlBase}actor_id=VALUES(actor_id), id=LAST_INSERT_ID(id)`
    : `${sqlBase}id=LAST_INSERT_ID(id)`;

  return { sql, params };
}

module.exports = { buildCharacterUpsert };
