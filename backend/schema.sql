-- geo# backend v2 (Supabase / Postgres).
-- Run once in the Supabase SQL editor. Safe to re-run: it only creates what's missing and replaces functions.
-- Before running: Authentication > Sign In / Providers > turn ON "Allow anonymous sign-ins".
--
-- Model
--   wall   = a real flat surface, pinned by a geospatial pose. Its local frame: x right, y up, z out of the wall.
--   piece  = one painting session on a wall, stored as vector data in wall metres. Layer order = created_at.
--   anchor = a Google Cloud Anchor id for a wall (visual fingerprint). Several per wall, retired when they stop matching.
-- Membership: every phone signs in anonymously; only redeeming an invite creates a profile, and only profiles can read or write.

create extension if not exists pgcrypto;

-- ============================================================ tables

create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  handle           text not null unique check (handle ~ '^@[a-z0-9_.]{2,20}$'),
  invited_by       uuid references public.profiles(id) on delete set null,
  is_admin         boolean not null default false,
  banned_at        timestamptz,
  rules_accepted_at timestamptz,
  created_at       timestamptz not null default now()
);

create table if not exists public.invites (
  code        text primary key,
  owner       uuid references public.profiles(id) on delete cascade,  -- null = root code made by an admin
  used_by     uuid references public.profiles(id) on delete set null,
  used_at     timestamptz,
  max_uses    int not null default 1,          -- root codes for App Review or launch events can allow more
  use_count   int not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.walls (
  id              uuid primary key default gen_random_uuid(),
  created_by      uuid references public.profiles(id) on delete set null,
  lat             double precision not null check (lat between -90 and 90),
  lng             double precision not null check (lng between -180 and 180),
  alt             double precision not null,
  qx real not null, qy real not null, qz real not null, qw real not null,  -- east-up-south rotation of the wall frame
  heading         real not null,           -- compass direction the wall faces (outward normal), degrees
  canvas_x0       real not null default -4,  -- canvas rectangle in wall metres
  canvas_y0       real not null default -2,
  canvas_w        real not null default 8 check (canvas_w between 1 and 30),
  canvas_h        real not null default 6 check (canvas_h between 1 and 15),
  status          text not null default 'active' check (status in ('active', 'changed', 'removed')),
  piece_count     int not null default 0,
  last_painted_at timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists walls_lat_lng on public.walls (lat, lng) where status = 'active';

create table if not exists public.wall_anchors (
  id          uuid primary key default gen_random_uuid(),
  wall_id     uuid not null references public.walls(id) on delete cascade,
  cloud_id    text not null unique,
  created_by  uuid references public.profiles(id) on delete set null,
  expires_at  timestamptz not null,
  successes   int not null default 0,
  failures    int not null default 0,
  retired     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists wall_anchors_wall on public.wall_anchors (wall_id) where not retired;

create table if not exists public.wall_observations (
  id          bigint generated always as identity primary key,
  wall_id     uuid not null references public.walls(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  offset_m    real not null,   -- how far the detected plane sat from the stored one, along the normal
  angle_deg   real not null,   -- angle between detected and stored normals
  matched     boolean not null,
  created_at  timestamptz not null default now()
);
create index if not exists wall_obs_wall on public.wall_observations (wall_id, created_at desc);

create table if not exists public.pieces (
  id            uuid primary key default gen_random_uuid(),
  wall_id       uuid not null references public.walls(id) on delete cascade,
  author        uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind          text not null check (kind in ('spray', 'sketch')),
  data          jsonb not null check (octet_length(data::text) < 700000),
  x0 real not null, y0 real not null, x1 real not null, y1 real not null,  -- bounding box in wall metres
  props_count   int not null default 0,
  comment_count int not null default 0,
  report_count  int not null default 0,
  hidden        boolean not null default false,
  archived      boolean not null default false,  -- wall changed; kept for the archive
  created_at    timestamptz not null default now()
);
create index if not exists pieces_wall on public.pieces (wall_id, created_at);
create index if not exists pieces_author on public.pieces (author, created_at desc);

create table if not exists public.comments (
  id           uuid primary key default gen_random_uuid(),
  piece_id     uuid not null references public.pieces(id) on delete cascade,
  author       uuid not null references public.profiles(id) on delete cascade,
  body         text not null check (char_length(body) between 1 and 280),
  report_count int not null default 0,
  hidden       boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists comments_piece on public.comments (piece_id, created_at);

create table if not exists public.props (
  piece_id   uuid not null references public.pieces(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (piece_id, user_id)
);

create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  piece_id    uuid references public.pieces(id) on delete cascade,
  comment_id  uuid references public.comments(id) on delete cascade,
  user_id     uuid references public.profiles(id) on delete cascade,   -- reporting a person
  reporter    uuid not null references public.profiles(id) on delete cascade,
  reason      text,
  resolved    boolean not null default false,
  created_at  timestamptz not null default now(),
  check (num_nonnulls(piece_id, comment_id, user_id) = 1)
);
create unique index if not exists reports_piece_once on public.reports (piece_id, reporter) where piece_id is not null;
create unique index if not exists reports_comment_once on public.reports (comment_id, reporter) where comment_id is not null;
create unique index if not exists reports_user_once on public.reports (user_id, reporter) where user_id is not null;

create table if not exists public.blocks (
  blocker    uuid not null references public.profiles(id) on delete cascade,
  blocked    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);

-- Words that can't appear in handles or comments. Fill it from the SQL editor (admin.sql has the pattern).
create table if not exists public.banned_words (word text primary key);

-- Kept for later: paid "scrubbed" walls. Nothing in the app uses it yet.
create table if not exists public.scrub_zones (
  id uuid primary key default gen_random_uuid(),
  owner_name text not null, lat double precision not null, lng double precision not null,
  radius_m real not null, active_until timestamptz, created_at timestamptz not null default now()
);

-- ============================================================ helpers

create or replace function public.geo_dist_m(lat1 double precision, lng1 double precision,
                                             lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

create or replace function public.angle_diff(a real, b real)
returns real language sql immutable as $$
  select abs(((a - b + 540)::numeric % 360) - 180)::real
$$;

create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and banned_at is null)
$$;

create or replace function public.require_member()
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if not is_member() then raise exception 'not_a_member'; end if;
  return auth.uid();
end $$;

create or replace function public.has_banned_word(t text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from banned_words b where lower(t) like '%' || lower(b.word) || '%')
$$;

-- Users hidden from me: people I blocked, people who blocked me, and banned people.
create or replace function public.hidden_users()
returns setof uuid language sql stable security definer set search_path = public as $$
  select blocked from blocks where blocker = auth.uid()
  union select blocker from blocks where blocked = auth.uid()
  union select id from profiles where banned_at is not null
$$;

create or replace function public.new_invite_code()
returns text language sql volatile as $$
  select 'GEO-' || upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 6))
$$;

-- ============================================================ account

create or replace function public.redeem_invite(p_code text, p_handle text)
returns public.profiles language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); inv invites; prof profiles; h text;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select * into prof from profiles where id = me;
  if found then return prof; end if;

  h := regexp_replace(lower(trim(p_handle)), '\s+', '_', 'g');
  if left(h, 1) <> '@' then h := '@' || h; end if;
  if h !~ '^@[a-z0-9_.]{2,20}$' then raise exception 'bad_handle'; end if;
  if has_banned_word(h) then raise exception 'bad_handle'; end if;
  if exists (select 1 from profiles where handle = h) then raise exception 'handle_taken'; end if;

  select * into inv from invites where code = upper(trim(p_code)) and use_count < max_uses for update;
  if not found then raise exception 'bad_invite'; end if;

  insert into profiles (id, handle, invited_by, rules_accepted_at) values (me, h, inv.owner, now()) returning * into prof;
  update invites set use_count = use_count + 1,
                     used_by = case when max_uses = 1 then me else used_by end,
                     used_at = now()
   where code = inv.code;
  insert into invites (code, owner) select new_invite_code(), me from generate_series(1, 3);
  return prof;
end $$;

create or replace function public.me()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'handle', p.handle, 'is_admin', p.is_admin, 'created_at', p.created_at,
    'invited_by', (select handle from profiles i where i.id = p.invited_by))
  from profiles p where p.id = auth.uid() and p.banned_at is null
$$;

create or replace function public.my_invites()
returns table (code text, used_by_handle text, used_at timestamptz)
language sql stable security definer set search_path = public as $$
  select i.code, p.handle, i.used_at from invites i left join profiles p on p.id = i.used_by
  where i.owner = auth.uid() order by i.used_at nulls first, i.created_at
$$;

-- Apple requires in-app account deletion. Pieces, comments and props go with the account.
create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_signed_in'; end if;
  delete from auth.users where id = me;
end $$;

create or replace function public.profile_card(p_handle text)
returns json language plpgsql stable security definer set search_path = public as $$
declare p profiles;
begin
  perform require_member();
  select * into p from profiles where handle = lower(p_handle) and banned_at is null;
  if not found or p.id in (select hidden_users()) then return null; end if;
  return json_build_object(
    'id', p.id, 'handle', p.handle, 'since', p.created_at,
    'pieces', (select count(*) from pieces where author = p.id and not hidden),
    'walls', (select count(distinct wall_id) from pieces where author = p.id and not hidden),
    'props', (select coalesce(sum(props_count), 0) from pieces where author = p.id and not hidden),
    'invited_by', (select handle from profiles i where i.id = p.invited_by),
    'crew', (select coalesce(json_agg(handle order by created_at), '[]') from profiles c
             where c.invited_by = p.id and c.banned_at is null),
    'blocked', exists (select 1 from blocks where blocker = auth.uid() and blocked = p.id));
end $$;

-- ============================================================ walls

-- Nearby walls with their freshest anchors. The app pins each with a geospatial anchor.
create or replace function public.walls_near(p_lat double precision, p_lng double precision, p_radius_m double precision default 150)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  r double precision := least(greatest(p_radius_m, 10), 2000);
  dlat double precision := r / 111320.0;
  dlng double precision := r / (111320.0 * greatest(cos(radians(p_lat)), 0.01));
begin
  perform require_member();
  return coalesce((
    select json_agg(w order by w.dist) from (
      select w.id, w.lat, w.lng, w.alt, w.qx, w.qy, w.qz, w.qw, w.heading,
             w.canvas_x0, w.canvas_y0, w.canvas_w, w.canvas_h, w.last_painted_at,
             geo_dist_m(p_lat, p_lng, w.lat, w.lng) as dist,
             (select count(*) from pieces p where p.wall_id = w.id and not p.hidden and not p.archived
                and p.author not in (select hidden_users())) as piece_count,
             (select coalesce(json_agg(a.cloud_id order by (a.successes - a.failures) desc, a.created_at desc), '[]')
                from (select * from wall_anchors a where a.wall_id = w.id and not a.retired and a.expires_at > now()
                      order by (a.successes - a.failures) desc, a.created_at desc limit 3) a) as anchors
      from walls w
      where w.status = 'active'
        and w.lat between p_lat - dlat and p_lat + dlat
        and w.lng between p_lng - dlng and p_lng + dlng
        and geo_dist_m(p_lat, p_lng, w.lat, w.lng) <= r
      order by dist limit 200) w), '[]');
end $$;

-- Lightweight version for the map: just where the walls are and how busy they are.
create or replace function public.walls_map(p_lat double precision, p_lng double precision, p_radius_m double precision default 3000)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  r double precision := least(greatest(p_radius_m, 100), 25000);
  dlat double precision := r / 111320.0;
  dlng double precision := r / (111320.0 * greatest(cos(radians(p_lat)), 0.01));
begin
  perform require_member();
  return coalesce((
    select json_agg(x) from (
      select w.id, w.lat, w.lng, w.heading, w.last_painted_at,
             count(p.id) as piece_count,
             (select pr.handle from pieces lp join profiles pr on pr.id = lp.author
               where lp.wall_id = w.id and not lp.hidden and not lp.archived
                 and lp.author not in (select hidden_users())
               order by lp.created_at desc limit 1) as last_artist
      from walls w
      left join pieces p on p.wall_id = w.id and not p.hidden and not p.archived and p.author not in (select hidden_users())
      where w.status = 'active'
        and w.lat between p_lat - dlat and p_lat + dlat
        and w.lng between p_lng - dlng and p_lng + dlng
      group by w.id
      having count(p.id) > 0
      order by max(p.created_at) desc nulls last
      limit 500) x), '[]');
end $$;

-- Creates a wall, unless one already exists within 2.5 m facing the same way, in which case that one is returned.
create or replace function public.create_wall(
  p_lat double precision, p_lng double precision, p_alt double precision,
  p_qx real, p_qy real, p_qz real, p_qw real, p_heading real,
  p_canvas_x0 real default -4, p_canvas_y0 real default -2, p_canvas_w real default 8, p_canvas_h real default 6)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); w walls;
