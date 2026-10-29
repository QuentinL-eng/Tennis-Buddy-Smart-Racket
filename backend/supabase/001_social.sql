-- Run once in a new Supabase project's SQL editor. No service key belongs in the app.
begin;
create table public.player_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Tennis player' check (length(display_name) between 1 and 60),
  friend_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
);
create table public.friendships (
  requester uuid not null references public.player_profiles(id) on delete cascade,
  recipient uuid not null references public.player_profiles(id) on delete cascade,
  accepted boolean not null default false,
  primary key (requester, recipient), check (requester <> recipient)
);
create unique index one_friendship_per_pair on public.friendships
  (least(requester, recipient), greatest(requester, recipient));
create table public.shared_matches (
  id uuid primary key default gen_random_uuid(),
  host uuid not null references public.player_profiles(id) on delete cascade,
  guest uuid references public.player_profiles(id) on delete cascade,
  title text not null check (length(title) between 1 and 120),
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
  created_at timestamptz not null default now(), ended boolean not null default false,
  revision integer not null default 0,
  check (guest is null or guest <> host)
);
create table public.match_invitations (
  match_id uuid not null references public.shared_matches(id) on delete cascade,
  recipient uuid not null references public.player_profiles(id) on delete cascade,
  primary key (match_id, recipient)
);
create table public.shared_points (
  id uuid primary key, -- client operation UUID makes a retried award idempotent
  match_id uuid not null references public.shared_matches(id) on delete cascade,
  winner uuid not null references public.player_profiles(id) on delete cascade,
  voided boolean not null default false,
  sequence bigint generated always as identity unique
);
create index shared_points_match on public.shared_points(match_id, sequence);
create table public.shared_racket_stats (
  match_id uuid not null references public.shared_matches(id) on delete cascade,
  player_id uuid not null references public.player_profiles(id) on delete cascade,
  shots integer not null check (shots >= 0),
  sweet_percent double precision not null check (sweet_percent between 0 and 100),
  average_ball_kmh double precision check (average_ball_kmh between 0 and 500),
  top_ball_kmh double precision check (top_ball_kmh between 0 and 500),
  primary key (match_id, player_id)
);

-- Tables are not exposed for direct reads/writes. Every RPC below checks the authenticated caller.
alter table public.player_profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.shared_matches enable row level security;
alter table public.match_invitations enable row level security;
alter table public.shared_points enable row level security;
alter table public.shared_racket_stats enable row level security;
revoke all on public.player_profiles, public.friendships, public.shared_matches,
  public.match_invitations, public.shared_points, public.shared_racket_stats from anon, authenticated;

create function public.social_dashboard() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); result jsonb;
begin
  if me is null then raise exception 'Sign in first'; end if;
  insert into public.player_profiles(id) values (me) on conflict do nothing;
  select jsonb_build_object(
    'profile', jsonb_build_object('id', p.id, 'name', p.display_name, 'friendCode', p.friend_code),
    'friends', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'name', q.display_name, 'friendCode', q.friend_code) order by q.display_name)
      from public.friendships f join public.player_profiles q on q.id = case when f.requester = me then f.recipient else f.requester end
      where f.accepted and me in (f.requester, f.recipient)), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('player', jsonb_build_object('id', q.id, 'name', q.display_name, 'friendCode', ''), 'incoming', f.recipient = me))
      from public.friendships f join public.player_profiles q on q.id = case when f.requester = me then f.recipient else f.requester end
      where not f.accepted and me in (f.requester, f.recipient)), '[]'::jsonb),
    'invitations', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title, 'hostName', h.display_name) order by m.created_at desc)
      from public.match_invitations i join public.shared_matches m on m.id = i.match_id join public.player_profiles h on h.id = m.host
      where i.recipient = me and not m.ended and m.guest is null and m.created_at > now() - interval '24 hours'), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title, 'hostName', h.display_name) order by m.created_at desc)
      from (select * from public.shared_matches where me in (host, guest) order by created_at desc limit 30) m
      join public.player_profiles h on h.id = m.host), '[]'::jsonb)
  ) into result from public.player_profiles p where p.id = me;
  return result;
