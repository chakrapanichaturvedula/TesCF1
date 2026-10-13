-- ============================================================================
-- CF1 course platform: database schema for Supabase (Postgres 15 or later)
--
-- Run once, in full, in the Supabase SQL editor on an empty project.
-- Then run seed.sql, then add your roster and staff (see the end of seed.sql).
--
-- Setup notes (Supabase dashboard):
--   1. Authentication > Providers > enable "Allow anonymous sign-ins".
--      Students sign in anonymously, then claim their roster ID with
--      public.claim_student(). Their browser then stays signed in.
--   2. Create the four instructor accounts by hand: Authentication > Users >
--      Add user > Create new user, with Auto Confirm ticked. No email is
--      sent. Leave "Confirm email" ON so nobody can sign up with an address
--      they do not own.
--   3. Anonymous sign-ins are limited per IP address (30 an hour by default).
--      Campus Wi-Fi may share one address, so raise the limit under
--      Authentication > Rate Limits before the first class use.
--   4. Turn on CAPTCHA (Authentication > Bot and Abuse Protection) before
--      wide release, and move login to institute email or Google before
--      participation counts for marks.
--
-- Who can do what
--   Student        reads own rows only; writes only through the functions below
--   Instructor     reads students, progress and analytics of own sections only
--   In-charge      reads everything, controls visibility, roster and purge
-- ============================================================================

create schema if not exists app;
grant usage on schema app to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Core tables
-- ----------------------------------------------------------------------------

-- One course in one term. New term or new course = new row here.
create table public.offerings (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique,            -- put this in the site config
  course_code    text not null,                   -- e.g. FIA203; matches content_items
  title          text not null,
  term           text not null,                   -- e.g. 2026-T2
  starts_on      date,
  ends_on        date,
  retention_days integer not null default 90 check (retention_days >= 0),
  class_key      text,                            -- optional shared word for the ID step
  created_at     timestamptz not null default now(),
  unique (course_code, term)
);

create table public.sections (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings (id) on delete cascade,
  name        text not null,                      -- A, B, C, D, E
  unique (offering_id, name)
);

-- The roster. student_code is the ID students type.
create table public.students (
  id           uuid primary key default gen_random_uuid(),
  offering_id  uuid not null references public.offerings (id) on delete cascade,
  section_id   uuid not null references public.sections (id) on delete cascade,
  student_code text not null,
  full_name    text not null,
  email        text,
  created_at   timestamptz not null default now(),
  unique (offering_id, student_code)
);
create index students_section_idx on public.students (section_id);

-- Which browser sessions are linked to which student (one row per device).
create table public.student_links (
  auth_uid   uuid primary key,
  student_id uuid not null references public.students (id) on delete cascade,
  claimed_at timestamptz not null default now()
);
create index student_links_student_idx on public.student_links (student_id);

-- Every ID claim, successful or not. Used to throttle guessing and to flag
-- an ID claimed from many devices.
create table public.claim_log (
  id          bigint generated always as identity primary key,
  auth_uid    uuid not null,
  offering_id uuid references public.offerings (id) on delete cascade,
  student_id  uuid references public.students (id) on delete cascade,
  success     boolean not null,
  at          timestamptz not null default now()
);
create index claim_log_uid_idx on public.claim_log (auth_uid, at);
create index claim_log_student_idx on public.claim_log (student_id);

-- Instructors and the in-charge, identified by the email on their login.
create table public.staff (
  email     text primary key,
  full_name text not null,
  role      text not null check (role in ('in_charge', 'instructor'))
);

create table public.staff_sections (
  staff_email text not null references public.staff (email) on delete cascade,
  section_id  uuid not null references public.sections (id) on delete cascade,
  primary key (staff_email, section_id)
);

-- ----------------------------------------------------------------------------
-- Content and activities
-- ----------------------------------------------------------------------------

-- Modules and pages of a course. A page's slug is its file name without .html.
create table public.content_items (
  id              uuid primary key default gen_random_uuid(),
  course_code     text not null,
  slug            text not null,
  kind            text not null check (kind in ('module', 'page')),
  parent_id       uuid references public.content_items (id) on delete set null,
  title           text not null,
  file            text,
  sort            integer not null default 0,
  total_steps     integer check (total_steps is null or total_steps > 0),
  completion_rule text not null default 'last_step'
                    check (completion_rule in ('last_step', 'manual')),
  created_at      timestamptz not null default now(),
  unique (course_code, slug)
);