begin
  select * into w from walls
   where status = 'active'
     and lat between p_lat - 0.0001 and p_lat + 0.0001
     and geo_dist_m(p_lat, p_lng, lat, lng) <= 2.5
     and abs(alt - p_alt) < 3
     and angle_diff(heading, p_heading) < 25
   order by geo_dist_m(p_lat, p_lng, lat, lng) limit 1;
  if found then return json_build_object('id', w.id, 'existing', true); end if;

  if (select count(*) from walls where created_by = me and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'slow_down';
  end if;
  insert into walls (created_by, lat, lng, alt, qx, qy, qz, qw, heading, canvas_x0, canvas_y0, canvas_w, canvas_h)
  values (me, p_lat, p_lng, p_alt, p_qx, p_qy, p_qz, p_qw, p_heading, p_canvas_x0, p_canvas_y0, p_canvas_w, p_canvas_h)
  returning * into w;
  return json_build_object('id', w.id, 'existing', false);
end $$;

create or replace function public.add_wall_anchor(p_wall uuid, p_cloud_id text, p_ttl_days int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_member();
begin
  insert into wall_anchors (wall_id, cloud_id, created_by, expires_at)
  values (p_wall, p_cloud_id, me, now() + make_interval(days => least(greatest(p_ttl_days, 1), 365)))
  on conflict (cloud_id) do nothing;
  -- keep the five healthiest
  update wall_anchors set retired = true
   where wall_id = p_wall and not retired and id not in (
     select id from wall_anchors where wall_id = p_wall and not retired
     order by (successes - failures) desc, created_at desc limit 5);
end $$;

create or replace function public.anchor_result(p_cloud_id text, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_member();
  update wall_anchors set
    successes = successes + case when p_ok then 1 else 0 end,
    failures  = failures + case when p_ok then 0 else 1 end,
    retired   = retired or (not p_ok and failures + 1 >= 4 and failures + 1 > successes * 2)
  where cloud_id = p_cloud_id;
end $$;

-- A phone reports how well the stored wall matched what its camera sees.
-- Three different people seeing a consistent mismatch marks the wall as changed and archives its pieces.
create or replace function public.observe_wall(p_wall uuid, p_offset_m real, p_angle_deg real, p_matched boolean)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); bad int; good int;
begin
  if exists (select 1 from wall_observations where wall_id = p_wall and user_id = me and created_at > now() - interval '10 minutes') then
    return (select status from walls where id = p_wall);
  end if;
  insert into wall_observations (wall_id, user_id, offset_m, angle_deg, matched)
  values (p_wall, me, p_offset_m, p_angle_deg, p_matched);

  select count(distinct user_id) filter (where not matched),
         count(distinct user_id) filter (where matched)
    into bad, good
    from (select * from wall_observations where wall_id = p_wall order by created_at desc limit 12) o;

  if bad >= 3 and good = 0 then
    update walls set status = 'changed' where id = p_wall and status = 'active';
    update pieces set archived = true where wall_id = p_wall;
  end if;
  return (select status from walls where id = p_wall);
end $$;

-- ============================================================ pieces

create or replace function public.wall_pieces(p_wall uuid)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform require_member();
  return coalesce((
    select json_agg(x order by x.created_at) from (
      select p.id, p.wall_id, p.kind, p.data, p.x0, p.y0, p.x1, p.y1, p.props_count, p.comment_count, p.created_at,
             p.author as author_id, pr.handle,
             exists (select 1 from props where piece_id = p.id and user_id = auth.uid()) as i_propped,
             p.author = auth.uid() as mine
      from pieces p join profiles pr on pr.id = p.author
      where p.wall_id = p_wall and not p.hidden and not p.archived
        and p.author not in (select hidden_users())
      order by p.created_at limit 400) x), '[]');
end $$;

create or replace function public.add_piece(p_wall uuid, p_kind text, p_data jsonb, p_x0 real, p_y0 real, p_x1 real, p_y1 real)
returns json language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); pid uuid; ts timestamptz;
begin
  if not exists (select 1 from walls where id = p_wall and status = 'active') then raise exception 'wall_gone'; end if;
  if (select count(*) from pieces where author = me and created_at > now() - interval '1 hour') >= 40 then
    raise exception 'slow_down';
  end if;
  insert into pieces (wall_id, author, kind, data, x0, y0, x1, y1)
  values (p_wall, me, p_kind, p_data, p_x0, p_y0, p_x1, p_y1) returning id, created_at into pid, ts;
  update walls set piece_count = piece_count + 1, last_painted_at = now() where id = p_wall;
  return json_build_object('id', pid, 'created_at', ts);
end $$;

create or replace function public.delete_my_piece(p_piece uuid)
returns void language sql security definer set search_path = public as $$
  delete from pieces where id = p_piece and author = auth.uid()
$$;

create or replace function public.toggle_prop(p_piece uuid)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); n int;
begin
  if exists (select 1 from props where piece_id = p_piece and user_id = me) then
    delete from props where piece_id = p_piece and user_id = me;
    update pieces set props_count = greatest(props_count - 1, 0) where id = p_piece returning props_count into n;
  else
    insert into props (piece_id, user_id) values (p_piece, me);
    update pieces set props_count = props_count + 1 where id = p_piece returning props_count into n;
  end if;
  return n;