end $$;

create function public.set_player_name(p_name text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if length(trim(p_name)) not between 1 and 60 then raise exception 'Enter a name of 1 to 60 characters'; end if;
  insert into public.player_profiles(id, display_name) values (auth.uid(), trim(p_name))
    on conflict(id) do update set display_name = excluded.display_name;
  return true;
end $$;

create function public.request_friend(p_code text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); other uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  insert into public.player_profiles(id) values(me) on conflict do nothing;
  select id into other from public.player_profiles where friend_code = upper(trim(p_code));
  if other is null or other = me then raise exception 'That friend code is not available'; end if;
  if exists(select 1 from public.friendships where requester = other and recipient = me and not accepted)
    then raise exception 'This player has already sent you a request. Accept it below.'; end if;
  insert into public.friendships(requester, recipient) values(me, other) on conflict do nothing;
  return true;
end $$;
create function public.respond_friend(p_player uuid, p_accept boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if p_accept then
    update public.friendships set accepted = true where requester = p_player and recipient = auth.uid();
  else
    delete from public.friendships where requester = p_player and recipient = auth.uid() and not accepted;
  end if;
  return true;
end $$;
create function public.remove_friend(p_player uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.friendships where auth.uid() in (requester, recipient) and p_player in (requester, recipient);
  -- Removing a friend also withdraws any unaccepted invitations between these players.
  delete from public.match_invitations i using public.shared_matches m where i.match_id = m.id
    and ((m.host = auth.uid() and i.recipient = p_player) or (m.host = p_player and i.recipient = auth.uid()));
  return true;
end $$;

create function public.shared_match_state(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m public.shared_matches; result jsonb;
begin
  select * into m from public.shared_matches where id = p_match;
  if auth.uid() is null or m.id is null or (auth.uid() <> m.host and auth.uid() is distinct from m.guest)
    then raise exception 'This match is not available to you'; end if;
  select jsonb_build_object('id', m.id, 'title', m.title, 'inviteCode', m.invite_code, 'ended', m.ended, 'revision', m.revision,
    'host', (select jsonb_build_object('id', id, 'name', display_name, 'friendCode', '') from public.player_profiles where id = m.host),
    'guest', (select jsonb_build_object('id', id, 'name', display_name, 'friendCode', '') from public.player_profiles where id = m.guest),
    'points', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'winner', winner) order by sequence) from public.shared_points where match_id = m.id and not voided), '[]'::jsonb),
    'stats', coalesce((select jsonb_agg(jsonb_build_object('id', player_id, 'shots', shots, 'sweetPercent', sweet_percent,
      'averageBallKmh', average_ball_kmh, 'topBallKmh', top_ball_kmh)) from public.shared_racket_stats where match_id = m.id), '[]'::jsonb)
  ) into result;
  return result;
end $$;
create function public.create_shared_match(p_title text, p_friend uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); match_id uuid;
begin
  if me is null then raise exception 'Sign in first'; end if;
  insert into public.player_profiles(id) values(me) on conflict do nothing;
  if p_friend is not null and not exists(select 1 from public.friendships where accepted
    and me in (requester, recipient) and p_friend in (requester, recipient) and p_friend <> me)
    then raise exception 'Only accepted friends can be invited'; end if;
  insert into public.shared_matches(host, title) values(me, left(coalesce(nullif(trim(p_title), ''), 'Tennis with friends'), 120)) returning id into match_id;
  if p_friend is not null then insert into public.match_invitations values(match_id, p_friend); end if;
  return public.shared_match_state(match_id);