-- Show or hide an item. A row with section_id null applies to every section of
-- the offering; a row with a section overrides it for that section. No row at
-- all means hidden. A release date holds an item back until that moment.
create table public.content_visibility (
  id          uuid primary key default gen_random_uuid(),
  offering_id uuid not null references public.offerings (id) on delete cascade,
  item_id     uuid not null references public.content_items (id) on delete cascade,
  section_id  uuid references public.sections (id) on delete cascade,
  visible     boolean not null,
  release_at  timestamptz
);
create unique index content_visibility_all_idx
  on public.content_visibility (offering_id, item_id) where section_id is null;
create unique index content_visibility_section_idx
  on public.content_visibility (offering_id, item_id, section_id) where section_id is not null;

-- Everything trackable inside a page: a quiz, a check-yourself, an activity.
create table public.activities (
  id        uuid primary key default gen_random_uuid(),
  item_id   uuid not null references public.content_items (id) on delete cascade,
  key       text not null check (key ~ '^[a-z0-9_-]{1,40}$'),
  title     text not null,
  kind      text not null check (kind in ('quiz', 'check', 'activity')),
  max_score numeric check (max_score is null or max_score >= 0),
  config    jsonb not null default '{}'::jsonb,
  unique (item_id, key)
);

-- Where a student is on a page, and how long they have actively spent there.
create table public.progress (
  student_id     uuid not null references public.students (id) on delete cascade,
  item_id        uuid not null references public.content_items (id) on delete cascade,
  status         text not null default 'started' check (status in ('started', 'completed')),
  furthest_step  integer not null default 0,
  active_seconds integer not null default 0,
  first_opened_at timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  completed_at   timestamptz,
  primary key (student_id, item_id)
);

-- One row per attempt at an activity. Individual answers are not stored by
-- default; detail is optional room for later.
create table public.attempts (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students (id) on delete cascade,
  activity_id uuid not null references public.activities (id) on delete cascade,
  attempt_no integer not null,
  score      numeric,
  max_score  numeric,
  seconds    integer,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (student_id, activity_id, attempt_no)
);
create index attempts_student_idx on public.attempts (student_id);

-- Optional, unused until participation counts for marks. A page with no row
-- here weighs 1.
create table public.participation_weights (
  offering_id uuid not null references public.offerings (id) on delete cascade,
  item_id     uuid not null references public.content_items (id) on delete cascade,
  weight      numeric not null default 1 check (weight >= 0),
  primary key (offering_id, item_id)
);

-- Anonymous per-page totals kept when a term is purged, so next term you can
-- still see which modules were weakly covered. Contains no student data.
create table public.archive_item_stats (
  offering_id        uuid not null references public.offerings (id) on delete cascade,
  item_id            uuid not null references public.content_items (id) on delete cascade,
  section_name       text not null,
  students           integer not null,
  started            integer not null,
  completed          integer not null,
  avg_active_minutes numeric,
  archived_at        timestamptz not null default now(),
  primary key (offering_id, item_id, section_name)
);

-- ----------------------------------------------------------------------------
-- Tidy-up triggers
-- ----------------------------------------------------------------------------

create function app.normalise_student() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.student_code := upper(btrim(new.student_code));
  return new;
end $$;
create trigger students_normalise before insert or update on public.students
  for each row execute function app.normalise_student();

create function app.normalise_staff() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.email := lower(btrim(new.email));
  new.full_name := btrim(new.full_name);
  return new;
end $$;
create trigger staff_normalise before insert or update on public.staff
  for each row execute function app.normalise_staff();

-- ----------------------------------------------------------------------------
-- Helper functions used by the access rules
-- ----------------------------------------------------------------------------

create function app.jwt_email() returns text
language sql stable set search_path = '' as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create function app.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff s where s.email = app.jwt_email())
$$;

create function app.is_in_charge() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff s
    where s.email = app.jwt_email() and s.role = 'in_charge'
  )
