const { test } = require('node:test');
const assert = require('node:assert');

const { buildCharacterUpsert } = require('../lib/characterUpsert');

test('buildCharacterUpsert preserves actor when not updating', () => {
  const { sql, params } = buildCharacterUpsert({
    showId: 1,
    name: 'James Holden',
    actorId: undefined,
    shouldUpdateActor: false,
  });

  assert.ok(sql.includes('ON DUPLICATE KEY UPDATE'));
  assert.ok(!sql.includes('actor_id=VALUES(actor_id)'), 'should not update actor_id');
  assert.deepStrictEqual(params, [1, 'James Holden', null]);
});

test('buildCharacterUpsert updates actor when requested', () => {
  const { sql, params } = buildCharacterUpsert({
    showId: 2,
    name: 'Naomi Nagata',
    actorId: 7,
    shouldUpdateActor: true,
  });

  assert.ok(sql.includes('actor_id=VALUES(actor_id)'));
  assert.deepStrictEqual(params, [2, 'Naomi Nagata', 7]);
});

test('buildCharacterUpsert clears actor when requested', () => {
  const { sql, params } = buildCharacterUpsert({
    showId: 3,
    name: 'Alex Kamal',
    actorId: null,
    shouldUpdateActor: true,
  });

  assert.ok(sql.includes('actor_id=VALUES(actor_id)'));
  assert.deepStrictEqual(params, [3, 'Alex Kamal', null]);
});
