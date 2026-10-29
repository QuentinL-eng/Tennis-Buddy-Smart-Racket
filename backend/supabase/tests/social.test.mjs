import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// Real Postgres in WASM; Supabase's auth.uid() is modelled with a per-request claim.
const ids = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003'];
test('friend consent, invitations, participant isolation, score conflicts, undo, and private stats', async () => {
  const db = new PGlite();
  try {
    await db.exec(`create role anon; create role authenticated; create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
      grant usage on schema auth to anon, authenticated;`);
    await db.exec(await readFile(new URL('../001_social.sql', import.meta.url), 'utf8'));
    for (const id of ids) await db.query('insert into auth.users values ($1)', [id]);
    const as = async (id, role = 'authenticated') => {
      await db.exec('reset role');
      await db.query("select set_config('request.jwt.claim.sub', $1, false)", [id ?? '']);
      await db.exec(`set role ${role}`);
    };
    const call = async (sql, params = []) => (await db.query(`select ${sql} as result`, params)).rows[0].result;
    await as(null, 'anon');
    await assert.rejects(call('public.social_dashboard()'), /permission denied/);
    await as(ids[0]);
    const a = await call('public.social_dashboard()');
    await call("public.set_player_name('Alice')");
    await as(ids[1]);
    const b = await call('public.social_dashboard()');
    await call("public.set_player_name('Bob')");
    await as(ids[2]);
    await call('public.social_dashboard()');
    await as(ids[0]);
    await assert.rejects(call('public.create_shared_match($1, $2)', ['Test', ids[1]]), /accepted friends/);
    await call('public.request_friend($1)', [b.profile.friendCode]);
    await call('public.respond_friend($1, true)', [ids[1]]); // requester cannot accept own request
    assert.equal((await call('public.social_dashboard()')).friends.length, 0);
    await as(ids[1]);
    assert.equal((await call('public.social_dashboard()')).requests[0].incoming, true);
    await call('public.respond_friend($1, true)', [ids[0]]);
    await as(ids[0]);
    assert.equal((await call('public.social_dashboard()')).friends[0].id, ids[1]);
    const match = await call('public.create_shared_match($1, $2)', ['Saturday singles', ids[1]]);
    await as(ids[2]);
    await assert.rejects(call('public.shared_match_state($1)', [match.id]), /not available/);
    await assert.rejects(call('public.accept_match_invitation($1)', [match.id]), /No invitation/);
    await assert.rejects(db.query('select * from public.shared_matches'), /permission denied/);
    await as(ids[1]);
    assert.equal((await call('public.social_dashboard()')).invitations[0].id, match.id);
    const joined = await call('public.accept_match_invitation($1)', [match.id]);
    assert.equal(joined.guest.id, ids[1]);
    const op = '10000000-0000-4000-8000-000000000001';
    await call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[0], op]);
    await call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[0], op]); // safe retry
    assert.equal((await call('public.shared_match_state($1)', [match.id])).points.length, 1);
    await assert.rejects(call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[1], '10000000-0000-4000-8000-000000000002']), /score changed/);
    await assert.rejects(call('public.add_shared_point($1, $2, $3, 1)', [match.id, ids[2], '10000000-0000-4000-8000-000000000003']), /Invalid player/);
    await call('public.share_racket_stats($1, 25, 80, 90, 125)', [match.id]);
    let state = await call('public.shared_match_state($1)', [match.id]);
    assert.equal(state.stats[0].id, ids[1]);
    assert.equal(state.stats[0].shots, 25);
    assert.equal(state.stats[0].averageBallKmh, 90);
    await assert.rejects(call('public.share_racket_stats($1, -1, 80)', [match.id]), /check constraint/);
    await as(ids[2]);
    await assert.rejects(call('public.share_racket_stats($1, 1, 80)', [match.id]), /not available/);
    await assert.rejects(call('public.add_shared_point($1, $2, $3, 1)', [match.id, ids[0], '10000000-0000-4000-8000-000000000004']), /not available/);
    await as(ids[0]);
    await assert.rejects(call('public.undo_shared_point($1, $2)', [match.id, '10000000-0000-4000-8000-000000000005']), /score changed/);
    await call('public.undo_shared_point($1, $2)', [match.id, op]);
    state = await call('public.shared_match_state($1)', [match.id]);
    assert.equal(state.points.length, 0);
    assert.equal(state.revision, 2);
    // A delayed retry of an undone operation must never restore the point.
    await call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[0], op]);
    assert.equal((await call('public.shared_match_state($1)', [match.id])).points.length, 0);
    await assert.rejects(call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[0], '10000000-0000-4000-8000-000000000007']), /score changed/);
    assert.equal(state.stats.length, 1); // undo changes only the point log
    await call('public.end_shared_match($1)', [match.id]);
    await assert.rejects(call('public.add_shared_point($1, $2, $3, 0)', [match.id, ids[0], '10000000-0000-4000-8000-000000000006']), /not active/);
    const codeMatch = await call("public.create_shared_match('Quick practice')");
    await as(ids[1]);
    await call('public.join_shared_match($1)', [codeMatch.inviteCode]);
    await as(ids[2]);
    await assert.rejects(call('public.join_shared_match($1)', [codeMatch.inviteCode]), /full/);
    await as(ids[0]);
    await call('public.remove_friend($1)', [ids[1]]);
    assert.equal((await call('public.social_dashboard()')).friends.length, 0);
    assert.equal(a.profile.friendCode.length, 12);
  } finally { await db.close(); }
});