end $$;

create or replace function public.piece_comments(p_piece uuid)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform require_member();
  return coalesce((
    select json_agg(x order by x.created_at) from (
      select c.id, c.body, c.created_at, c.author as author_id, pr.handle, c.author = auth.uid() as mine
      from comments c join profiles pr on pr.id = c.author
      where c.piece_id = p_piece and not c.hidden and c.author not in (select hidden_users())
      order by c.created_at limit 300) x), '[]');
end $$;

create or replace function public.add_comment(p_piece uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); b text := trim(p_body);
begin
  if char_length(b) = 0 then return; end if;
  if has_banned_word(b) then raise exception 'not_allowed'; end if;
  if (select count(*) from comments cm where cm.author = me and cm.created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'slow_down';
  end if;
  insert into comments (piece_id, author, body) values (p_piece, me, b);
  update pieces set comment_count = comment_count + 1 where id = p_piece;
end $$;

create or replace function public.delete_my_comment(p_comment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  delete from comments where id = p_comment and author = auth.uid() returning piece_id into pid;
  if pid is not null then update pieces set comment_count = greatest(comment_count - 1, 0) where id = pid; end if;
end $$;

-- ============================================================ safety

-- Three reports from different members hide a piece or comment until an admin reviews it.
create or replace function public.report(p_piece uuid default null, p_comment uuid default null,
                                         p_user uuid default null, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_member(); added int;
begin
  insert into reports (piece_id, comment_id, user_id, reporter, reason)
  values (p_piece, p_comment, p_user, me, left(p_reason, 300))
  on conflict do nothing;
  get diagnostics added = row_count;
  if added = 0 then return; end if;
  if p_piece is not null then
    update pieces set report_count = report_count + 1, hidden = hidden or report_count + 1 >= 3 where id = p_piece;
  elsif p_comment is not null then
    update comments set report_count = report_count + 1, hidden = hidden or report_count + 1 >= 3 where id = p_comment;
  end if;
end $$;

create or replace function public.block_user(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_member();
begin
  if p_user = me then return; end if;
  insert into blocks (blocker, blocked) values (me, p_user) on conflict do nothing;
end $$;

create or replace function public.unblock_user(p_user uuid)
returns void language sql security definer set search_path = public as $$
  delete from blocks where blocker = auth.uid() and blocked = p_user
$$;

create or replace function public.my_blocks()
returns table (id uuid, handle text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.handle, b.created_at from blocks b join profiles p on p.id = b.blocked
  where b.blocker = auth.uid() order by b.created_at desc
$$;

-- ============================================================ activity

-- What happened to my pieces, plus pieces that went over mine.
create or replace function public.activity()
returns json language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_member();
begin
  return coalesce((
    select json_agg(x order by x.at desc) from (
      (select 'prop' as kind, pr.created_at as at, u.handle, p.id as piece_id, p.wall_id, null::text as body
         from props pr join pieces p on p.id = pr.piece_id join profiles u on u.id = pr.user_id
        where p.author = me and pr.user_id <> me and pr.user_id not in (select hidden_users())
        order by pr.created_at desc limit 50)
      union all
      (select 'comment', c.created_at, u.handle, p.id, p.wall_id, c.body
         from comments c join pieces p on p.id = c.piece_id join profiles u on u.id = c.author
        where p.author = me and c.author <> me and not c.hidden and c.author not in (select hidden_users())
        order by c.created_at desc limit 50)
      union all
      (select 'over', o.created_at, u.handle, o.id, o.wall_id, null
         from pieces mine join pieces o on o.wall_id = mine.wall_id and o.created_at > mine.created_at
          and o.author <> me and not o.hidden
          and o.x0 < mine.x1 and o.x1 > mine.x0 and o.y0 < mine.y1 and o.y1 > mine.y0
         join profiles u on u.id = o.author
        where mine.author = me and not mine.hidden and o.author not in (select hidden_users())
        order by o.created_at desc limit 50)
      union all
      (select 'joined', c.created_at, c.handle, null, null, null
         from profiles c where c.invited_by = me order by c.created_at desc limit 20)
    ) x), '[]');
end $$;

create or replace function public.my_pieces()
returns json language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_member();
begin
  return coalesce((
    select json_agg(x order by x.created_at desc) from (
      select p.id, p.wall_id, p.kind, p.data, p.x0, p.y0, p.x1, p.y1, p.props_count, p.comment_count,
             p.created_at, p.hidden, p.archived, w.lat, w.lng
      from pieces p join walls w on w.id = p.wall_id
      where p.author = me order by p.created_at desc limit 200) x), '[]');
end $$;

-- ============================================================ security

alter table public.profiles          enable row level security;
alter table public.invites           enable row level security;
alter table public.walls             enable row level security;
alter table public.wall_anchors      enable row level security;
alter table public.wall_observations enable row level security;
alter table public.pieces            enable row level security;
alter table public.comments          enable row level security;
alter table public.props             enable row level security;
alter table public.reports           enable row level security;
alter table public.blocks            enable row level security;
alter table public.banned_words      enable row level security;
alter table public.scrub_zones       enable row level security;

-- No direct table access at all: every read and write goes through the functions above.
revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;
