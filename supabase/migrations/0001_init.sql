-- Orzio — commercial, multi-company edition.
-- Database, access rules, plans and limits, usage metering, realtime, private file storage
-- and the platform admin console's functions.
--
-- Run once on a NEW Supabase project: SQL Editor → paste this whole file → Run.
--
-- One codebase, two ways to sell it (platform_config.mode):
--   'saas'   — any business signs up on your domain and gets its own walled-off company.
--   'single' — a dedicated install for one client: only the first company can be created.

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. Platform settings and plans
-- ============================================================================
create table if not exists public.platform_config (
  key   text primary key,
  value text not null
);
insert into public.platform_config (key, value) values
  ('mode', 'saas'),              -- 'saas' or 'single'
  ('trial_days', '14'),
  ('max_orgs_per_user', '3'),    -- companies one person may create (stops abuse of free trials)
  ('ai_calls_per_minute', '30'), -- per person, across all servers
  ('support_email', '')          -- shown to customers when a trial ends or a limit is hit
on conflict (key) do nothing;

create or replace function public.cfg(k text) returns text
language sql stable security definer set search_path = public as $$
  select value from platform_config where key = k
$$;

-- Limits are per company per month. NULL means unlimited. Prices are yours to set
-- (from the admin console) once billing is decided; customers only see names and limits.
create table if not exists public.plans (
  id             text primary key,
  name           text not null,
  sort           int  not null default 0,
  price_month    numeric,
  currency       text not null default 'USD',
  max_staff      int,   -- owner + staff + read-only logins
  max_portal     int,   -- employee, customer and supplier logins
  max_entities   int,   -- legal entities / branches inside one company
  ai_calls_month int,   -- AI agent calls per calendar month
  ai_tokens_month bigint, -- AI tokens (input + output) per calendar month: the real cost driver
  storage_mb     int,   -- uploaded files
  data_mb        int,   -- records (the books) stored in the database
  public         boolean not null default true
);
alter table public.plans add column if not exists ai_tokens_month bigint;
alter table public.plans add column if not exists data_mb int;
insert into public.plans (id, name, sort, max_staff, max_portal, max_entities, ai_calls_month, ai_tokens_month, storage_mb, data_mb, public) values
  ('trial',     'Free trial', 0,    3,   25,    3,   300,   2000000,   1024,   250, false),
  ('starter',   'Starter',    1,    3,   50,    1,  1500,  15000000,   5120,  1024, true),
  ('growth',    'Growth',     2,   10,  250,    3,  6000,  60000000,  25600,  5120, true),
  ('scale',     'Scale',      3,   30, 1000,   10, 20000, 200000000, 102400, 20480, true),
  ('dedicated', 'Dedicated',  4, null, null, null,  null,      null,   null,  null, false)
on conflict (id) do nothing;

-- ============================================================================
-- 2. Companies, people and membership
-- ============================================================================
create table if not exists public.orgs (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) between 2 and 120),
  plan          text not null default 'trial' references public.plans (id),
  status        text not null default 'trial'
                check (status in ('trial', 'active', 'past_due', 'suspended', 'cancelled')),
  trial_ends_at timestamptz,
  limits        jsonb not null default '{}'::jsonb,  -- per-company overrides of plan limits
  notes         text,                                -- platform admin notes, never shown to customers
  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now()
);

create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text,
  email      text
);

