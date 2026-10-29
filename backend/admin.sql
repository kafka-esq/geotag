-- geo# admin snippets. Run one at a time in the Supabase SQL editor (runs as owner, so the usual locks don't apply).

-- 1. Founder codes for your first crew (one use each).
insert into invites (code) values ('WPG-FOUNDER'), ('EXCHANGE-01'), ('EXCHANGE-02');

-- 1b. A multi-use code for Apple's reviewers. Put it in the App Review notes.
insert into invites (code, max_uses) values ('APPREVIEW', 25);

-- 2. Give someone more codes.
insert into invites (code, owner)
select new_invite_code(), id from profiles, generate_series(1, 5) where handle = '@somebody';

-- 3. Words not allowed in names and comments. Add your own list.
insert into banned_words (word) values ('example1'), ('example2') on conflict do nothing;

-- 4. Moderation queue: anything reported, newest first. Apple expects action within 24 hours.
select 'piece' as what, p.id, u.handle, p.report_count, p.hidden, p.created_at,
       (select string_agg(coalesce(r.reason, '-'), ' | ') from reports r where r.piece_id = p.id) as reasons
from pieces p join profiles u on u.id = p.author where p.report_count > 0
union all
select 'comment', c.id, u.handle, c.report_count, c.hidden, c.created_at, c.body
from comments c join profiles u on u.id = c.author where c.report_count > 0
union all
select 'person', u.id, u.handle, count(*)::int, u.banned_at is not null, max(r.created_at), string_agg(coalesce(r.reason, '-'), ' | ')
from reports r join profiles u on u.id = r.user_id group by u.id
order by 6 desc;

-- 4b. Restore or remove a piece.
update pieces set hidden = false, report_count = 0 where id = '00000000-0000-0000-0000-000000000000';
delete from pieces where id = '00000000-0000-0000-0000-000000000000';

-- 5. Ban one person (their art disappears everywhere immediately).
update profiles set banned_at = now() where handle = '@somebody';

-- 5b. Ban a person and everyone they brought in.
with recursive tree as (
  select id from profiles where handle = '@somebody'
  union all select p.id from profiles p join tree t on p.invited_by = t.id
) update profiles set banned_at = now() where id in (select id from tree);

-- 6. Who invited whom.
with recursive tree as (
  select id, handle, 0 as depth from profiles where invited_by is null
  union all select p.id, p.handle, t.depth + 1 from profiles p join tree t on p.invited_by = t.id
) select repeat('  ', depth) || handle from tree;

-- 7. Walls flagged as changed, and bringing one back if it was a false alarm.
select id, lat, lng, piece_count, created_at from walls where status = 'changed';
update walls set status = 'active' where id = '00000000-0000-0000-0000-000000000000';
update pieces set archived = false where wall_id = '00000000-0000-0000-0000-000000000000';