$$;

create function app.my_section_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select ss.section_id from public.staff_sections ss
  where ss.staff_email = app.jwt_email()
$$;

create function app.my_student_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select l.student_id from public.student_links l where l.auth_uid = auth.uid()
$$;

-- True for the student themself, for an instructor of the student's section,
-- and for the in-charge.
create function app.can_see_student(p_student uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.is_in_charge()
      or p_student = app.my_student_id()
      or exists (
           select 1 from public.students st
           where st.id = p_student
             and st.section_id in (select app.my_section_ids())
         )
$$;

-- ----------------------------------------------------------------------------
-- Views (run with the caller's rights, so the access rules apply to them)
-- ----------------------------------------------------------------------------

-- Is each item released, for each section? Own setting first, then the
-- offering-wide setting, otherwise hidden. A release date delays it.
create view public.v_item_release_raw with (security_invoker = true) as
select
  o.id   as offering_id,
  sec.id as section_id,
  ci.id  as item_id,
  (
    case when cv_s.id is not null then cv_s.visible
         else coalesce(cv_g.visible, false) end
  ) and (
    coalesce(case when cv_s.id is not null then cv_s.release_at
                  else cv_g.release_at end, '-infinity'::timestamptz) <= now()
  ) as released
from public.offerings o
join public.sections sec on sec.offering_id = o.id
join public.content_items ci on ci.course_code = o.course_code
left join public.content_visibility cv_s
       on cv_s.offering_id = o.id and cv_s.item_id = ci.id and cv_s.section_id = sec.id
left join public.content_visibility cv_g
       on cv_g.offering_id = o.id and cv_g.item_id = ci.id and cv_g.section_id is null;

-- A page is released only if its module is released too.
create view public.v_item_release with (security_invoker = true) as
select
  r.offering_id,
  r.section_id,
  r.item_id,
  (r.released and coalesce(p.released, true)) as released
from public.v_item_release_raw r
join public.content_items ci on ci.id = r.item_id
left join public.v_item_release_raw p
       on p.offering_id = r.offering_id
      and p.section_id  = r.section_id
      and p.item_id     = ci.parent_id;

-- One row per student: how far they have got and how active they are.
create view public.v_student_overview with (security_invoker = true) as
select
  st.id as student_id,
  st.offering_id,
  st.section_id,
  sec.name as section,
  st.student_code,
  st.full_name,
  (select count(*) from public.v_item_release r
     join public.content_items ci on ci.id = r.item_id
    where r.offering_id = st.offering_id and r.section_id = st.section_id
      and r.released and ci.kind = 'page') as pages_released,
  (select count(*) from public.progress p where p.student_id = st.id) as pages_started,
  (select count(*) from public.progress p
    where p.student_id = st.id and p.status = 'completed') as pages_completed,
  (select coalesce(round(sum(p.active_seconds) / 60.0, 1), 0)
     from public.progress p where p.student_id = st.id) as active_minutes,
  (select max(p.last_seen_at) from public.progress p where p.student_id = st.id) as last_active_at,
  (select count(*) from public.attempts a where a.student_id = st.id) as attempts,
  (select count(distinct l.auth_uid) from public.claim_log l
    where l.student_id = st.id and l.success) as devices
from public.students st
join public.sections sec on sec.id = st.section_id;

-- Student by released page: covered or not.
create view public.v_student_page with (security_invoker = true) as
select
  st.id as student_id,
  st.offering_id,
  sec.name as section,
  st.student_code,
  st.full_name,
  ci.slug,
  ci.title,
  ci.sort,
  case when p.status = 'completed' then 'completed'
       when p.student_id is not null then 'started'
       else 'not started' end as status,
  coalesce(p.active_seconds, 0) as active_seconds,
  p.last_seen_at
from public.students st
join public.sections sec on sec.id = st.section_id
join public.offerings o on o.id = st.offering_id
join public.content_items ci on ci.course_code = o.course_code and ci.kind = 'page'
join public.v_item_release r
  on r.offering_id = st.offering_id and r.section_id = st.section_id
 and r.item_id = ci.id and r.released
left join public.progress p on p.student_id = st.id and p.item_id = ci.id;

-- Section by page: how many started and finished.
create view public.v_page_coverage with (security_invoker = true) as
select
  r.offering_id,
  sec.name as section,
  ci.slug,
  ci.title,
  ci.sort,
  r.released,
  (select count(*) from public.students s where s.section_id = r.section_id) as students,
  count(p.student_id) as started,
  count(p.student_id) filter (where p.status = 'completed') as completed,
  round(avg(p.active_seconds) / 60.0, 1) as avg_active_minutes
from public.v_item_release r
join public.sections sec on sec.id = r.section_id
join public.content_items ci on ci.id = r.item_id and ci.kind = 'page'
left join public.progress p
  on p.item_id = r.item_id
 and p.student_id in (select s.id from public.students s where s.section_id = r.section_id)
group by r.offering_id, r.section_id, sec.name, ci.id, ci.slug, ci.title, ci.sort, r.released;

-- Weighted share of released pages completed. Unused until you decide.
create view public.v_participation with (security_invoker = true) as
select
  st.id as student_id,
  st.offering_id,
  sec.name as section,
  st.student_code,
  st.full_name,
  count(*) filter (where r.released) as pages_released,
  count(*) filter (where r.released and p.status = 'completed') as pages_completed,
  round(
    100.0 * sum(coalesce(pw.weight, 1)) filter (where r.released and p.status = 'completed')
    / nullif(sum(coalesce(pw.weight, 1)) filter (where r.released), 0), 1
  ) as participation_pct
from public.students st
join public.sections sec on sec.id = st.section_id
join public.offerings o on o.id = st.offering_id
join public.content_items ci on ci.course_code = o.course_code and ci.kind = 'page'
join public.v_item_release r
  on r.offering_id = st.offering_id and r.section_id = st.section_id and r.item_id = ci.id
left join public.progress p on p.student_id = st.id and p.item_id = ci.id
left join public.participation_weights pw
  on pw.offering_id = st.offering_id and pw.item_id = ci.id
group by st.id, st.offering_id, sec.name, st.student_code, st.full_name;

-- ----------------------------------------------------------------------------
-- Functions the site calls
-- ----------------------------------------------------------------------------

-- Student types their ID. On success this browser is linked to the roster row
-- and returns the name and section; on any failure it returns null with one
-- generic outcome, so the answer does not reveal which IDs exist.
create function public.claim_student(
  p_offering_slug text,
  p_student_code  text,
  p_class_key     text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_off  public.offerings%rowtype;
  v_st   public.students%rowtype;
  v_fail integer;
  v_sec  text;
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  select count(*) into v_fail from public.claim_log l
   where l.auth_uid = v_uid and not l.success and l.at > now() - interval '10 minutes';
  if v_fail >= 8 then
    raise exception 'Too many attempts. Try again in a few minutes.';
  end if;

  select * into v_off from public.offerings o where o.slug = p_offering_slug;
  if v_off.id is not null then
    select * into v_st from public.students s
     where s.offering_id = v_off.id and s.student_code = upper(btrim(p_student_code));
  end if;

  if v_off.id is null or v_st.id is null
     or (v_off.class_key is not null and v_off.class_key is distinct from p_class_key) then
    insert into public.claim_log (auth_uid, offering_id, success) values (v_uid, v_off.id, false);
    return null;
  end if;

  insert into public.student_links (auth_uid, student_id) values (v_uid, v_st.id)
  on conflict (auth_uid) do update set student_id = excluded.student_id, claimed_at = now();

  insert into public.claim_log (auth_uid, offering_id, student_id, success)
  values (v_uid, v_off.id, v_st.id, true);

  select sec.name into v_sec from public.sections sec where sec.id = v_st.section_id;
  return jsonb_build_object('name', v_st.full_name, 'section', v_sec);
end $$;

-- Who am I? Null when this browser has not claimed an ID.
create function public.my_profile() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'student_code', st.student_code,
    'name', st.full_name,
    'section', sec.name,
    'course', o.title,
    'term', o.term
  )
  from public.students st
  join public.sections sec on sec.id = st.section_id
  join public.offerings o on o.id = st.offering_id
  where st.id = app.my_student_id()
$$;

-- The course map for this student, with released = false for anything hidden.
-- The site uses it to draw the index and to gate each page.
create function public.my_content()
returns table (
  item_id uuid, slug text, kind text, parent_id uuid, title text,
  file text, sort integer, released boolean
)
language sql stable security definer set search_path = '' as $$
  with me as (
    select st.offering_id, st.section_id, o.course_code
    from public.students st
    join public.offerings o on o.id = st.offering_id
    where st.id = app.my_student_id()
  )
  select ci.id, ci.slug, ci.kind, ci.parent_id, ci.title, ci.file, ci.sort,
         coalesce(r.released, false)
  from me
  join public.content_items ci on ci.course_code = me.course_code
  left join public.v_item_release r
         on r.offering_id = me.offering_id
        and r.section_id  = me.section_id
        and r.item_id     = ci.id
  order by ci.sort
$$;

-- Record where the student is on a page and how long they were active.
-- Seconds are capped per call so one bad call cannot inflate the total.
create function public.track_progress(
  p_item_slug text,
  p_step      integer default null,
  p_seconds   integer default 0,
  p_completed boolean default false
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_student uuid := app.my_student_id();
  v_off     uuid;
  v_sec     uuid;
  v_item    public.content_items%rowtype;
  v_ok      boolean;
  v_done    boolean;
  v_secs    integer := least(greatest(coalesce(p_seconds, 0), 0), 120);
begin
  if v_student is null then
    raise exception 'Enter your student ID first';
  end if;

  select st.offering_id, st.section_id into v_off, v_sec
    from public.students st where st.id = v_student;

  select ci.* into v_item
    from public.content_items ci
    join public.offerings o on o.course_code = ci.course_code
   where o.id = v_off and ci.slug = p_item_slug and ci.kind = 'page';
  if v_item.id is null then
    raise exception 'Unknown page';
  end if;

  select r.released into v_ok from public.v_item_release r
   where r.offering_id = v_off and r.section_id = v_sec and r.item_id = v_item.id;
  if not coalesce(v_ok, false) then
    raise exception 'This page is not released yet';
  end if;

  v_done := p_completed
         or (v_item.completion_rule = 'last_step'
             and v_item.total_steps is not null
             and coalesce(p_step, 0) >= v_item.total_steps);

  insert into public.progress as pr
    (student_id, item_id, status, furthest_step, active_seconds, completed_at)
  values
    (v_student, v_item.id, case when v_done then 'completed' else 'started' end,
     coalesce(p_step, 0), v_secs, case when v_done then now() end)
  on conflict (student_id, item_id) do update set
    furthest_step  = greatest(pr.furthest_step, excluded.furthest_step),
    active_seconds = pr.active_seconds + excluded.active_seconds,
    last_seen_at   = now(),
    status         = case when pr.status = 'completed' or excluded.status = 'completed'
                          then 'completed' else 'started' end,
    completed_at   = coalesce(pr.completed_at, excluded.completed_at);
end $$;

-- Record one attempt at a registered activity. Returns the attempt number.
create function public.submit_attempt(
  p_item_slug    text,
  p_activity_key text,
  p_score        numeric default null,
  p_max_score    numeric default null,
  p_seconds      integer default null,
  p_detail       jsonb default '{}'::jsonb
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_student uuid := app.my_student_id();
  v_off     uuid;
  v_sec     uuid;
  v_act     public.activities%rowtype;
  v_ok      boolean;
  v_no      integer;
begin
  if v_student is null then
    raise exception 'Enter your student ID first';
  end if;
  if p_score is not null and p_score < 0 then
    raise exception 'Invalid score';
  end if;
  if pg_column_size(coalesce(p_detail, '{}'::jsonb)) > 4096 then
    raise exception 'Detail is too large';
  end if;

  select st.offering_id, st.section_id into v_off, v_sec
    from public.students st where st.id = v_student;

  select a.* into v_act
    from public.activities a
    join public.content_items ci on ci.id = a.item_id
    join public.offerings o on o.course_code = ci.course_code
   where o.id = v_off and ci.slug = p_item_slug and a.key = p_activity_key;
  if v_act.id is null then
    raise exception 'Unknown activity';
  end if;

  select r.released into v_ok from public.v_item_release r
   where r.offering_id = v_off and r.section_id = v_sec and r.item_id = v_act.item_id;
  if not coalesce(v_ok, false) then
    raise exception 'This page is not released yet';
  end if;

  select coalesce(max(t.attempt_no), 0) + 1 into v_no
    from public.attempts t where t.student_id = v_student and t.activity_id = v_act.id;

  insert into public.attempts
    (student_id, activity_id, attempt_no, score, max_score, seconds, detail)
  values
    (v_student, v_act.id, v_no, p_score, coalesce(p_max_score, v_act.max_score),
     p_seconds, coalesce(p_detail, '{}'::jsonb));

  return v_no;
end $$;

-- In-charge only. Show or hide an item for every section (p_section null) or
-- for one section. p_visible null removes that setting.
create function public.set_visibility(
  p_offering_slug text,
  p_item_slug     text,
  p_visible       boolean,
  p_section       text default null,
  p_release_at    timestamptz default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_off  public.offerings%rowtype;
  v_item uuid;
  v_sec  uuid;
begin
  if not app.is_in_charge() then
    raise exception 'Only the instructor in charge can change visibility';
  end if;

  select * into v_off from public.offerings o where o.slug = p_offering_slug;
  if v_off.id is null then raise exception 'Unknown offering'; end if;

  select ci.id into v_item from public.content_items ci
   where ci.course_code = v_off.course_code and ci.slug = p_item_slug;
  if v_item is null then raise exception 'Unknown item'; end if;

  if p_section is not null then
    select s.id into v_sec from public.sections s
     where s.offering_id = v_off.id and s.name = p_section;
    if v_sec is null then raise exception 'Unknown section'; end if;
  end if;

  if p_visible is null then
    delete from public.content_visibility cv
     where cv.offering_id = v_off.id and cv.item_id = v_item
       and cv.section_id is not distinct from v_sec;
  elsif v_sec is null then
    insert into public.content_visibility (offering_id, item_id, section_id, visible, release_at)
    values (v_off.id, v_item, null, p_visible, p_release_at)
    on conflict (offering_id, item_id) where section_id is null
    do update set visible = excluded.visible, release_at = excluded.release_at;
  else
    insert into public.content_visibility (offering_id, item_id, section_id, visible, release_at)
    values (v_off.id, v_item, v_sec, p_visible, p_release_at)
    on conflict (offering_id, item_id, section_id) where section_id is not null
    do update set visible = excluded.visible, release_at = excluded.release_at;
  end if;
end $$;

-- In-charge only. Delete a term's student data once retention_days have passed
-- since ends_on (or immediately with p_force). Keeps the offering, sections,
-- staff and an anonymous per-page summary.
create function public.purge_offering(
  p_offering_slug text,
  p_force         boolean default false
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_off      public.offerings%rowtype;
  v_students integer;
  v_attempts integer;
begin
  if not app.is_in_charge() then
    raise exception 'Only the instructor in charge can purge a term';
  end if;

  select * into v_off from public.offerings o where o.slug = p_offering_slug;
  if v_off.id is null then raise exception 'Unknown offering'; end if;

  if not p_force and (v_off.ends_on is null
                      or current_date < v_off.ends_on + v_off.retention_days) then
    raise exception 'Retention period has not ended for this term';
  end if;

  insert into public.archive_item_stats
    (offering_id, item_id, section_name, students, started, completed, avg_active_minutes)
  select v_off.id, ci.id, sec.name,
         (select count(*) from public.students s where s.section_id = sec.id)::integer,
         count(p.student_id)::integer,
         (count(p.student_id) filter (where p.status = 'completed'))::integer,
         round(avg(p.active_seconds) / 60.0, 1)
    from public.sections sec
    join public.content_items ci on ci.course_code = v_off.course_code and ci.kind = 'page'
    left join public.progress p
      on p.item_id = ci.id
     and p.student_id in (select s.id from public.students s where s.section_id = sec.id)
   where sec.offering_id = v_off.id
   group by ci.id, sec.id, sec.name
  on conflict do nothing;

  select count(*) into v_attempts from public.attempts a
   where a.student_id in (select s.id from public.students s where s.offering_id = v_off.id);

  delete from public.students s where s.offering_id = v_off.id;
  get diagnostics v_students = row_count;

  delete from public.claim_log l where l.offering_id = v_off.id;
  delete from public.content_visibility cv where cv.offering_id = v_off.id;

  return jsonb_build_object('students_deleted', v_students, 'attempts_deleted', v_attempts);
end $$;

-- To purge automatically, enable the pg_cron extension (Database > Extensions)
-- and schedule something like:
--   select cron.schedule('purge-old-terms', '0 3 * * 0', $$
--     select public.purge_offering(slug) from public.offerings
--     where ends_on is not null and current_date >= ends_on + retention_days
--   $$);
-- Until then, run it by hand from the admin page after each term.

-- ----------------------------------------------------------------------------
-- Access rules (row-level security)
-- ----------------------------------------------------------------------------

alter table public.offerings             enable row level security;
alter table public.sections              enable row level security;
alter table public.students              enable row level security;
alter table public.student_links         enable row level security;
alter table public.claim_log             enable row level security;
alter table public.staff                 enable row level security;
alter table public.staff_sections        enable row level security;
alter table public.content_items         enable row level security;
alter table public.content_visibility    enable row level security;
alter table public.activities            enable row level security;
alter table public.progress              enable row level security;
alter table public.attempts              enable row level security;
alter table public.participation_weights enable row level security;
alter table public.archive_item_stats    enable row level security;

-- In-charge: full control of setup tables.
create policy incharge_all on public.offerings for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.sections for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.students for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.staff for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.staff_sections for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.content_items for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.content_visibility for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.activities for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());
create policy incharge_all on public.participation_weights for all to authenticated
  using (app.is_in_charge()) with check (app.is_in_charge());

-- Read access. Students never read the setup tables directly (that would
-- expose the class key); they use my_profile() and my_content().
create policy staff_read on public.offerings for select to authenticated
  using (app.is_staff());
create policy staff_read on public.content_items for select to authenticated
  using (app.is_staff());
create policy staff_read on public.content_visibility for select to authenticated
  using (app.is_staff());
create policy staff_read on public.activities for select to authenticated
  using (app.is_staff());
create policy staff_read on public.participation_weights for select to authenticated
  using (app.is_staff());
create policy incharge_read on public.archive_item_stats for select to authenticated
  using (app.is_in_charge());

create policy own_sections on public.sections for select to authenticated
  using (id in (select app.my_section_ids()));
create policy own_row on public.staff for select to authenticated
  using (email = app.jwt_email());
create policy own_row on public.staff_sections for select to authenticated
  using (staff_email = app.jwt_email());

-- Student data: the student, their section's instructors, and the in-charge.
create policy scoped_read on public.students for select to authenticated
  using (app.can_see_student(id));
create policy scoped_read on public.progress for select to authenticated
  using (app.can_see_student(student_id));
create policy scoped_read on public.attempts for select to authenticated
  using (app.can_see_student(student_id));
create policy scoped_read on public.claim_log for select to authenticated
  using (app.can_see_student(student_id));

-- student_links has no policy at all: only the functions above can touch it.

-- ----------------------------------------------------------------------------
-- Table and function permissions
-- ----------------------------------------------------------------------------

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
revoke all on all functions in schema public from public;

revoke all on public.student_links from authenticated;
revoke insert, update, delete on public.progress, public.attempts,
  public.claim_log, public.archive_item_stats from authenticated;

grant select on public.v_item_release_raw, public.v_item_release,
  public.v_student_overview, public.v_student_page,
  public.v_page_coverage, public.v_participation to authenticated;

grant execute on function public.claim_student(text, text, text) to authenticated;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.my_content() to authenticated;
grant execute on function public.track_progress(text, integer, integer, boolean) to authenticated;
grant execute on function public.submit_attempt(text, text, numeric, numeric, integer, jsonb) to authenticated;
grant execute on function public.set_visibility(text, text, boolean, text, timestamptz) to authenticated;
grant execute on function public.purge_offering(text, boolean) to authenticated;