-- owner  = full control, the only role that can grant or remove logins
-- staff  = works in the books (finer rights per area are set in the app)
-- viewer = read-only staff (auditors) — enforced by the database
-- portal = employees, customers and suppliers: only portal/<their id>/…
create table if not exists public.members (
  org_id     uuid not null references public.orgs (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null check (role in ('owner', 'staff', 'viewer', 'portal')),
  status     text not null default 'active' check (status in ('invited', 'active')),  -- invited = waiting for the person to accept
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
alter table public.members add column if not exists status text not null default 'active' check (status in ('invited', 'active'));
-- Companies (entities) inside the workspace this person may see; NULL = all companies, including future ones
alter table public.members add column if not exists entities text[];
create index if not exists members_user_idx on public.members (user_id);

create table if not exists public.platform_admins (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);

-- ============================================================================
-- 3. Helpers used by the access rules
-- ============================================================================
create or replace function public.safe_uuid(t text) returns uuid
language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end $$;

create or replace function public.my_role(p_org uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from members where org_id = p_org and user_id = auth.uid() and status = 'active'
$$;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
$$;

-- Readable unless cancelled. Writable while active, in grace (past_due) or in an unexpired trial.
create or replace function public.org_readable(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from orgs where id = p_org and status <> 'cancelled')
$$;
create or replace function public.org_writable(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from orgs where id = p_org and (
      status in ('active', 'past_due') or (status = 'trial' and coalesce(trial_ends_at, now() + interval '1 day') > now())
    )
  )
$$;

-- Effective limit: per-company override, else the plan's value. NULL = unlimited.
create or replace function public.org_limit(p_org uuid, k text) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce((o.limits ->> k)::bigint,
    case k when 'max_staff' then p.max_staff when 'max_portal' then p.max_portal
           when 'max_entities' then p.max_entities when 'ai_calls_month' then p.ai_calls_month
           when 'ai_tokens_month' then p.ai_tokens_month when 'storage_mb' then p.storage_mb
           when 'data_mb' then p.data_mb end)
  from orgs o join plans p on p.id = o.plan where o.id = p_org
$$;

create or replace function public.own_portal(p text) returns boolean
language sql stable as $$
  select auth.uid() is not null and (p = 'portal/' || auth.uid()::text or p like 'portal/' || auth.uid()::text || '/%')
$$;

-- Company-level access: a person limited to some companies only reaches records of those companies.
-- A record's company is data.entity (none = the main company, as in the app); shared set-up
-- (group settings, journals, workflows, exchange rates, logins) is visible to every member.
create or replace function public.entity_allowed(p_org uuid, p_path text, p_entity text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare ents text[];
begin
  select entities into ents from members where org_id = p_org and user_id = auth.uid() and status = 'active';
  if ents is null then return true; end if;
  if p_path like 'setup/main/entities/%' then return split_part(p_path, '/', 4) = any (ents); end if;
  if p_path = 'setup/main' or p_path like 'setup/main/journals/%' or p_path like 'setup/main/workflows/%'
     or p_path like 'setup/main/fx/%' or p_path like 'setup/main/access/%' or p_path like 'setup/main/access_log/%' then
    return true;
  end if;
  return coalesce(nullif(p_entity, ''), 'main') = any (ents);
end $$;

drop function if exists public.can_read_doc(uuid, text) cascade;
drop function if exists public.can_write_doc(uuid, text) cascade;
create or replace function public.can_read_doc(p_org uuid, p_path text, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case my_role(p_org)
    when 'owner'  then org_readable(p_org)
    when 'staff'  then org_readable(p_org) and entity_allowed(p_org, p_path, p_entity)
    when 'viewer' then org_readable(p_org) and entity_allowed(p_org, p_path, p_entity)
    when 'portal' then org_readable(p_org) and own_portal(p_path)
    else false end
$$;

-- Only owners grant or change logins; the access log is append-only (see policies).
create or replace function public.can_write_doc(p_org uuid, p_path text, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select org_writable(p_org) and case my_role(p_org)
    when 'owner'  then true
    when 'staff'  then p_path not like 'setup/main/access/%' and entity_allowed(p_org, p_path, p_entity)
    when 'portal' then own_portal(p_path)
    else false end
$$;

-- ============================================================================
-- 4. Documents — every record in the app is a JSON document at a path
--    (invoices/abc123, setup/main/accounts/main-1000…) inside one company.
-- ============================================================================
create table if not exists public.docs (
  id          uuid primary key default gen_random_uuid(),  -- opaque, so realtime deletes reveal nothing
  org_id      uuid not null references public.orgs (id) on delete cascade,
  path        text not null check (path ~ '^[^/]+(/[^/]+)+$' and length(path) <= 512),
  collection  text not null,
  scope       text not null,           -- '<org_id>:<collection>', the realtime filter key
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  unique (org_id, path)
);
create index if not exists docs_scope_idx on public.docs (scope);
alter table public.docs replica identity full;

create or replace function public.docs_before() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and (new.org_id <> old.org_id or new.path <> old.path) then
    raise exception 'A record cannot be moved to another path or company.' using errcode = '42501';
  end if;
  new.collection := regexp_replace(new.path, '/[^/]+$', '');
  new.scope      := new.org_id::text || ':' || new.collection;
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  if octet_length(new.data::text) > 1048576 then
    raise exception 'This record is larger than 1 MB.' using errcode = '54000';
  end if;
  return new;
end $$;
drop trigger if exists docs_before on public.docs;
create trigger docs_before before insert or update on public.docs for each row execute function public.docs_before();

-- Size a record counts against the data quota: its JSON, its path and a fixed per-row overhead
create or replace function public.doc_bytes(p_path text, p_data jsonb) returns bigint
language sql immutable as $$
  select octet_length(p_data::text)::bigint + octet_length(p_path) + 200
$$;

-- Running totals per workspace (records and bytes), kept by trigger, for the data quota
create table if not exists public.org_counters (
  org_id uuid primary key references public.orgs (id) on delete cascade,
  docs   bigint not null default 0,
  bytes  bigint not null default 0
);
alter table public.org_counters enable row level security;

-- Plan limits on records: entities, total data size, and what portal users may store
create or replace function public.docs_limits() returns trigger
language plpgsql security definer set search_path = public as $$
declare lim bigint; n bigint; sz bigint := doc_bytes(new.path, new.data); oldsz bigint := 0; cur bigint; r text;
begin
  -- An upsert of an existing record fires this as INSERT first, then as UPDATE: check it once, as the update.
  if tg_op = 'INSERT' and exists (select 1 from docs where org_id = new.org_id and path = new.path) then
    return new;
  end if;
  -- serialise writers of the same workspace while checking limits (prevents parallel-request bypass)
  insert into org_counters (org_id) values (new.org_id) on conflict (org_id) do nothing;
  select bytes into cur from org_counters where org_id = new.org_id for update;
  lim := org_limit(new.org_id, 'data_mb');
  if tg_op = 'UPDATE' then oldsz := doc_bytes(old.path, old.data); end if;
  -- growing past the quota is refused; shrinking or deleting is always allowed
  if lim is not null and sz > oldsz and cur - oldsz + sz > lim * 1048576 then
    raise exception 'This workspace has used its % MB of records. Upgrade the plan to add more.', lim
      using errcode = 'P0001', hint = 'plan_limit';
  end if;
  if tg_op = 'INSERT' and new.collection = 'setup/main/entities' then
    lim := org_limit(new.org_id, 'max_entities');
    if lim is not null then
      select count(*) into n from docs where org_id = new.org_id and collection = 'setup/main/entities' and path <> new.path;
      if n >= lim then
        raise exception 'Your plan allows % entit%. Upgrade to add more.', lim, case when lim = 1 then 'y' else 'ies' end
          using errcode = 'P0001', hint = 'plan_limit';
      end if;
    end if;
  end if;
  -- employees, customers and suppliers: small records, and not too many
  r := (select role from members where org_id = new.org_id and user_id = auth.uid() and status = 'active');
  if r = 'portal' then
    if octet_length(new.data::text) > 65536 then raise exception 'This item is too large.' using errcode = '54000'; end if;
    if tg_op = 'INSERT' and (select count(*) from docs where org_id = new.org_id
         and (path = 'portal/' || auth.uid()::text or path like 'portal/' || auth.uid()::text || '/%')) >= 2000 then
      raise exception 'You have reached the number of items you can store here.' using errcode = 'P0001', hint = 'plan_limit';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists docs_limits on public.docs;
create trigger docs_limits before insert or update on public.docs for each row execute function public.docs_limits();

create or replace function public.docs_count() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update org_counters set docs = docs + 1, bytes = bytes + doc_bytes(new.path, new.data) where org_id = new.org_id;
  elsif tg_op = 'UPDATE' then
    update org_counters set bytes = bytes - doc_bytes(old.path, old.data) + doc_bytes(new.path, new.data) where org_id = new.org_id;
  else
    update org_counters set docs = docs - 1, bytes = bytes - doc_bytes(old.path, old.data) where org_id = old.org_id;
  end if;
  return null;
end $$;
drop trigger if exists docs_count on public.docs;
create trigger docs_count after insert or update or delete on public.docs for each row execute function public.docs_count();

alter table public.docs enable row level security;
drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_read   on public.docs for select using (public.can_read_doc(org_id, path, data ->> 'entity'));
create policy docs_insert on public.docs for insert with check (public.can_write_doc(org_id, path, data ->> 'entity'));
create policy docs_update on public.docs for update
  using (public.can_write_doc(org_id, path, data ->> 'entity') and collection <> 'setup/main/access_log')
  with check (public.can_write_doc(org_id, path, data ->> 'entity'));
create policy docs_delete on public.docs for delete
  using (public.can_write_doc(org_id, path, data ->> 'entity') and collection <> 'setup/main/access_log');

-- Partial update merging top-level fields (runs with the caller's rights, so the rules apply)
create or replace function public.doc_update(p_org uuid, p_path text, p_patch jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  update docs set data = data || p_patch where org_id = p_org and path = p_path;
  if not found then
    raise exception 'missing %', p_path using errcode = 'P0002';
  end if;
end $$;

-- ============================================================================
-- 5. Logins: Settings → Logins and access writes setup/main/access/<user id>;
--    this mirrors it into members, applying plan limits.
-- ============================================================================
create or replace function public.sync_access() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid; r text; cur text; lim bigint; n bigint; k text; ents text[];
begin
  if tg_op = 'DELETE' then
    if old.collection = 'setup/main/access' then
      uid := safe_uuid(split_part(old.path, '/', 4));
      delete from members where org_id = old.org_id and user_id = uid and role <> 'owner';
    end if;
    return old;
  end if;
  if new.collection <> 'setup/main/access' then return new; end if;
  uid := safe_uuid(split_part(new.path, '/', 4));
  if uid is null or not exists (select 1 from auth.users where id = uid) then return new; end if;
  r := case
         when new.data ->> 'role' in ('employee', 'customer', 'supplier') then 'portal'
         when new.data ->> 'role' = 'auditor' then 'viewer'
         when new.data ->> 'role' in ('admin', 'accountant', 'approver', 'tax', 'custom') then 'staff'  -- only the owner can grant logins
         else null end;
  if r is null then
    raise exception 'Unknown role "%".', coalesce(new.data ->> 'role', '') using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('seats:' || new.org_id::text));
  select role into cur from members where org_id = new.org_id and user_id = uid;
  if cur = 'owner' then return new; end if;
  k := case when r = 'portal' then 'max_portal' else 'max_staff' end;
  if cur is null or (cur = 'portal') <> (r = 'portal') then
    lim := org_limit(new.org_id, k);
    if lim is not null then
      select count(*) into n from members
       where org_id = new.org_id and (case when r = 'portal' then role = 'portal' else role <> 'portal' end);
      if n >= lim then
        raise exception 'Your plan allows % % logins. Upgrade or remove someone first.',
          lim, case when r = 'portal' then 'employee, customer and supplier' else 'team' end
          using errcode = 'P0001', hint = 'plan_limit';
      end if;
    end if;
  end if;
  -- Companies this person may reach: data.entities = ["main","ksa"]; missing, empty or "all" = every company
  if r <> 'portal' and jsonb_typeof(new.data -> 'entities') = 'array' and jsonb_array_length(new.data -> 'entities') > 0 then
    select array_agg(distinct x) into ents from jsonb_array_elements_text(new.data -> 'entities') x where btrim(x) <> '';
    if ents is not null and 'all' = any (ents) then ents := null; end if;
  end if;
  -- New people are invited: they must accept before they can see anything.
  insert into members (org_id, user_id, role, status, entities) values (new.org_id, uid, r, 'invited', ents)
  on conflict (org_id, user_id) do update set role = excluded.role, entities = excluded.entities;
  return new;
end $$;
drop trigger if exists docs_access_sync on public.docs;
create trigger docs_access_sync after insert or update or delete on public.docs
  for each row execute function public.sync_access();

-- New sign-ups get a profile. Companies are created explicitly (create_org).
create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email)
  values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)), lower(new.email))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.on_new_user();

-- Keep the profile email in step with the verified sign-in email
create or replace function public.on_user_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set email = lower(new.email) where id = new.id;
  return new;
end $$;
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users for each row execute function public.on_user_email();

-- ============================================================================
-- 6. Row-level security on the other tables (writes go through functions only)
-- ============================================================================
create or replace function public.shares_org(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from members a join members b on a.org_id = b.org_id
     where a.user_id = auth.uid() and b.user_id = p_user and a.role in ('owner', 'staff', 'viewer') and a.status = 'active'
  )
$$;

alter table public.orgs            enable row level security;
alter table public.members         enable row level security;
alter table public.profiles        enable row level security;
alter table public.plans           enable row level security;
alter table public.platform_config enable row level security;
alter table public.platform_admins enable row level security;

drop policy if exists orgs_read on public.orgs;
create policy orgs_read on public.orgs for select using (public.my_role(id) is not null);
drop policy if exists members_read on public.members;
create policy members_read on public.members for select
  using (user_id = auth.uid() or public.my_role(org_id) in ('owner', 'staff', 'viewer'));
drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_read on public.profiles for select using (id = auth.uid() or public.shares_org(id));
create policy profiles_update_own on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (full_name) on public.profiles to authenticated;
drop policy if exists plans_read on public.plans;
create policy plans_read on public.plans for select using (auth.uid() is not null);
-- platform_config and platform_admins: no policies → only security-definer functions and the server.

-- ============================================================================
-- 7. Functions the app calls
-- ============================================================================
create or replace function public.app_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'mode', cfg('mode'),
    'support_email', nullif(cfg('support_email'), ''),
    'is_platform_admin', is_platform_admin(),
    'can_create_org', auth.uid() is not null and case
       when cfg('mode') = 'single' then not exists (select 1 from orgs)
       else (select count(*) from orgs where created_by = auth.uid()) < coalesce(cfg('max_orgs_per_user')::int, 3)
         or is_platform_admin()
     end
  )
$$;

drop function if exists public.create_org(text, boolean);
create or replace function public.create_org(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare oid uuid; single boolean := cfg('mode') = 'single';
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Enter a workspace name.' using errcode = '22023'; end if;
  if single then
    perform pg_advisory_xact_lock(hashtext('sme-suite-single-org'));
    if exists (select 1 from orgs) then
      raise exception 'This installation already has its workspace. Ask the owner to give you access.' using errcode = '42501';
    end if;
  elsif not is_platform_admin() then
    perform pg_advisory_xact_lock(hashtext('create_org:' || auth.uid()::text));
    if (select count(*) from orgs where created_by = auth.uid()) >= coalesce(cfg('max_orgs_per_user')::int, 3) then
      raise exception 'You have reached the number of workspaces you can create. Contact support to add more.' using errcode = '42501';
    end if;
  end if;

  insert into orgs (name, plan, status, trial_ends_at, created_by)
  values (btrim(p_name),
          case when single then 'dedicated' else 'trial' end,
          case when single then 'active' else 'trial' end,
          case when single then null else now() + make_interval(days => coalesce(cfg('trial_days')::int, 14)) end,
          auth.uid())
  returning id into oid;
  insert into members (org_id, user_id, role) values (oid, auth.uid(), 'owner');
  return oid;
end $$;

drop function if exists public.my_orgs();
create or replace function public.my_orgs() returns table (
  id uuid, name text, role text, status text, plan text, plan_name text,
  trial_ends_at timestamptz, writable boolean, invited boolean, invited_by text, entities text[]
)
language sql stable security definer set search_path = public as $$
  select o.id, o.name, m.role, o.status, o.plan, p.name, o.trial_ends_at, org_writable(o.id), m.status = 'invited',
         case when m.status = 'invited' then (select coalesce(pr.full_name, pr.email) from members x join profiles pr on pr.id = x.user_id
                                               where x.org_id = o.id and x.role = 'owner' order by x.created_at limit 1) end,
         m.entities
    from members m join orgs o on o.id = m.org_id join plans p on p.id = o.plan
   where m.user_id = auth.uid() and o.status <> 'cancelled'
   order by o.created_at
$$;

create or replace function public.answer_invite(p_org uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    update members set status = 'active' where org_id = p_org and user_id = auth.uid() and status = 'invited';
  else
    delete from members where org_id = p_org and user_id = auth.uid() and status = 'invited';
  end if;
  if not found then raise exception 'No invitation found.' using errcode = 'P0002'; end if;
end $$;

create or replace function public.rename_org(p_org uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if my_role(p_org) is distinct from 'owner' then raise exception 'Only the owner can rename the workspace.' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Enter a workspace name.' using errcode = '22023'; end if;
  update orgs set name = btrim(p_name) where id = p_org;
end $$;

create or replace function public.org_storage_bytes(p_org uuid) returns bigint
language sql stable security definer set search_path = public, storage as $$
  select coalesce(sum((metadata ->> 'size')::bigint), 0)::bigint
    from storage.objects where bucket_id = 'assets' and name like p_org::text || '/%'
$$;

-- Usage of AI agents (written by the server only)
create table if not exists public.ai_log (
  id            bigserial primary key,
  org_id        uuid not null references public.orgs (id) on delete cascade,
  user_id       uuid references auth.users (id) on delete set null,
  at            timestamptz not null default now(),
  tier          text,
  model         text,
  input_tokens  int,
  output_tokens int,
  ok            boolean
);
create index if not exists ai_log_org_at_idx  on public.ai_log (org_id, at);
create index if not exists ai_log_user_at_idx on public.ai_log (user_id, at);
alter table public.ai_log enable row level security;

create or replace function public.org_usage(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r text := my_role(p_org); o orgs; p plans;
begin
  if r is null and not is_platform_admin() then raise exception 'No access to this workspace.' using errcode = '42501'; end if;
  select * into o from orgs where id = p_org;
  select * into p from plans where id = o.plan;
  return jsonb_build_object(
    'name', o.name, 'status', o.status, 'plan', o.plan, 'plan_name', p.name,
    'trial_ends_at', o.trial_ends_at, 'writable', org_writable(p_org), 'role', r,
    'staff',    jsonb_build_object('used', (select count(*) from members where org_id = p_org and role <> 'portal'), 'limit', org_limit(p_org, 'max_staff')),
    'portal',   jsonb_build_object('used', (select count(*) from members where org_id = p_org and role = 'portal'), 'limit', org_limit(p_org, 'max_portal')),
    'entities', jsonb_build_object('used', (select count(*) from docs where org_id = p_org and collection = 'setup/main/entities'), 'limit', org_limit(p_org, 'max_entities')),
    'ai',       jsonb_build_object('used', (select count(*) from ai_log where org_id = p_org and at >= date_trunc('month', now()) and ok is not false), 'limit', org_limit(p_org, 'ai_calls_month')),
    'ai_tokens', jsonb_build_object('used', (select coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) from ai_log where org_id = p_org and at >= date_trunc('month', now())), 'limit', org_limit(p_org, 'ai_tokens_month')),
    'records',  jsonb_build_object('used_mb', round(coalesce((select bytes from org_counters where org_id = p_org), 0) / 1048576.0, 1), 'limit', org_limit(p_org, 'data_mb')),
    'storage',  jsonb_build_object('used_mb', round(org_storage_bytes(p_org) / 1048576.0, 1), 'limit', org_limit(p_org, 'storage_mb')),
    'plans', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'max_staff', max_staff, 'max_portal', max_portal,
                'max_entities', max_entities, 'ai_calls_month', ai_calls_month, 'ai_tokens_month', ai_tokens_month,
                'storage_mb', storage_mb, 'data_mb', data_mb,
                'price_month', price_month, 'currency', currency) order by sort) from plans where public)
  );
end $$;

-- People search for Settings → Logins and access: members of this company by name or email,
-- plus anyone already signed up whose email is typed in full. Owners and staff only.
create table if not exists public.lookup_log (
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists lookup_log_user_at_idx on public.lookup_log (user_id, at);
alter table public.lookup_log enable row level security;

drop function if exists public.people_search(uuid, text);
create or replace function public.people_search(p_org uuid, p_q text) returns table (id uuid, name text, email text)
language plpgsql volatile security definer set search_path = public, auth as $$
declare q text := lower(btrim(coalesce(p_q, ''))); hit uuid;
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') then return; end if;
  -- people already in this workspace (active or invited), by name or email
  return query
    select pr.id, coalesce(pr.full_name, pr.email), pr.email
      from members m join profiles pr on pr.id = m.user_id
     where m.org_id = p_org
       and (q = '' or lower(coalesce(pr.full_name, '')) like '%' || q || '%' or lower(pr.email) like '%' || q || '%')
     limit 20;
  -- anyone else only by their full, verified sign-in email; shown by email, never by name; rate limited
  if q ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     and not exists (select 1 from members m join profiles pr on pr.id = m.user_id where m.org_id = p_org and pr.email = q) then
    if (select count(*) from lookup_log where user_id = auth.uid() and at > now() - interval '1 hour') >= 30 then return; end if;
    insert into lookup_log (user_id) values (auth.uid());
    select u.id into hit from auth.users u where lower(u.email) = q and u.email_confirmed_at is not null limit 1;
    if hit is not null then
      return query select hit, q, q;
    end if;
  end if;
end $$;

-- Names for user ids shown in the app (approvers, authors…), limited to this company's people
create or replace function public.org_profiles(p_org uuid, p_ids uuid[]) returns table (id uuid, name text, email text)
language sql stable security definer set search_path = public as $$
  select pr.id, coalesce(pr.full_name, pr.email), case when my_role(p_org) in ('owner', 'staff', 'viewer') then pr.email end
    from profiles pr join members m on m.user_id = pr.id and m.org_id = p_org
   where pr.id = any (p_ids) and my_role(p_org) is not null
$$;

-- Server-side gate for AI calls (service role only): membership, company status,
-- per-person rate and monthly plan quota. Returns a log id to finish later.
create or replace function public.ai_begin(p_org uuid, p_user uuid, p_tier text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text; lim bigint; used bigint; per_min int := coalesce(cfg('ai_calls_per_minute')::int, 30); lid bigint;
begin
  select role into r from members where org_id = p_org and user_id = p_user and status = 'active';
  if r is null then return jsonb_build_object('ok', false, 'status', 403, 'message', 'You do not have access to this workspace.'); end if;
  if not org_writable(p_org) then
    return jsonb_build_object('ok', false, 'status', 402, 'message', 'AI agents are paused because this workspace''s trial or subscription has ended.');
  end if;
  perform pg_advisory_xact_lock(hashtext('ai:' || p_org::text));
  if (select count(*) from ai_log where user_id = p_user and at > now() - interval '1 minute') >= per_min then
    return jsonb_build_object('ok', false, 'status', 429, 'message', 'Too many AI requests. Wait a minute and try again.');
  end if;
  lim := org_limit(p_org, 'ai_calls_month');
  if lim is not null then
    select count(*) into used from ai_log where org_id = p_org and at >= date_trunc('month', now()) and ok is not false;
    if used >= lim then
      return jsonb_build_object('ok', false, 'status', 402, 'message',
        format('This workspace has used its %s AI agent calls for this month. Upgrade the plan or wait until next month.', lim));
    end if;
  end if;
  lim := org_limit(p_org, 'ai_tokens_month');
  if lim is not null then
    select coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) into used
      from ai_log where org_id = p_org and at >= date_trunc('month', now());
    if used >= lim then
      return jsonb_build_object('ok', false, 'status', 402, 'message',
        'This workspace has used its AI allowance for this month. Upgrade the plan or wait until next month.');
    end if;
  end if;
  insert into ai_log (org_id, user_id, tier) values (p_org, p_user, p_tier) returning id into lid;
  return jsonb_build_object('ok', true, 'log_id', lid, 'role', r,
    'trial', (select status = 'trial' from orgs where id = p_org));
end $$;

create or replace function public.ai_finish(p_id bigint, p_model text, p_in int, p_out int, p_ok boolean) returns void
language sql security definer set search_path = public as $$
  update ai_log set model = p_model, input_tokens = p_in, output_tokens = p_out, ok = p_ok where id = p_id
$$;

-- Files: who may open /_blob/<id> (service role only). Staff and viewers: any file of the company.
-- Portal users: only files referenced in their own portal records.
create or replace function public.blob_allowed(p_org uuid, p_user uuid, p_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select case (select role from members where org_id = p_org and user_id = p_user and status = 'active')
    when 'owner' then org_readable(p_org) when 'staff' then org_readable(p_org) when 'viewer' then org_readable(p_org)
    when 'portal' then org_readable(p_org) and exists (
      select 1 from docs d
       where d.org_id = p_org
         and (d.path = 'portal/' || p_user::text or d.path like 'portal/' || p_user::text || '/%')
         and position(p_id in d.data::text) > 0
         -- the link must have been placed by the owner or staff, not by the portal user
         and exists (select 1 from members s where s.org_id = p_org and s.user_id = d.updated_by
                       and s.role in ('owner', 'staff') and s.status = 'active'))
    else false end
$$;

-- Which of this person's companies holds file <id> and may they open it? (service role only)
create or replace function public.blob_locate(p_user uuid, p_id text) returns uuid
language sql stable security definer set search_path = public, storage as $$
  select m.org_id from members m
   where m.user_id = p_user and m.status = 'active'
     and exists (select 1 from storage.objects o where o.bucket_id = 'assets' and o.name = m.org_id::text || '/' || p_id)
     and blob_allowed(m.org_id, p_user, p_id)
   limit 1
$$;

-- ============================================================================
-- 8. Platform admin console (your own view across all companies — metadata only,
--    never the companies' books)
-- ============================================================================
create or replace function public.admin_orgs() returns table (
  id uuid, name text, plan text, status text, trial_ends_at timestamptz, created_at timestamptz,
  owner_email text, staff bigint, portal bigint, ai_month bigint, ai_tokens_month bigint,
  storage_mb numeric, records bigint, data_mb numeric, last_activity timestamptz, limits jsonb, notes text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return query
  select o.id, o.name, o.plan, o.status, o.trial_ends_at, o.created_at,
         (select pr.email from members m join profiles pr on pr.id = m.user_id
           where m.org_id = o.id and m.role = 'owner' order by m.created_at limit 1),
         (select count(*) from members m where m.org_id = o.id and m.role <> 'portal'),
         (select count(*) from members m where m.org_id = o.id and m.role = 'portal'),
         (select count(*) from ai_log a where a.org_id = o.id and a.at >= date_trunc('month', now()) and a.ok is not false),
         (select coalesce(sum(coalesce(a.input_tokens, 0) + coalesce(a.output_tokens, 0)), 0)::bigint
            from ai_log a where a.org_id = o.id and a.at >= date_trunc('month', now())),
         round(org_storage_bytes(o.id) / 1048576.0, 1),
         coalesce((select c.docs from org_counters c where c.org_id = o.id), 0),
         round(coalesce((select c.bytes from org_counters c where c.org_id = o.id), 0) / 1048576.0, 1),
         (select max(d.updated_at) from docs d where d.org_id = o.id),
         o.limits, o.notes
    from orgs o order by o.created_at desc;
end $$;

create or replace function public.admin_update_org(
  p_org uuid, p_plan text default null, p_status text default null,
  p_trial_ends_at timestamptz default null, p_limits jsonb default null, p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  update orgs set
    plan          = coalesce(p_plan, plan),
    status        = coalesce(p_status, status),
    trial_ends_at = coalesce(p_trial_ends_at, trial_ends_at),
    limits        = coalesce(p_limits, limits),
    notes         = coalesce(p_notes, notes)
  where id = p_org;
  if not found then raise exception 'Workspace not found.' using errcode = 'P0002'; end if;
end $$;

create or replace function public.admin_plans() returns setof public.plans
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return query select * from plans order by sort;
end $$;

create or replace function public.admin_save_plan(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  insert into plans (id, name, sort, price_month, currency, max_staff, max_portal, max_entities, ai_calls_month, ai_tokens_month, storage_mb, data_mb, public)
  values (p ->> 'id', p ->> 'name', coalesce((p ->> 'sort')::int, 9), (p ->> 'price_month')::numeric, coalesce(p ->> 'currency', 'USD'),
          (p ->> 'max_staff')::int, (p ->> 'max_portal')::int, (p ->> 'max_entities')::int,
          (p ->> 'ai_calls_month')::int, (p ->> 'ai_tokens_month')::bigint, (p ->> 'storage_mb')::int, (p ->> 'data_mb')::int,
          coalesce((p ->> 'public')::boolean, true))
  on conflict (id) do update set
    name = excluded.name, sort = excluded.sort, price_month = excluded.price_month, currency = excluded.currency,
    max_staff = excluded.max_staff, max_portal = excluded.max_portal, max_entities = excluded.max_entities,
    ai_calls_month = excluded.ai_calls_month, ai_tokens_month = excluded.ai_tokens_month,
    storage_mb = excluded.storage_mb, data_mb = excluded.data_mb, public = excluded.public;
end $$;

create or replace function public.admin_config() returns setof public.platform_config
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return query select * from platform_config order by key;
end $$;

create or replace function public.admin_set_config(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  if p_key = 'mode' and p_value not in ('saas', 'single') then raise exception 'mode must be saas or single'; end if;
  update platform_config set value = coalesce(p_value, '') where key = p_key;
  if not found then raise exception 'Unknown setting %', p_key; end if;
end $$;

-- ============================================================================
-- 9. Realtime for live updates between users (rules above apply to every event)
-- ============================================================================
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- ============================================================================
-- 10. Private file storage: assets/<company id>/<file id>
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit)
values ('assets', 'assets', false, 20971520)
on conflict (id) do update set public = false, file_size_limit = 20971520;

create or replace function public.can_upload(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role(safe_uuid(split_part(p_name, '/', 1))) in ('owner', 'staff'), false)
     and org_writable(safe_uuid(split_part(p_name, '/', 1)))
     and coalesce(org_storage_bytes(safe_uuid(split_part(p_name, '/', 1)))
                  < org_limit(safe_uuid(split_part(p_name, '/', 1)), 'storage_mb') * 1048576, true)
$$;

create or replace function public.can_read_asset(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role(safe_uuid(split_part(p_name, '/', 1))) in ('owner', 'staff', 'viewer'), false)
     and org_readable(safe_uuid(split_part(p_name, '/', 1)))
$$;
create or replace function public.can_delete_asset(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role(safe_uuid(split_part(p_name, '/', 1))) in ('owner', 'staff'), false)
     and org_writable(safe_uuid(split_part(p_name, '/', 1)))
$$;

drop policy if exists assets_staff_insert on storage.objects;
drop policy if exists assets_staff_delete on storage.objects;
drop policy if exists assets_members_read on storage.objects;
drop policy if exists assets_org_insert on storage.objects;
drop policy if exists assets_org_delete on storage.objects;
drop policy if exists assets_org_read   on storage.objects;
create policy assets_org_insert on storage.objects for insert
  with check (bucket_id = 'assets' and public.can_upload(name));
create policy assets_org_delete on storage.objects for delete
  using (bucket_id = 'assets' and public.can_delete_asset(name));
create policy assets_org_read on storage.objects for select
  using (bucket_id = 'assets' and public.can_read_asset(name));

-- ============================================================================
-- 11. Who may call what (kept last so it covers every function above)
-- ============================================================================
-- Nothing for anonymous visitors; signed-in users get the app's functions; then the exceptions below.
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.org_limit(uuid, text)                   from authenticated;
revoke execute on function public.org_storage_bytes(uuid)                 from authenticated;
revoke execute on function public.org_readable(uuid)                      from authenticated;
revoke execute on function public.org_writable(uuid)                      from authenticated;
revoke execute on function public.ai_begin(uuid, uuid, text)              from public, anon, authenticated;
revoke execute on function public.ai_finish(bigint, text, int, int, boolean) from public, anon, authenticated;
revoke execute on function public.blob_allowed(uuid, uuid, text)          from public, anon, authenticated;
revoke execute on function public.cfg(text)                               from public, anon, authenticated;
revoke execute on function public.blob_locate(uuid, text)                 from public, anon, authenticated;
grant  execute on function public.blob_locate(uuid, text)                 to service_role;
grant  execute on function public.ai_begin(uuid, uuid, text)              to service_role;
grant  execute on function public.ai_finish(bigint, text, int, int, boolean) to service_role;
grant  execute on function public.blob_allowed(uuid, uuid, text)          to service_role;
grant  execute on function public.cfg(text)                               to service_role;
revoke all on public.ai_log, public.platform_config, public.platform_admins,
              public.org_counters, public.lookup_log from anon, authenticated;

-- Recompute record counters (safe to re-run)
insert into public.org_counters (org_id, docs, bytes)
select org_id, count(*), coalesce(sum(public.doc_bytes(path, data)), 0) from public.docs group by org_id
on conflict (org_id) do update set docs = excluded.docs, bytes = excluded.bytes;

-- ============================================================================
-- Make yourself platform admin (after signing up once), then open /admin:
--   insert into public.platform_admins (user_id)
--   select id from auth.users where email = 'you@example.com';
-- ============================================================================