end $$;
create function public.join_shared_match(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare m public.shared_matches; me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into m from public.shared_matches where invite_code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'Session code not found'; end if;
  if me = m.host or me = m.guest then return public.shared_match_state(m.id); end if;
  if m.guest is not null or m.ended or m.created_at < now() - interval '24 hours'
    then raise exception 'This session is full, ended, or the invitation has expired'; end if;
  insert into public.player_profiles(id) values(me) on conflict do nothing;
  update public.shared_matches set guest = me where id = m.id;
  delete from public.match_invitations where match_id = m.id;
  return public.shared_match_state(m.id);
end $$;
create function public.accept_match_invitation(p_match uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare code text;
begin
  if auth.uid() is null or not exists(select 1 from public.match_invitations where match_id = p_match and recipient = auth.uid())
    then raise exception 'No invitation found'; end if;
  select invite_code into code from public.shared_matches where id = p_match;
  return public.join_shared_match(code);
end $$;
create function public.decline_match_invitation(p_match uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from public.match_invitations where match_id = p_match and recipient = auth.uid();
  return true;
end $$;

create function public.add_shared_point(p_match uuid, p_winner uuid, p_operation uuid, p_expected_revision integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare m public.shared_matches; previous public.shared_points;
begin
  select * into m from public.shared_matches where id = p_match for update;
  if auth.uid() is null or m.id is null or (auth.uid() <> m.host and auth.uid() is distinct from m.guest)
    then raise exception 'This match is not available to you'; end if;
  select * into previous from public.shared_points where id = p_operation;
  if previous.id is not null then
    if previous.match_id = p_match and previous.winner = p_winner then return true; end if;
    raise exception 'Point operation already used';
  end if;
  if m.ended or m.guest is null then raise exception 'This match is not active'; end if;
  if p_winner is null or p_winner not in (m.host, m.guest) then raise exception 'Invalid player'; end if;
  if p_expected_revision is distinct from m.revision
    then raise exception 'The score changed. Refresh before recording this point.'; end if;
  insert into public.shared_points(id, match_id, winner) values(p_operation, p_match, p_winner);
  update public.shared_matches set revision = revision + 1 where id = p_match;
  return true;
end $$;
create function public.undo_shared_point(p_match uuid, p_point uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare m public.shared_matches; last_id uuid;
begin
  select * into m from public.shared_matches where id = p_match for update;
  if auth.uid() is null or m.id is null or (auth.uid() <> m.host and auth.uid() is distinct from m.guest) or m.ended
    then raise exception 'This match is not active'; end if;
  select id into last_id from public.shared_points where match_id = p_match and not voided order by sequence desc limit 1;
  if last_id is distinct from p_point then raise exception 'The score changed. Refresh before undoing.'; end if;
  update public.shared_points set voided = true where id = p_point;
  update public.shared_matches set revision = revision + 1 where id = p_match;
  return true;
end $$;
create function public.end_shared_match(p_match uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  -- Use the same row lock as point awards and joins.
  perform 1 from public.shared_matches where id = p_match and auth.uid() in (host, guest) for update;
  if not found then raise exception 'This match is not available to you'; end if;
  update public.shared_matches set ended = true where id = p_match;
  delete from public.match_invitations where match_id = p_match;
  return true;
end $$;
create function public.share_racket_stats(p_match uuid, p_shots integer, p_sweet double precision,
  p_average double precision default null, p_top double precision default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists(select 1 from public.shared_matches where id = p_match and auth.uid() in (host, guest))
    then raise exception 'This match is not available to you'; end if;
  insert into public.shared_racket_stats values(p_match, auth.uid(), p_shots, p_sweet, p_average, p_top)
    on conflict(match_id, player_id) do update set shots = excluded.shots, sweet_percent = excluded.sweet_percent,
      average_ball_kmh = excluded.average_ball_kmh, top_ball_kmh = excluded.top_ball_kmh;
  return true;
end $$;

-- Definer functions bypass RLS deliberately, so expose only these authenticated entrypoints.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('social_dashboard', 'set_player_name', 'request_friend',
      'respond_friend', 'remove_friend', 'shared_match_state', 'create_shared_match', 'join_shared_match',
      'accept_match_invitation', 'decline_match_invitation', 'add_shared_point', 'undo_shared_point', 'end_shared_match', 'share_racket_stats')
  loop
    execute format('revoke all on function %s from public, anon', f.signature);
    execute format('grant execute on function %s to authenticated', f.signature);
  end loop;
end $$;
commit;
