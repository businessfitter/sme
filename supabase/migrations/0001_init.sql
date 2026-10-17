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
  ('open_access', 'true'),
  ('signup_approval', 'true'),    -- 'true': new sign-ups wait for a platform admin to approve them        -- 'true': no trial, no plan limits (set to 'false' when plans start)
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
-- New sign-ups wait for a platform admin's approval (signup_approval = 'true'); people added by a company admin do not
alter table public.profiles add column if not exists approval text not null default 'approved';
alter table public.profiles add column if not exists signed_up_at timestamptz default now();
alter table public.profiles add column if not exists approved_at timestamptz;
alter table public.profiles add column if not exists approved_by uuid;
alter table public.profiles add column if not exists request jsonb;

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
-- Company-level roles: companies where this person may only read (an "auditor" role set for that company),
-- and whether an HQ login may open the consolidated group (group-level records: entity = 'group').
alter table public.members add column if not exists ro_entities text[];
alter table public.members add column if not exists group_view boolean not null default true;
-- Time-limited access (temporary staff, auditors, delegations): no access after this moment
alter table public.members add column if not exists expires_at timestamptz;
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
  select role from members where org_id = p_org and user_id = auth.uid() and status = 'active' and (expires_at is null or expires_at > now())
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
declare ents text[]; gv boolean;
begin
  select entities, group_view into ents, gv from members where org_id = p_org and user_id = auth.uid() and status = 'active' and (expires_at is null or expires_at > now());
  -- group-level records (consolidation adjustments) only for HQ logins with the consolidated view
  if p_entity = 'group' then return ents is null and coalesce(gv, true); end if;
  if ents is null then return true; end if;
  if p_path like 'setup/main/entities/%' then return split_part(p_path, '/', 4) = any (ents); end if;
  if p_path = 'setup/main' or p_path like 'setup/main/journals/%' or p_path like 'setup/main/workflows/%'
     or p_path like 'setup/main/fx/%' or p_path like 'setup/main/access/%' or p_path like 'setup/main/access_log/%' then
    return true;
  end if;
  return coalesce(nullif(p_entity, ''), 'main') = any (ents);
end $$;

-- Companies where the person's company-level role is read-only: they can read but not change that company's records.
create or replace function public.entity_readonly(p_org uuid, p_path text, p_entity text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare ro text[];
begin
  select ro_entities into ro from members where org_id = p_org and user_id = auth.uid() and status = 'active';
  if ro is null or cardinality(ro) = 0 then return false; end if;
  if p_path like 'setup/main/entities/%' then return split_part(p_path, '/', 4) = any (ro); end if;
  if p_path = 'setup/main' or p_path like 'setup/main/journals/%' or p_path like 'setup/main/workflows/%'
     or p_path like 'setup/main/fx/%' or p_path like 'setup/main/access_log/%' or p_path like 'portal/%' then
    return false;
  end if;
  if p_entity = 'group' then return false; end if;
  return coalesce(nullif(p_entity, ''), 'main') = any (ro);
end $$;

-- The person's role inside the app (ceo, cfo, hr_mgr, accountant…), from the login the owner gave them
create or replace function public.my_app_role(p_org uuid) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if my_role(p_org) = 'owner' then return 'owner'; end if;
  if my_role(p_org) is null then return null; end if;
  return (select data ->> 'role' from docs where org_id = p_org and path = 'setup/main/access/' || auth.uid()::text);
end $$;

drop function if exists public.can_read_doc(uuid, text) cascade;
drop function if exists public.can_write_doc(uuid, text) cascade;
create or replace function public.can_read_doc(p_org uuid, p_path text, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select case my_role(p_org)
    when 'owner'  then org_readable(p_org)
    when 'staff'  then org_readable(p_org) and entity_allowed(p_org, p_path, p_entity)
    when 'viewer' then org_readable(p_org) and entity_allowed(p_org, p_path, p_entity)
    when 'portal' then org_readable(p_org) and (own_portal(p_path) or (p_path like 'library/emp-%' and my_app_role(p_org) = 'employee'))
    else false end
$$;

-- Only owners grant or change logins; the access log is append-only (see policies).
create or replace function public.can_write_doc(p_org uuid, p_path text, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select org_writable(p_org) and case my_role(p_org)
    when 'owner'  then true
    when 'staff'  then (p_path not like 'setup/main/access/%'
                        or (my_app_role(p_org) = 'ceo' and p_path <> 'setup/main/access/' || auth.uid()::text))
                       and entity_allowed(p_org, p_path, p_entity)
                       and not entity_readonly(p_org, p_path, p_entity)
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
  r := (select role from members where org_id = new.org_id and user_id = auth.uid() and status = 'active' and (expires_at is null or expires_at > now()));
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
declare uid uuid; r text; cur text; lim bigint; n bigint; k text; ents text[]; ro text[]; gv boolean;
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
         when new.data ->> 'role' in ('admin', 'accountant', 'approver', 'tax', 'custom', 'ceo', 'cfo', 'compliance', 'audit_mgr',
                                      'fin_acc', 'hr_mgr', 'manager', 'officer', 'clinic_mgr', 'doctor', 'nurse', 'pharmacist',
                                      'lab_tech', 'receptionist', 'cashier', 'it_support', 'ecom_mgr', 'warehouse_mgr', 'storekeeper', 'procurement') then 'staff'  -- only the owner (or the CEO) can grant logins
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
  -- Company-level read-only roles (data.ent_perms = {"ksa": {"role": "auditor"}}) and the consolidated view (data.consolidated)
  if r <> 'portal' and jsonb_typeof(new.data -> 'ent_perms') = 'object' then
    select array_agg(key) into ro from jsonb_each(new.data -> 'ent_perms') where value ->> 'role' = 'auditor';
  end if;
  gv := ents is null and coalesce((new.data ->> 'consolidated')::boolean, true);
  -- New people are invited: they must accept before they can see anything.
  insert into members (org_id, user_id, role, status, entities, expires_at, ro_entities, group_view)
  values (new.org_id, uid, r, 'invited', ents, case when coalesce(new.data ->> 'expires_at', '') ~ '^\d{4}-\d{2}-\d{2}' then (new.data ->> 'expires_at')::timestamptz end, ro, gv)
  on conflict (org_id, user_id) do update set role = excluded.role, entities = excluded.entities, expires_at = excluded.expires_at, ro_entities = excluded.ro_entities, group_view = excluded.group_view;
  return new;
end $$;
drop trigger if exists docs_access_sync on public.docs;
create trigger docs_access_sync after insert or update or delete on public.docs
  for each row execute function public.sync_access();

-- New sign-ups get a profile. Companies are created explicitly (create_org).
create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name, email, approval, signed_up_at)
  values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)), lower(new.email),
          case when coalesce(cfg('signup_approval'), 'true') = 'true' and coalesce(new.raw_user_meta_data ->> 'created_by', '') = '' then 'pending' else 'approved' end, now())
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
     where a.user_id = auth.uid() and b.user_id = p_user and a.role in ('owner', 'staff', 'viewer') and a.status = 'active' and (a.expires_at is null or a.expires_at > now())
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

  if not single and not is_platform_admin() and coalesce((select approval from profiles where id = auth.uid()), 'approved') <> 'approved' then
    raise exception 'Your sign-up is waiting for approval. You will get an email once it is approved.' using errcode = '42501';
  end if;
  insert into orgs (name, plan, status, trial_ends_at, created_by)
  values (btrim(p_name),
          -- no trial for now: every new workspace is open with no limits until plans are introduced
          case when single or coalesce(cfg('open_access'), 'true') = 'true' then 'dedicated' else 'trial' end,
          case when single or coalesce(cfg('open_access'), 'true') = 'true' then 'active' else 'trial' end,
          case when single or coalesce(cfg('open_access'), 'true') = 'true' then null else now() + make_interval(days => coalesce(cfg('trial_days')::int, 14)) end,
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
  select role into r from members where org_id = p_org and user_id = p_user and status = 'active' and (expires_at is null or expires_at > now());
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
  select case (select role from members where org_id = p_org and user_id = p_user and status = 'active' and (expires_at is null or expires_at > now()))
    when 'owner' then org_readable(p_org) when 'staff' then org_readable(p_org) when 'viewer' then org_readable(p_org)
    when 'portal' then org_readable(p_org) and exists (
      select 1 from docs d
       where d.org_id = p_org
         and (d.path = 'portal/' || p_user::text or d.path like 'portal/' || p_user::text || '/%')
         and position(p_id in d.data::text) > 0
         -- the link must have been placed by the owner or staff, not by the portal user
         and exists (select 1 from members s where s.org_id = p_org and s.user_id = d.updated_by
                       and s.role in ('owner', 'staff') and s.status = 'active' and (s.expires_at is null or s.expires_at > now())))
    else false end
$$;

-- Which of this person's companies holds file <id> and may they open it? (service role only)
create or replace function public.blob_locate(p_user uuid, p_id text) returns uuid
language sql stable security definer set search_path = public, storage as $$
  select m.org_id from members m
   where m.user_id = p_user and m.status = 'active' and (m.expires_at is null or m.expires_at > now())
     and exists (select 1 from storage.objects o where o.bucket_id = 'assets' and o.name = m.org_id::text || '/' || p_id)
     and blob_allowed(m.org_id, p_user, p_id)
   limit 1
$$;

-- ============================================================================
-- 7b. Employee Lounge: verified attendance and portal write guard
--     Check-ins are written only by att_punch(), which takes the time from the
--     database clock, measures the distance to the chosen office itself and
--     refuses anything outside the radius. Nobody can insert, edit or delete a
--     check-in directly, not even the workspace owner; corrections are made as
--     separate, signed records in the app.
-- ============================================================================
create table if not exists public.attendance_punches (
  id           bigint generated always as identity primary key,
  org_id       uuid not null references public.orgs (id) on delete cascade,
  user_id      uuid not null,
  employee_id  text not null,
  entity       text not null default 'main',
  site_id      text,
  site_name    text,
  kind         text not null check (kind in ('in', 'out', 'denied')),
  reason       text,                                   -- why a denied attempt was refused
  at           timestamptz not null default now(),     -- database clock, never the phone's
  work_date    date not null,
  local_time   text not null,
  tz           text not null,
  lat          double precision,
  lng          double precision,
  accuracy_m   real,
  distance_m   real,
  device       text,
  flags        text[] not null default '{}'
);
create index if not exists attendance_punches_org_date on public.attendance_punches (org_id, work_date);
create index if not exists attendance_punches_user on public.attendance_punches (org_id, user_id, at desc);

create table if not exists public.attendance_devices (
  org_id     uuid not null references public.orgs (id) on delete cascade,
  user_id    uuid not null,
  device     text not null,
  first_seen timestamptz not null default now(),
  primary key (org_id, user_id)
);

alter table public.attendance_punches enable row level security;
alter table public.attendance_devices enable row level security;
create or replace function public.punch_visible(p_org uuid, p_user uuid, p_entity text) returns boolean
language sql stable security definer set search_path = public as $$
  select org_readable(p_org) and (
    (p_user = auth.uid() and my_role(p_org) is not null)
    or (my_role(p_org) in ('owner', 'staff', 'viewer') and entity_allowed(p_org, 'attendance/x', p_entity)))
$$;
drop policy if exists punches_read on public.attendance_punches;
create policy punches_read on public.attendance_punches for select to authenticated using (punch_visible(org_id, user_id, entity));
drop policy if exists devices_read on public.attendance_devices;
create policy devices_read on public.attendance_devices for select to authenticated using (
  user_id = auth.uid() or my_role(org_id) in ('owner', 'staff'));
revoke insert, update, delete, truncate on public.attendance_punches, public.attendance_devices from anon, authenticated;
grant select on public.attendance_punches, public.attendance_devices to authenticated;

-- Great-circle distance in metres
create or replace function public.geo_distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8) returns float8
language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- The caller's employee link and company settings, read from the records the owner keeps
create or replace function public.att_context(p_org uuid, out emp text, out ent text, out cfg jsonb, out tz text)
language plpgsql stable security definer set search_path = public as $$
declare acc jsonb;
begin
  if auth.uid() is null or my_role(p_org) is null then
    raise exception 'You are not a member of this workspace.' using errcode = '42501';
  end if;
  select data into acc from docs where org_id = p_org and path = 'setup/main/access/' || auth.uid()::text;
  emp := nullif(acc ->> 'employee_id', '');
  if emp is null then
    raise exception 'Your login is not linked to an employee record yet. Ask HR to link it in Logins and access.' using errcode = '42501';
  end if;
  ent := coalesce(nullif(acc ->> 'entity', ''), 'main');
  select data into cfg from docs where org_id = p_org and path = 'setup/main/entities/' || ent;
  cfg := coalesce(cfg, '{}'::jsonb);
  tz := coalesce(nullif(cfg #>> '{att_geo,tz}', ''), 'Asia/Dubai');
  if not exists (select 1 from pg_timezone_names where name = tz) then tz := 'Asia/Dubai'; end if;
end $$;

-- What the employee's check-in screen needs: offices, rules, server time, today's punches
create or replace function public.att_status(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c record; today date; sites jsonb;
begin
  select * into c from att_context(p_org);
  today := (now() at time zone c.tz)::date;
  select coalesce(jsonb_agg(jsonb_build_object('id', s ->> 'id', 'name', s ->> 'name', 'lat', (s ->> 'lat')::float8,
           'lng', (s ->> 'lng')::float8, 'radius', least(greatest(coalesce((s ->> 'radius')::int, 500), 50), 1000), 'address', s ->> 'address')), '[]'::jsonb)
    into sites
    from jsonb_array_elements(coalesce(c.cfg -> 'att_sites', '[]'::jsonb)) s
   where coalesce((s ->> 'active')::boolean, true) and s ? 'lat' and s ? 'lng';
  return jsonb_build_object(
    'server_time', now(), 'tz', c.tz, 'date', today, 'local_time', to_char(now() at time zone c.tz, 'HH24:MI:SS'),
    'employee_id', c.emp, 'entity', c.ent, 'sites', sites,
    'max_accuracy', least(greatest(coalesce((c.cfg #>> '{att_geo,max_accuracy}')::int, 100), 20), 500),
    'device_lock', coalesce((c.cfg #>> '{att_geo,device_lock}')::boolean, false),
    'shift', coalesce(c.cfg -> 'att_shift', '{}'::jsonb),
    'leave_policy', coalesce(c.cfg -> 'leave_policy', '{}'::jsonb),
    'punches', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'local_time', local_time, 'site_name', site_name,
                 'distance_m', round(distance_m), 'reason', reason, 'flags', flags) order by at)
               from attendance_punches where org_id = p_org and user_id = auth.uid() and work_date = today), '[]'::jsonb));
end $$;

-- Check in or out. Returns {ok, kind, local_time, …} or {ok:false, reason, distance_m, …}.
create or replace function public.att_punch(p_org uuid, p_site text, p_lat float8, p_lng float8, p_acc float8, p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c record; s jsonb; dist float8; radius int; max_acc int; today date; nowl text;
  last_kind text; prev record; flags text[] := '{}'; dev text; known text; lock boolean;
  speed float8; k text;
begin
  select * into c from att_context(p_org);
  if not org_writable(p_org) then
    raise exception 'This workspace is read-only, so attendance cannot be recorded.' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Your location could not be read. Allow location access and try again.' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('att:' || p_org::text || auth.uid()::text));
  today := (now() at time zone c.tz)::date;
  nowl := to_char(now() at time zone c.tz, 'HH24:MI');
  dev := left(coalesce(nullif(p_device, ''), 'unknown'), 80);

  select el into s from jsonb_array_elements(coalesce(c.cfg -> 'att_sites', '[]'::jsonb)) el
   where el ->> 'id' = p_site and coalesce((el ->> 'active')::boolean, true) and el ? 'lat' and el ? 'lng' limit 1;
  if s is null then
    raise exception 'Choose one of your office locations.' using errcode = '22023';
  end if;
  radius  := least(greatest(coalesce((s ->> 'radius')::int, 500), 50), 1000);
  max_acc := least(greatest(coalesce((c.cfg #>> '{att_geo,max_accuracy}')::int, 100), 20), 500);
  lock    := coalesce((c.cfg #>> '{att_geo,device_lock}')::boolean, false);
  dist    := geo_distance_m(p_lat, p_lng, (s ->> 'lat')::float8, (s ->> 'lng')::float8);

  -- one attempt a minute
  if exists (select 1 from attendance_punches where org_id = p_org and user_id = auth.uid() and at > now() - interval '60 seconds') then
    return jsonb_build_object('ok', false, 'reason', 'too_soon');
  end if;

  -- device: first phone is registered; another phone is flagged (or refused when locked)
  select device into known from attendance_devices where org_id = p_org and user_id = auth.uid();
  if known is null then
    insert into attendance_devices (org_id, user_id, device) values (p_org, auth.uid(), dev);
  elsif known <> dev then
    flags := array_append(flags, 'new device');
  end if;

  -- implausible movement since the last check-in
  select * into prev from attendance_punches where org_id = p_org and user_id = auth.uid() and lat is not null order by at desc limit 1;
  if prev.id is not null then
    speed := geo_distance_m(p_lat, p_lng, prev.lat, prev.lng) / 1000 / greatest(extract(epoch from now() - prev.at) / 3600, 1.0 / 60);
    if speed > 250 and geo_distance_m(p_lat, p_lng, prev.lat, prev.lng) > 5000 then
      flags := array_append(flags, 'impossible travel');
    end if;
  end if;

  k := null;
  if p_acc is null or p_acc <= 0 or p_acc > max_acc then k := 'accuracy';
  elsif dist > radius then k := 'far';
  elsif lock and known is not null and known <> dev then k := 'device';
  end if;
  if k is not null then
    insert into attendance_punches (org_id, user_id, employee_id, entity, site_id, site_name, kind, reason, work_date, local_time, tz, lat, lng, accuracy_m, distance_m, device, flags)
    values (p_org, auth.uid(), c.emp, c.ent, s ->> 'id', s ->> 'name', 'denied', k, today, nowl, c.tz, p_lat, p_lng, p_acc, dist, dev, flags);
    return jsonb_build_object('ok', false, 'reason', k, 'distance_m', round(dist), 'radius', radius,
      'accuracy_m', round(coalesce(p_acc, 0)), 'max_accuracy', max_acc, 'site_name', s ->> 'name', 'local_time', nowl);
  end if;

  select kind into last_kind from attendance_punches
   where org_id = p_org and user_id = auth.uid() and work_date = today and kind in ('in', 'out') order by at desc limit 1;
  k := case when last_kind = 'in' then 'out' else 'in' end;
  insert into attendance_punches (org_id, user_id, employee_id, entity, site_id, site_name, kind, work_date, local_time, tz, lat, lng, accuracy_m, distance_m, device, flags)
  values (p_org, auth.uid(), c.emp, c.ent, s ->> 'id', s ->> 'name', k, today, nowl, c.tz, p_lat, p_lng, p_acc, dist, dev, flags);
  return jsonb_build_object('ok', true, 'kind', k, 'local_time', nowl, 'date', today, 'site_name', s ->> 'name',
    'distance_m', round(dist), 'flags', flags);
end $$;

-- HR lets an employee register a new phone
create or replace function public.att_reset_device(p_org uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') or not org_writable(p_org) then
    raise exception 'Only HR can reset a registered phone.' using errcode = '42501';
  end if;
  delete from attendance_devices where org_id = p_org and user_id = p_user;
end $$;

-- Employees, customers and suppliers may only add their own requests, leave, time, uploads,
-- signatures, task updates and self-reviews. They cannot change what the company published to
-- them (payslips, tasks, appraisals), record their own attendance, or approve their own requests.
create or replace function public.docs_portal_guard() returns trigger
language plpgsql set search_path = public as $$
declare me text := coalesce(auth.uid()::text, '');
begin
  if coalesce(my_role(new.org_id), '') <> 'portal' then return new; end if;
  if new.path !~ ('^portal/' || me || '/(concerns|leaves|requests|signatures|timesheets|uploads|task_updates|appraisal_self|quote_requests|quote_responses|payments|rfq_quotes)/[^/]+$') then
    raise exception 'This record is kept by the company and cannot be changed from your dashboard.' using errcode = '42501';
  end if;
  if new.path ~ '/(leaves|requests)/' then
    if tg_op = 'INSERT' and coalesce(new.data ->> 'status', 'submitted') <> 'submitted' then
      raise exception 'New requests start as submitted.' using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (new.data -> 'status') is distinct from (old.data -> 'status')
       and not (old.data ->> 'status' = 'submitted' and new.data ->> 'status' = 'withdrawn') then
      raise exception 'Only the company can decide a request.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists docs_portal_guard on public.docs;
create trigger docs_portal_guard before insert or update on public.docs for each row execute function public.docs_portal_guard();

-- Delegations: only the person delegating (or the owner) can create or change one.
-- Organogram: only the HR Manager, the CEO, the owner or the person they delegated to can approve it.
create or replace function public.docs_role_guard() returns trigger
language plpgsql set search_path = public as $$
declare ar text := my_app_role(new.org_id); was text;
begin
  if new.path like 'delegations/%' then
    if ar is distinct from 'owner' and ar is distinct from 'ceo' and coalesce(new.data ->> 'from_uid', '') <> coalesce(auth.uid()::text, '') then
      raise exception 'Only the person delegating, the CEO or the owner can set up a delegation.' using errcode = '42501';
    end if;
    new.data := new.data || jsonb_build_object('set_by', auth.uid());
  end if;
  if new.path like 'org_charts/%' then
    was := case when tg_op = 'UPDATE' then old.data ->> 'status' end;
    if new.data ->> 'status' = 'approved' and was is distinct from 'approved' then
      if not (ar in ('owner', 'ceo', 'hr_mgr') or coalesce(new.data ->> 'delegate_uid', '') = coalesce(auth.uid()::text, '')) then
        raise exception 'Only the HR Manager, the CEO, the admin or their delegate can approve the organogram.' using errcode = '42501';
      end if;
      new.data := new.data || jsonb_build_object('approved_by', auth.uid(), 'approved_at', now());
    end if;
    if (new.data -> 'delegate_uid') is distinct from (case when tg_op = 'UPDATE' then old.data -> 'delegate_uid' end)
       and ar not in ('owner', 'ceo') then
      raise exception 'Only the CEO or the admin can delegate the organogram approval.' using errcode = '42501';
    end if;
  end if;
  -- Policies and risk registers: only the CEO gives final approval (the admin when there is no CEO)
  if new.path like 'policies/%' and new.data ->> 'status' = 'approved'
     and (tg_op = 'INSERT' or old.data ->> 'status' is distinct from 'approved') then
    if not (ar = 'ceo' or (ar = 'owner' and not exists (select 1 from docs d where d.org_id = new.org_id and d.collection = 'setup/main/access' and d.data ->> 'role' = 'ceo'))) then
      raise exception 'Only the CEO can give the final approval of a policy.' using errcode = '42501';
    end if;
    new.data := new.data || jsonb_build_object('approved_by', auth.uid(), 'approved_at', now());
  end if;
  return new;
end $$;
drop trigger if exists docs_role_guard on public.docs;
create trigger docs_role_guard before insert or update on public.docs for each row execute function public.docs_role_guard();

-- ============================================================================
-- 7c. Saved signatures and email-code signing
--     A person's saved signature is only stored, and only released for signing,
--     by the server after they enter a one-time code sent to their sign-in email.
--     Each verified signing leaves an attestation (server time, document
--     fingerprint, signature fingerprint) that is used once.
-- ============================================================================
create table if not exists public.user_signatures (
  user_id    uuid primary key,
  image      text not null check (image like 'data:image/png;base64,%' and length(image) <= 400000),
  method     text,
  updated_at timestamptz not null default now()
);
create table if not exists public.sign_attestations (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs (id) on delete cascade,
  user_id     uuid not null,
  req         text not null,
  signer_key  text not null,
  doc_hash    text not null,
  image_sha   text not null,
  stamp       boolean not null default true,
  saved       boolean not null default false,
  verified_at timestamptz not null default now(),
  used_at     timestamptz
);
create table if not exists public.sign_code_log (
  user_id uuid not null,
  at      timestamptz not null default now(),
  ok      boolean not null
);
create index if not exists sign_code_log_user on public.sign_code_log (user_id, at);
alter table public.user_signatures enable row level security;
alter table public.sign_attestations enable row level security;
alter table public.sign_code_log enable row level security;
drop policy if exists usig_read on public.user_signatures;
create policy usig_read on public.user_signatures for select to authenticated using (user_id = auth.uid());
revoke all on public.user_signatures, public.sign_attestations, public.sign_code_log from anon, authenticated;
grant select on public.user_signatures to authenticated;

-- Server only: too many wrong codes in an hour locks signing for that hour
create or replace function public.sig_code_gate(p_user uuid) returns boolean
language sql security definer set search_path = public as $$
  select (select count(*) from sign_code_log where user_id = p_user and not ok and at > now() - interval '1 hour') < 5
$$;
create or replace function public.sig_code_result(p_user uuid, p_ok boolean) returns void
language sql security definer set search_path = public as $$
  insert into sign_code_log (user_id, ok) values (p_user, p_ok)
$$;

-- Server only: store the saved signature (after the code was verified)
create or replace function public.sig_save(p_user uuid, p_image text, p_method text) returns void
language sql security definer set search_path = public as $$
  insert into user_signatures (user_id, image, method, updated_at) values (p_user, p_image, left(p_method, 40), now())
  on conflict (user_id) do update set image = excluded.image, method = excluded.method, updated_at = now()
$$;
create or replace function public.sig_saved(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select image from user_signatures where user_id = p_user
$$;

-- Server only: record a verified signing for one signer of one request in one workspace
create or replace function public.sig_attest(p_user uuid, p_org uuid, p_req text, p_key text, p_doc_hash text,
  p_image_sha text, p_stamp boolean, p_saved boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; role text;
begin
  select m.role into role from members m where m.org_id = p_org and m.user_id = p_user and m.status = 'active' and (m.expires_at is null or m.expires_at > now());
  if role is null then raise exception 'Not a member of this workspace.' using errcode = '42501'; end if;
  if not org_writable(p_org) then raise exception 'This workspace is read-only.' using errcode = '42501'; end if;
  insert into sign_attestations (org_id, user_id, req, signer_key, doc_hash, image_sha, stamp, saved)
  values (p_org, p_user, left(p_req, 80), left(p_key, 80), left(p_doc_hash, 80), left(p_image_sha, 80), coalesce(p_stamp, true), coalesce(p_saved, false))
  returning * into r;
  return jsonb_build_object('id', r.id, 'verified_at', r.verified_at);
end $$;

-- Staff applying a signature: check the attestation matches and use it up
create or replace function public.sig_consume(p_org uuid, p_id uuid, p_user uuid, p_req text, p_key text, p_doc_hash text, p_image_sha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') and not (p_user = auth.uid() and my_role(p_org) is not null) then
    raise exception 'Not allowed.' using errcode = '42501';
  end if;
  select * into r from sign_attestations where id = p_id and org_id = p_org for update;
  if r.id is null then return jsonb_build_object('ok', false, 'why', 'email code was not verified'); end if;
  if r.used_at is not null then return jsonb_build_object('ok', false, 'why', 'this verification was already used'); end if;
  if r.verified_at < now() - interval '1 day' then return jsonb_build_object('ok', false, 'why', 'the verification expired'); end if;
  if r.user_id <> p_user or r.req <> p_req or r.signer_key <> p_key then return jsonb_build_object('ok', false, 'why', 'the verification belongs to someone else'); end if;
  if r.doc_hash <> p_doc_hash then return jsonb_build_object('ok', false, 'why', 'document fingerprint does not match the verification'); end if;
  if r.image_sha <> p_image_sha then return jsonb_build_object('ok', false, 'why', 'signature does not match the one verified'); end if;
  update sign_attestations set used_at = now() where id = p_id;
  return jsonb_build_object('ok', true, 'verified_at', r.verified_at, 'stamp', r.stamp, 'saved', r.saved);
end $$;

create or replace function public.sig_delete_mine() returns void
language sql security definer set search_path = public as $$
  delete from user_signatures where user_id = auth.uid()
$$;

-- ============================================================================
-- 7d. Sales: quotes customers open by link, outgoing email log, payment reminders
-- ============================================================================
-- Server only: the public view of a quote sent by link (token = 32+ random characters)
create or replace function public.quote_public(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record; ent jsonb;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select org_id, path, data into d from docs where collection = 'quotes' and data ->> 'public_token' = p_token limit 1;
  if d.path is null then return null; end if;
  select data into ent from docs where org_id = d.org_id and path = 'setup/main/entities/' || coalesce(nullif(d.data ->> 'entity', ''), 'main');
  return jsonb_build_object('id', split_part(d.path, '/', 2), 'quote', d.data - 'public_token' - 'history' - 'created_by' - 'internal_notes' - 'approved_by',
    'company', jsonb_build_object('name', ent ->> 'name', 'address', ent ->> 'address', 'email', ent ->> 'email', 'phone', ent ->> 'phone', 'trn', ent ->> 'trn', 'logo', ent #>> '{brand,logo}', 'color', ent #>> '{brand,color}'),
    'org_ok', exists (select 1 from orgs where id = d.org_id and status <> 'cancelled'));
end $$;

-- Server only: the customer accepts, asks for changes or declines through the link
create or replace function public.quote_public_answer(p_token text, p_action text, p_name text, p_comment text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record; st text; ev jsonb;
begin
  if p_action not in ('accept', 'changes', 'decline') then raise exception 'Unknown answer.'; end if;
  select id, org_id, data into d from docs where collection = 'quotes' and data ->> 'public_token' = p_token and length(p_token) >= 32 for update;
  if d.id is null then return jsonb_build_object('ok', false, 'why', 'This quote link is not valid.'); end if;
  if d.data ->> 'status' <> 'sent' then return jsonb_build_object('ok', false, 'why', 'This quote is no longer open: ' || coalesce(d.data ->> 'status', '')); end if;
  if coalesce(d.data ->> 'valid_until', '9999-12-31') < to_char(now(), 'YYYY-MM-DD') then return jsonb_build_object('ok', false, 'why', 'This quote has expired. Ask for a new one.'); end if;
  if not org_writable(d.org_id) then return jsonb_build_object('ok', false, 'why', 'The company cannot take answers right now.'); end if;
  if btrim(coalesce(p_name, '')) = '' then return jsonb_build_object('ok', false, 'why', 'Enter your name.'); end if;
  st := case p_action when 'accept' then 'accepted' when 'changes' then 'change_requested' else 'declined' end;
  ev := jsonb_build_object('at', now(), 'what', case p_action when 'accept' then 'Accepted by the customer (link)' when 'changes' then 'Customer asked for changes (link)' else 'Declined by the customer (link)' end,
                           'by_name', left(btrim(p_name), 120), 'comment', left(coalesce(p_comment, ''), 4000), 'via', 'link');
  update docs set data = data || jsonb_build_object('status', st, 'answered_at', now(), 'answered_by_name', left(btrim(p_name), 120), 'customer_comment', left(coalesce(p_comment, ''), 4000),
         'history', coalesce(data -> 'history', '[]'::jsonb) || jsonb_build_array(ev)) where id = d.id;
  return jsonb_build_object('ok', true, 'status', st);
end $$;

-- Outgoing email (quotes, agreements, reminders): a daily cap per workspace
create table if not exists public.email_log (
  id bigint generated always as identity primary key,
  org_id uuid not null references public.orgs (id) on delete cascade,
  user_id uuid,
  kind text,
  to_addr text,
  at timestamptz not null default now()
);
create index if not exists email_log_org on public.email_log (org_id, at);
alter table public.email_log enable row level security;
create or replace function public.email_gate(p_org uuid, p_user uuid, p_kind text, p_to text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_user is not null and not exists (select 1 from members where org_id = p_org and user_id = p_user and status = 'active' and (expires_at is null or expires_at > now()) and role in ('owner', 'staff')) then return false; end if;
  if (select count(*) from email_log where org_id = p_org and at > now() - interval '1 day') >= 300 then return false; end if;
  insert into email_log (org_id, user_id, kind, to_addr) values (p_org, p_user, left(p_kind, 40), left(p_to, 200));
  return true;
end $$;

-- ============================================================================
-- 7e. Purchasing: suppliers quote through a private link (RFQ invitations)
-- ============================================================================
create or replace function public.rfq_public(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record; inv jsonb; ent jsonb;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select org_id, path, data into d from docs where collection = 'rfqs' and data -> 'invites' @> jsonb_build_array(jsonb_build_object('token', p_token)) limit 1;
  if d.path is null then return null; end if;
  select x into inv from jsonb_array_elements(d.data -> 'invites') x where x ->> 'token' = p_token;
  select data into ent from docs where org_id = d.org_id and path = 'setup/main/entities/' || coalesce(nullif(d.data ->> 'entity', ''), 'main');
  return jsonb_build_object('rfq', jsonb_build_object('number', d.data ->> 'number', 'title', d.data ->> 'title', 'details', d.data ->> 'details', 'lines', d.data -> 'lines', 'due', d.data ->> 'due', 'status', d.data ->> 'status', 'currency', d.data ->> 'currency'),
    'invite', jsonb_build_object('supplier', inv ->> 'supplier', 'status', inv ->> 'status', 'quote', inv -> 'quote'),
    'company', jsonb_build_object('name', ent ->> 'name', 'address', ent ->> 'address', 'email', ent ->> 'email', 'logo', ent #>> '{brand,logo}'),
    'org_ok', exists (select 1 from orgs where id = d.org_id and status <> 'cancelled'));
end $$;
create or replace function public.rfq_public_submit(p_token text, p_quote jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d record; arr jsonb; i int;
begin
  select id, org_id, data into d from docs where collection = 'rfqs' and data -> 'invites' @> jsonb_build_array(jsonb_build_object('token', p_token)) and length(p_token) >= 32 for update;
  if d.id is null then return jsonb_build_object('ok', false, 'why', 'This link is not valid.'); end if;
  if d.data ->> 'status' <> 'open' then return jsonb_build_object('ok', false, 'why', 'This request for quotation is closed.'); end if;
  if coalesce(d.data ->> 'due', '9999-12-31') < to_char(now(), 'YYYY-MM-DD') then return jsonb_build_object('ok', false, 'why', 'The deadline for quotations has passed.'); end if;
  if not org_writable(d.org_id) then return jsonb_build_object('ok', false, 'why', 'The company cannot take quotations right now.'); end if;
  if octet_length(p_quote::text) > 700000 then return jsonb_build_object('ok', false, 'why', 'The attachment is too large (max about 500 KB).'); end if;
  arr := d.data -> 'invites';
  for i in 0 .. jsonb_array_length(arr) - 1 loop
    if arr -> i ->> 'token' = p_token then
      arr := jsonb_set(arr, array[i::text], (arr -> i) || jsonb_build_object('status', 'quoted', 'quote', p_quote || jsonb_build_object('submitted_at', now(), 'via', 'link')));
    end if;
  end loop;
  update docs set data = data || jsonb_build_object('invites', arr) where id = d.id;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================================
-- 7f. AML screening: official sanctions lists, refreshed daily by the server
-- ============================================================================
create extension if not exists pg_trgm;
create table if not exists public.sanctions_entries (
  id         bigint generated always as identity primary key,
  source     text not null,          -- un, ofac, uk, eu, uae
  ext_id     text,
  name       text not null,
  name_norm  text not null,
  kind       text,                   -- individual, entity, vessel…
  program    text,
  country    text,
  listed_on  text,
  extra      text
);
create index if not exists sanctions_name_trgm on public.sanctions_entries using gin (name_norm gin_trgm_ops);
create index if not exists sanctions_source on public.sanctions_entries (source);
create table if not exists public.sanctions_sources (
  source text primary key, title text, url text, fetched_at timestamptz, entries int, status text, note text
);
alter table public.sanctions_entries enable row level security;
alter table public.sanctions_sources enable row level security;
drop policy if exists sources_read on public.sanctions_sources;
create policy sources_read on public.sanctions_sources for select to authenticated using (true);
revoke all on public.sanctions_entries, public.sanctions_sources from anon, authenticated;
grant select on public.sanctions_sources to authenticated;

create or replace function public.aml_norm(t text) returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(lower(translate(coalesce(t, ''), 'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÇçÑñ', 'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
    '\m(llc|l\.l\.c|ltd|limited|co|company|inc|fze|fzco|fz|est|establishment|trading|group|holding|holdings|the|mr|mrs|ms|dr|al|el|bin|ibn|abu)\M|[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;
-- Team members screen names against the lists (the lists are public; only scores and matches are returned)
create or replace function public.aml_screen(p_org uuid, p_names text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; n text; nn text; m jsonb;
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff', 'viewer') then raise exception 'Not allowed.' using errcode = '42501'; end if;
  if array_length(p_names, 1) > 200 then raise exception 'Screen at most 200 names at a time.'; end if;
  foreach n in array p_names loop
    nn := aml_norm(n);
    if length(nn) < 3 then out := out || jsonb_build_array(jsonb_build_object('name', n, 'matches', '[]'::jsonb)); continue; end if;
    select coalesce(jsonb_agg(x order by (x ->> 'score')::numeric desc), '[]'::jsonb) into m from (
      select jsonb_build_object('source', source, 'name', name, 'kind', kind, 'program', program, 'country', country, 'listed_on', listed_on, 'ext_id', ext_id,
             'score', round(greatest(similarity(name_norm, nn), word_similarity(nn, name_norm))::numeric, 2)) x
        from sanctions_entries where name_norm % nn or nn <% name_norm
        order by greatest(similarity(name_norm, nn), word_similarity(nn, name_norm)) desc limit 5) s
      where (x ->> 'score')::numeric >= 0.55;
    out := out || jsonb_build_array(jsonb_build_object('name', n, 'matches', m));
  end loop;
  return out;
end $$;

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
-- 7g. Clinic donor dashboards (public, read-only, expiring) and custom domains
-- ============================================================================
-- Server only: the public view of a donor dashboard link. Returns only the summary the
-- clinic published (no patient names), and nothing once the link is revoked or expired.
create or replace function public.donor_public(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record; ent jsonb;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select org_id, path, data into d from docs where path like 'donor_links/%' and data ->> 'token' = p_token limit 1;
  if d.path is null then return null; end if;
  if coalesce((d.data ->> 'revoked')::boolean, false) or coalesce((d.data ->> 'expires_at')::timestamptz, now() - interval '1 second') < now() then
    return jsonb_build_object('expired', true, 'org_ok', true);
  end if;
  select data into ent from docs where org_id = d.org_id and path = 'setup/main/entities/' || coalesce(nullif(d.data ->> 'entity', ''), 'main');
  return jsonb_build_object('summary', coalesce(d.data -> 'snapshot', '{}'::jsonb), 'title', d.data ->> 'title', 'message', d.data ->> 'message', 'expires_at', d.data ->> 'expires_at',
    'company', jsonb_build_object('name', ent ->> 'name', 'address', ent ->> 'address', 'phone', ent ->> 'phone', 'email', ent ->> 'email', 'logo', ent #>> '{brand,logo}', 'color', ent #>> '{brand,color}', 'currency', ent ->> 'currency'),
    'org_ok', exists (select 1 from orgs where id = d.org_id and status <> 'cancelled'));
end $$;

-- Custom domains: a workspace owner can serve Orzio on their own address (for example app.myclinic.org).
-- Rows are written only by the server (/api/domain) after checking the caller is an owner.
create table if not exists public.org_domains (
  domain      text primary key check (domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  org_id      uuid not null references public.orgs (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'verified', 'error')),
  detail      jsonb not null default '{}'::jsonb,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  verified_at timestamptz
);
alter table public.org_domains enable row level security;
drop policy if exists org_domains_read on public.org_domains;
create policy org_domains_read on public.org_domains for select to authenticated using (my_role(org_id) in ('owner', 'staff'));
revoke insert, update, delete, truncate on public.org_domains from anon, authenticated;
grant select on public.org_domains to authenticated;

-- Server only: which workspace a verified domain belongs to, with its public branding
create or replace function public.domain_lookup(p_host text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('org_id', d.org_id, 'name', coalesce(e.data ->> 'name', o.name), 'logo', e.data #>> '{brand,logo}', 'color', e.data #>> '{brand,color}')
    from org_domains d join orgs o on o.id = d.org_id and o.status <> 'cancelled'
    left join docs e on e.org_id = d.org_id and e.path = 'setup/main/entities/main'
   where d.domain = lower(p_host) and d.status = 'verified' limit 1
$$;

-- Clinic: public appointment requests (no login). The front desk confirms them.
create or replace function public.booking_public(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e record;
begin
  if p_token is null or length(p_token) < 24 then return null; end if;
  select org_id, path, data into e from docs where path like 'setup/main/entities/%' and data #>> '{clinic,booking_token}' = p_token
     and coalesce((data #>> '{clinic,booking_on}')::boolean, false) limit 1;
  if e.path is null then return null; end if;
  return jsonb_build_object('company', jsonb_build_object('name', e.data ->> 'name', 'phone', e.data ->> 'phone', 'address', e.data ->> 'address', 'logo', e.data #>> '{brand,logo}'),
    'doctors', coalesce((select jsonb_agg(jsonb_build_object('id', d ->> 'id', 'name', d ->> 'name', 'specialty', d ->> 'specialty', 'days', d -> 'days', 'start', d ->> 'start', 'end', d ->> 'end'))
       from jsonb_array_elements(coalesce(e.data #> '{clinic,doctors}', '[]'::jsonb)) d where coalesce((d ->> 'online')::boolean, true)), '[]'::jsonb),
    'org_ok', exists (select 1 from orgs where id = e.org_id and status <> 'cancelled'));
end $$;
create or replace function public.booking_public_request(p_token text, p_name text, p_phone text, p_doctor text, p_date date, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e record; ent text; n int; id text;
begin
  select org_id, path, data into e from docs where path like 'setup/main/entities/%' and data #>> '{clinic,booking_token}' = p_token
     and coalesce((data #>> '{clinic,booking_on}')::boolean, false) limit 1;
  if e.path is null then return jsonb_build_object('ok', false, 'why', 'Online booking is not available.'); end if;
  if length(btrim(coalesce(p_name, ''))) < 2 or length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 7 then return jsonb_build_object('ok', false, 'why', 'Enter your name and phone number.'); end if;
  if p_date is null or p_date < current_date or p_date > current_date + 60 then return jsonb_build_object('ok', false, 'why', 'Choose a date in the next 60 days.'); end if;
  ent := split_part(e.path, '/', 4);
  select count(*) into n from docs where org_id = e.org_id and path like 'appointments/%' and data ->> 'source' = 'online' and (data ->> 'created_at')::timestamptz > now() - interval '1 hour';
  if n >= 40 then return jsonb_build_object('ok', false, 'why', 'Too many requests just now. Please call the clinic.'); end if;
  select count(*) into n from docs where org_id = e.org_id and path like 'appointments/%' and data ->> 'source' = 'online' and data ->> 'phone_digits' = right(regexp_replace(p_phone, '\D', '', 'g'), 9) and data ->> 'date' = p_date::text;
  if n >= 2 then return jsonb_build_object('ok', false, 'why', 'You already asked for an appointment on that day.'); end if;
  id := ent || '-a' || replace(gen_random_uuid()::text, '-', '');
  insert into docs (org_id, path, collection, scope, data) values (e.org_id, 'appointments/' || id, 'appointments', '',
    jsonb_build_object('entity', ent, 'patient_name', left(btrim(p_name), 120), 'phone', left(btrim(p_phone), 30), 'phone_digits', right(regexp_replace(p_phone, '\D', '', 'g'), 9),
      'doctor_id', left(coalesce(p_doctor, ''), 40), 'date', p_date::text, 'time', '', 'reason', left(coalesce(p_note, ''), 500), 'status', 'requested', 'source', 'online', 'created_at', now()));
  return jsonb_build_object('ok', true, 'clinic', e.data ->> 'name');
end $$;
-- Clinic: a patient opens their prescription or lab report from a link that expires
create or replace function public.share_public(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d record;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select org_id, path, data into d from docs where path like 'share_links/%' and data ->> 'token' = p_token limit 1;
  if d.path is null then return null; end if;
  if coalesce((d.data ->> 'revoked')::boolean, false) or coalesce((d.data ->> 'expires_at')::timestamptz, now() - interval '1 second') < now() then
    return jsonb_build_object('expired', true, 'org_ok', true);
  end if;
  return jsonb_build_object('kind', d.data ->> 'kind', 'doc', d.data -> 'snapshot', 'expires_at', d.data ->> 'expires_at',
    'org_ok', exists (select 1 from orgs where id = d.org_id and status <> 'cancelled'));
end $$;

-- ============================================================================
-- 7h. E-commerce: online stores read live stock and place orders without a login
--     (through /api/store). Connector secrets (Shopify, WooCommerce) stay on the server.
-- ============================================================================
create table if not exists public.store_secrets (
  store_id   text primary key,
  org_id     uuid not null references public.orgs (id) on delete cascade,
  data       jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.store_secrets enable row level security;  -- no policies: server only

create or replace function public.store_find(p_key text) returns table (org_id uuid, store_id text, data jsonb)
language sql stable security definer set search_path = public as $$
  select d.org_id, split_part(d.path, '/', 2), d.data from docs d join orgs o on o.id = d.org_id and o.status <> 'cancelled'
   where p_key is not null and length(p_key) >= 24 and d.collection = 'stores' and d.data ->> 'key' = p_key and coalesce((d.data ->> 'active')::boolean, true)
   limit 1 $$;

-- available stock of one item in the store's warehouses (all warehouses when none are chosen)
create or replace function public.store_avail(p_org uuid, p_item text, p_whs text[]) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum((m.data ->> 'qty')::numeric), 0) from docs m
   where m.org_id = p_org and m.collection = 'stock_moves' and m.data ->> 'item_id' = p_item
     and (p_whs is null or cardinality(p_whs) = 0 or coalesce(m.data ->> 'wh', 'main') = any (p_whs)) $$;

create or replace function public.store_catalog(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f record; ent text; whs text[]; e jsonb;
begin
  select * into f from store_find(p_key);
  if f.org_id is null then return null; end if;
  ent := coalesce(f.data ->> 'entity', 'main');
  select array_agg(x) into whs from jsonb_array_elements_text(coalesce(f.data -> 'warehouses', '[]'::jsonb)) x;
  select data into e from docs where org_id = f.org_id and path = 'setup/main/entities/' || ent;
  return jsonb_build_object('store', f.data ->> 'name', 'company', e ->> 'name', 'currency', coalesce(e ->> 'currency', 'AED'),
    'shipping', coalesce(f.data -> 'shipping', '{}'::jsonb), 'payments', coalesce(f.data -> 'payments', '["cod"]'::jsonb), 'updated_at', now(),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', split_part(i.path, '/', 2), 'sku', i.data ->> 'sku', 'name', coalesce(nullif(i.data ->> 'web_name', ''), i.data ->> 'name'),
        'price', round(coalesce(nullif(i.data ->> 'web_price', '')::numeric, (i.data ->> 'price')::numeric, 0) * (1 + coalesce(nullif(f.data ->> 'price_pct', '')::numeric, 0) / 100), 2),
        'compare_at', nullif(i.data ->> 'compare_at', '')::numeric, 'image', i.data ->> 'image', 'description', i.data ->> 'web_desc',
        'category', i.data ->> 'category', 'weight', nullif(i.data ->> 'weight', '')::numeric,
        'available', greatest(0, floor(store_avail(f.org_id, split_part(i.path, '/', 2), whs) - coalesce(nullif(i.data ->> 'safety_stock', '')::numeric, 0))))
        order by i.data ->> 'name')
      from docs i where i.org_id = f.org_id and i.collection = 'inv_items' and coalesce(i.data ->> 'entity', 'main') = ent
       and coalesce((i.data ->> 'web')::boolean, false) and coalesce((i.data ->> 'active')::boolean, true)), '[]'::jsonb));
end $$;

-- an order from the website (or imported from Shopify / WooCommerce): checks stock, takes prices from the books,
-- reserves stock at once (so every website shows the new quantity) and records the order for the team to fulfil
create or replace function public.store_place_order(p_key text, p_order jsonb, p_source text default 'web', p_ext_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f record; ent text; whs text[]; ln jsonb; it record; q numeric; av numeric; price numeric; sub numeric := 0; lines jsonb := '[]'::jsonb;
  ship numeric := 0; sh jsonb; num text; oid text; n int; cost numeric; wh text; cust jsonb; pay text; i int := 0; cur text;
begin
  select * into f from store_find(p_key);
  if f.org_id is null then return jsonb_build_object('ok', false, 'why', 'This shop is not available.'); end if;
  if not org_writable(f.org_id) then return jsonb_build_object('ok', false, 'why', 'This shop is not taking orders right now.'); end if;
  ent := coalesce(f.data ->> 'entity', 'main');
  select array_agg(x) into whs from jsonb_array_elements_text(coalesce(f.data -> 'warehouses', '[]'::jsonb)) x;
  cust := coalesce(p_order -> 'customer', '{}'::jsonb);
  if p_source = 'web' then
    if length(btrim(coalesce(cust ->> 'name', ''))) < 2 or length(regexp_replace(coalesce(cust ->> 'phone', ''), '\D', '', 'g')) < 7 then
      return jsonb_build_object('ok', false, 'why', 'Enter your name and phone number.'); end if;
    if length(btrim(coalesce(cust ->> 'address', ''))) < 5 then return jsonb_build_object('ok', false, 'why', 'Enter the delivery address.'); end if;
    select count(*) into n from docs where org_id = f.org_id and collection = 'web_orders' and data ->> 'store' = f.store_id and (data ->> 'created_at')::timestamptz > now() - interval '10 minutes';
    if n >= 60 then return jsonb_build_object('ok', false, 'why', 'The shop is busy. Please try again in a few minutes.'); end if;
    select count(*) into n from docs where org_id = f.org_id and collection = 'web_orders' and data -> 'customer' ->> 'phone_digits' = right(regexp_replace(cust ->> 'phone', '\D', '', 'g'), 9)
       and (data ->> 'created_at')::timestamptz > now() - interval '1 minute';
    if n > 0 then return jsonb_build_object('ok', false, 'why', 'Your order was just received. Please wait a minute before ordering again.'); end if;
  end if;
  if p_ext_id is not null and exists (select 1 from docs where org_id = f.org_id and collection = 'web_orders' and data ->> 'ext_id' = p_ext_id and data ->> 'source' = p_source) then
    return jsonb_build_object('ok', true, 'duplicate', true); end if;
  if jsonb_typeof(p_order -> 'lines') <> 'array' or jsonb_array_length(p_order -> 'lines') = 0 or jsonb_array_length(p_order -> 'lines') > 50 then
    return jsonb_build_object('ok', false, 'why', 'Your cart is empty.'); end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || f.org_id::text));
  for ln in select * from jsonb_array_elements(p_order -> 'lines') loop
    q := floor(coalesce((ln ->> 'qty')::numeric, 0));
    if q <= 0 or q > 999 then return jsonb_build_object('ok', false, 'why', 'Check the quantities in your cart.'); end if;
    select split_part(d.path, '/', 2) id, d.data into it from docs d where d.org_id = f.org_id and d.collection = 'inv_items' and coalesce(d.data ->> 'entity', 'main') = ent
       and coalesce((d.data ->> 'active')::boolean, true) and (split_part(d.path, '/', 2) = ln ->> 'id' or (p_source <> 'web' and d.data ->> 'sku' = ln ->> 'sku' and coalesce(ln ->> 'sku', '') <> ''))
       and (p_source <> 'web' or coalesce((d.data ->> 'web')::boolean, false)) limit 1;
    if it.id is null then
      if p_source = 'web' then return jsonb_build_object('ok', false, 'why', 'An item in your cart is no longer sold.'); end if;
      lines := lines || jsonb_build_object('item_id', null, 'sku', ln ->> 'sku', 'name', coalesce(ln ->> 'name', ln ->> 'sku'), 'qty', q, 'price', coalesce((ln ->> 'price')::numeric, 0), 'cost', 0, 'unmatched', true);
      sub := sub + q * coalesce((ln ->> 'price')::numeric, 0); continue;
    end if;
    av := store_avail(f.org_id, it.id, whs);
    if p_source = 'web' and q > av - coalesce(nullif(it.data ->> 'safety_stock', '')::numeric, 0) then
      return jsonb_build_object('ok', false, 'why', format('Only %s left of %s.', greatest(0, floor(av - coalesce(nullif(it.data ->> 'safety_stock', '')::numeric, 0))), it.data ->> 'name'), 'item', it.id); end if;
    price := case when p_source = 'web' then round(coalesce(nullif(it.data ->> 'web_price', '')::numeric, (it.data ->> 'price')::numeric, 0) * (1 + coalesce(nullif(f.data ->> 'price_pct', '')::numeric, 0) / 100), 2) else coalesce((ln ->> 'price')::numeric, 0) end;
    select case when sum((m.data ->> 'qty')::numeric) > 0 then sum((m.data ->> 'value')::numeric) / sum((m.data ->> 'qty')::numeric) else coalesce((it.data ->> 'cost')::numeric, 0) end
      into cost from docs m where m.org_id = f.org_id and m.collection = 'stock_moves' and m.data ->> 'item_id' = it.id;
    -- the store's warehouse with the most stock of this item
    select w into wh from (select coalesce(m.data ->> 'wh', 'main') w, sum((m.data ->> 'qty')::numeric) s from docs m
      where m.org_id = f.org_id and m.collection = 'stock_moves' and m.data ->> 'item_id' = it.id and (whs is null or coalesce(m.data ->> 'wh', 'main') = any (whs)) group by 1 order by 2 desc limit 1) x;
    lines := lines || jsonb_build_object('item_id', it.id, 'sku', it.data ->> 'sku', 'name', it.data ->> 'name', 'qty', q, 'price', price, 'cost', round(coalesce(cost, 0), 4), 'wh', coalesce(wh, whs[1], 'main'));
    sub := sub + q * price;
  end loop;
  sh := coalesce(f.data -> 'shipping', '{}'::jsonb);
  ship := case when p_source <> 'web' then coalesce((p_order ->> 'shipping')::numeric, 0)
               when coalesce((sh ->> 'free_over')::numeric, 0) > 0 and sub >= (sh ->> 'free_over')::numeric then 0
               else coalesce((sh -> 'by_country' ->> upper(coalesce(cust ->> 'country', ''))) ::numeric, (sh ->> 'flat')::numeric, 0) end;
  pay := case when p_source <> 'web' then coalesce(p_order ->> 'payment', 'paid') when p_order ->> 'payment' in ('cod', 'bank', 'card') then p_order ->> 'payment' else 'cod' end;
  select data ->> 'currency' into cur from docs where org_id = f.org_id and path = 'setup/main/entities/' || ent;
  select count(*) + 1 into n from docs where org_id = f.org_id and collection = 'web_orders' and data ->> 'number' like 'WEB-' || to_char(now(), 'YYYY') || '-%';
  num := 'WEB-' || to_char(now(), 'YYYY') || '-' || lpad(n::text, 5, '0');
  oid := ent || '-w' || replace(gen_random_uuid()::text, '-', '');
  insert into docs (org_id, path, collection, scope, data) values (f.org_id, 'web_orders/' || oid, 'web_orders', '', jsonb_build_object(
    'entity', ent, 'store', f.store_id, 'store_name', f.data ->> 'name', 'number', num, 'source', p_source, 'ext_id', p_ext_id, 'status', 'new',
    'payment', pay, 'payment_status', case when pay in ('paid', 'card') and p_source <> 'web' then 'paid' else 'unpaid' end,
    'lines', lines, 'subtotal', round(sub, 2), 'shipping_fee', round(ship, 2), 'total', round(sub + ship, 2), 'currency', coalesce(cur, 'AED'),
    'customer', jsonb_build_object('name', left(btrim(coalesce(cust ->> 'name', '')), 120), 'phone', left(coalesce(cust ->> 'phone', ''), 40),
       'phone_digits', right(regexp_replace(coalesce(cust ->> 'phone', ''), '\D', '', 'g'), 9), 'email', left(coalesce(cust ->> 'email', ''), 160),
       'address', left(coalesce(cust ->> 'address', ''), 400), 'city', left(coalesce(cust ->> 'city', ''), 80), 'country', upper(left(coalesce(cust ->> 'country', ''), 2))),
    'note', left(coalesce(p_order ->> 'note', ''), 500), 'created_at', now()));
  -- reserve the stock straight away
  for ln in select * from jsonb_array_elements(lines) loop
    i := i + 1;
    if ln ->> 'item_id' is null then continue; end if;
    insert into docs (org_id, path, collection, scope, data) values (f.org_id, 'stock_moves/' || oid || '-' || i, 'stock_moves', '', jsonb_build_object(
      'entity', ent, 'item_id', ln ->> 'item_id', 'date', current_date::text, 'qty', -(ln ->> 'qty')::numeric, 'unit_cost', (ln ->> 'cost')::numeric,
      'value', round(-(ln ->> 'qty')::numeric * (ln ->> 'cost')::numeric, 2), 'type', 'web_order', 'wh', ln ->> 'wh', 'ref', num, 'order_id', oid, 'by', 'web', 'at', now(), 'posted', false));
  end loop;
  return jsonb_build_object('ok', true, 'number', num, 'total', round(sub + ship, 2), 'currency', coalesce(cur, 'AED'), 'order', oid);
end $$;

-- customers follow their order: number plus the last 4 digits of the phone they ordered with
create or replace function public.store_track(p_key text, p_number text, p_phone4 text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f record; o jsonb;
begin
  select * into f from store_find(p_key);
  if f.org_id is null or coalesce(p_number, '') = '' or coalesce(length(regexp_replace(p_phone4, '\D', '', 'g')), 0) < 4 then return null; end if;
  select data into o from docs where org_id = f.org_id and collection = 'web_orders' and upper(data ->> 'number') = upper(btrim(p_number))
     and right(data -> 'customer' ->> 'phone_digits', 4) = right(regexp_replace(p_phone4, '\D', '', 'g'), 4) limit 1;
  if o is null then return null; end if;
  return jsonb_build_object('number', o ->> 'number', 'status', o ->> 'status', 'store', f.data ->> 'name', 'placed', o ->> 'created_at', 'total', o -> 'total', 'currency', o ->> 'currency',
    'items', (select jsonb_agg(jsonb_build_object('name', l ->> 'name', 'qty', l -> 'qty')) from jsonb_array_elements(o -> 'lines') l),
    'carrier', o -> 'shipment' ->> 'carrier_name', 'tracking', o -> 'shipment' ->> 'awb', 'tracking_url', o -> 'shipment' ->> 'tracking_url', 'history', coalesce(o -> 'history', '[]'::jsonb));
end $$;

-- ============================================================================
-- 7i. Help desk: customers' IT teams escalate to the Orzio team (platform admins).
--     Kept outside the workspace data, so platform admins never need access to a customer's books.
-- ============================================================================
create table if not exists public.support_tickets (
  id         bigint generated always as identity primary key,
  org_id     uuid not null references public.orgs (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  subject    text not null check (length(subject) between 3 and 200),
  body       text not null check (length(body) between 1 and 8000),
  priority   text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  category   text,
  app_ref    text,
  status     text not null default 'open' check (status in ('open', 'in_progress', 'waiting', 'resolved', 'closed')),
  messages   jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.support_tickets enable row level security;  -- reached only through the functions below
create index if not exists support_tickets_org on public.support_tickets (org_id, created_at desc);

create or replace function public.support_open(p_org uuid, p_subject text, p_body text, p_priority text default 'normal', p_category text default null, p_ref text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare n int; id_ bigint;
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') then raise exception 'Only team members can contact Orzio support.' using errcode = '42501'; end if;
  select count(*) into n from support_tickets where org_id = p_org and created_at > now() - interval '1 day';
  if n >= 30 then raise exception 'Too many tickets today. Add to an open ticket instead.' using errcode = 'P0001'; end if;
  insert into support_tickets (org_id, created_by, subject, body, priority, category, app_ref)
  values (p_org, auth.uid(), left(btrim(p_subject), 200), left(p_body, 8000), case when p_priority in ('low', 'normal', 'high', 'urgent') then p_priority else 'normal' end, left(p_category, 60), left(p_ref, 120))
  returning id into id_;
  return id_;
end $$;

create or replace function public.support_mine(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(to_jsonb(t) - 'org_id' order by t.created_at desc) from support_tickets t where t.org_id = p_org), '[]'::jsonb);
end $$;

create or replace function public.support_reply(p_id bigint, p_text text, p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t support_tickets; adm boolean := is_platform_admin(); nm text;
begin
  select * into t from support_tickets where id = p_id;
  if t.id is null then raise exception 'Ticket not found.' using errcode = 'P0002'; end if;
  if not adm and coalesce(my_role(t.org_id), '') not in ('owner', 'staff') then raise exception 'Ticket not found.' using errcode = 'P0002'; end if;
  if p_status is not null and p_status not in ('open', 'in_progress', 'waiting', 'resolved', 'closed') then raise exception 'Unknown status.'; end if;
  if not adm and p_status not in ('open', 'closed') then p_status := null; end if;
  select coalesce(full_name, email) into nm from profiles where id = auth.uid();
  update support_tickets set
    messages = case when coalesce(btrim(p_text), '') = '' then messages else messages || jsonb_build_object('at', now(), 'by', case when adm then 'Orzio support' else coalesce(nm, 'Customer') end, 'from', case when adm then 'support' else 'customer' end, 'text', left(p_text, 8000)) end,
    status = coalesce(p_status, case when adm then (case when status = 'open' then 'in_progress' else status end) else (case when status in ('waiting', 'resolved') then 'open' else status end) end),
    updated_at = now()
  where id = p_id returning * into t;
  return to_jsonb(t) - 'org_id';
end $$;

create or replace function public.admin_tickets() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object('org_name', o.name, 'by_email', p.email) order by (t.status in ('resolved', 'closed')), t.updated_at desc)
    from support_tickets t join orgs o on o.id = t.org_id left join profiles p on p.id = t.created_by), '[]'::jsonb);
end $$;

-- ============================================================================
-- 7j. Industry packs: prepared once per industry and country by Orzio's agents,
--     approved and published by a platform admin, then offered to every customer
--     in that industry and country (each customer's admin approves before applying).
-- ============================================================================
create table if not exists public.industry_packs (
  id           uuid primary key default gen_random_uuid(),
  industry     text not null check (industry ~ '^[a-z_]{2,30}$'),
  country      text not null check (country ~ '^([A-Z]{2}|\*)$'),
  version      int  not null default 1,
  status       text not null default 'draft' check (status in ('draft', 'review', 'published', 'retired', 'rejected')),
  content      jsonb not null default '{}',
  sections     jsonb not null default '{}',
  notes        text,
  generated_by text,
  created_by   uuid references auth.users (id) on delete set null,
  approved_by  uuid references auth.users (id) on delete set null,
  approved_at  timestamptz,
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (industry, country, version)
);
alter table public.industry_packs enable row level security;  -- reached only through the functions below
create index if not exists industry_packs_pub on public.industry_packs (industry, country, status, version desc);
create table if not exists public.industry_pack_requests (
  industry   text not null,
  country    text not null,
  orgs       uuid[] not null default '{}',
  requests   int not null default 1,
  last_at    timestamptz not null default now(),
  primary key (industry, country)
);
alter table public.industry_pack_requests enable row level security;

-- customers: the latest published pack for their industry and country (falls back to the all-countries pack)
create or replace function public.pack_get(p_org uuid, p_industry text, p_country text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r industry_packs;
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') and not is_platform_admin() then return null; end if;
  select * into r from industry_packs where industry = p_industry and status = 'published' and country in (upper(p_country), '*')
   order by (country = upper(p_country)) desc, version desc limit 1;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'industry', r.industry, 'country', r.country, 'version', r.version, 'content', r.content, 'published_at', r.published_at);
end $$;

-- countries with a published pack (adds them to the sign-up list with their tax defaults)
create or replace function public.pack_countries(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') and not is_platform_admin() then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select distinct on (country) jsonb_build_object('country', country, 'name', content->'profile'->>'country_name', 'currency', content->'profile'->>'currency',
      'vat', content->'profile'->'vat', 'ct', content->'profile'->'ct', 'thr', content->'profile'->'thr', 'note', content->'profile'->>'note', 'banks', content->'profile'->'banks') as x
    from industry_packs where status = 'published' and country <> '*' order by country, published_at desc) q), '[]'::jsonb);
end $$;

-- customers ask for a pack that does not exist yet
create or replace function public.pack_request(p_org uuid, p_industry text, p_country text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(p_org), '') not in ('owner', 'staff') then return; end if;
  if p_industry !~ '^[a-z_]{2,30}$' or upper(p_country) !~ '^[A-Z]{2}$' then return; end if;
  insert into industry_pack_requests (industry, country, orgs) values (p_industry, upper(p_country), array[p_org])
  on conflict (industry, country) do update set
    orgs = case when p_org = any(industry_pack_requests.orgs) then industry_pack_requests.orgs else (industry_pack_requests.orgs || p_org)[1:500] end,
    requests = industry_pack_requests.requests + 1, last_at = now();
end $$;

-- platform admins: list, save drafts, approve and publish
create or replace function public.admin_packs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return jsonb_build_object(
    'packs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'industry', industry, 'country', country, 'version', version, 'status', status, 'sections', sections, 'notes', notes,
        'generated_by', generated_by, 'approved_at', approved_at, 'published_at', published_at, 'updated_at', updated_at,
        'size', length(content::text), 'counts', jsonb_build_object('accounts', jsonb_array_length(coalesce(content->'accounts'->'add', '[]')), 'laws', jsonb_array_length(coalesce(content->'laws'->'laws', '[]')),
          'templates', jsonb_array_length(coalesce(content->'templates', '[]')), 'faqs', jsonb_array_length(coalesce(content->'faqs', '[]'))),
        'in_use', (select count(*) from docs d where d.collection = 'pack_applied' and d.data->>'pack_id' = p.id::text))
      order by industry, country, version desc) from industry_packs p), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('industry', industry, 'country', country, 'orgs', cardinality(orgs), 'requests', requests, 'last_at', last_at) order by last_at desc) from industry_pack_requests), '[]'::jsonb));
end $$;

create or replace function public.admin_pack_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return (select to_jsonb(p) from industry_packs p where id = p_id);
end $$;

create or replace function public.admin_pack_save(p_id uuid, p_industry text, p_country text, p_content jsonb, p_sections jsonb, p_notes text, p_generated_by text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r industry_packs; v int; id_ uuid;
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  if length(p_content::text) > 3000000 then raise exception 'The pack is too large (3 MB at most).'; end if;
  if p_id is null then
    select coalesce(max(version), 0) + 1 into v from industry_packs where industry = p_industry and country = upper(p_country);
    insert into industry_packs (industry, country, version, content, sections, notes, generated_by, created_by)
    values (p_industry, case when p_country = '*' then '*' else upper(p_country) end, v, coalesce(p_content, '{}'), coalesce(p_sections, '{}'), p_notes, p_generated_by, auth.uid()) returning id into id_;
    return id_;
  end if;
  select * into r from industry_packs where id = p_id for update;
  if r.id is null then raise exception 'Pack not found.'; end if;
  if r.status in ('published', 'retired') then raise exception 'A published pack cannot be changed. Start a new version.'; end if;
  update industry_packs set content = coalesce(p_content, content), sections = coalesce(p_sections, sections), notes = coalesce(p_notes, notes),
    generated_by = coalesce(p_generated_by, generated_by), status = case when status = 'rejected' then 'draft' else status end, updated_at = now() where id = p_id;
  return p_id;
end $$;

create or replace function public.admin_pack_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r industry_packs;
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  if p_status not in ('draft', 'review', 'published', 'rejected', 'retired') then raise exception 'Unknown status.'; end if;
  select * into r from industry_packs where id = p_id for update;
  if r.id is null then raise exception 'Pack not found.'; end if;
  if p_status = 'published' then
    if exists (select 1 from jsonb_each_text(r.sections) s where s.value <> 'approved') or r.sections = '{}'::jsonb then
      raise exception 'Approve every section before publishing.' using errcode = 'P0001'; end if;
    update industry_packs set status = 'retired', updated_at = now() where industry = r.industry and country = r.country and status = 'published' and id <> r.id;
    update industry_packs set status = 'published', approved_by = auth.uid(), approved_at = now(), published_at = now(), updated_at = now() where id = p_id;
  else
    update industry_packs set status = p_status, updated_at = now() where id = p_id;
  end if;
  return (select jsonb_build_object('id', id, 'status', status, 'version', version) from industry_packs where id = p_id);
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
revoke execute on function public.att_context(uuid)                       from public, anon, authenticated;
revoke execute on function public.rfq_public(text), public.rfq_public_submit(text, jsonb) from public, anon, authenticated;
grant  execute on function public.rfq_public(text), public.rfq_public_submit(text, jsonb) to service_role;
revoke execute on function public.quote_public(text)                      from public, anon, authenticated;
revoke execute on function public.quote_public_answer(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.email_gate(uuid, uuid, text, text)      from public, anon, authenticated;
grant  execute on function public.quote_public(text), public.quote_public_answer(text, text, text, text), public.email_gate(uuid, uuid, text, text) to service_role;
revoke execute on function public.donor_public(text) from public, anon, authenticated;
revoke execute on function public.domain_lookup(text) from public, anon, authenticated;
grant  execute on function public.donor_public(text), public.domain_lookup(text) to service_role;
revoke execute on function public.booking_public(text), public.booking_public_request(text, text, text, text, date, text), public.share_public(text) from public, anon, authenticated;
grant  execute on function public.booking_public(text), public.booking_public_request(text, text, text, text, date, text), public.share_public(text) to service_role;
revoke execute on function public.store_find(text), public.store_avail(uuid, text, text[]), public.store_catalog(text), public.store_track(text, text, text), public.store_place_order(text, jsonb, text, text) from public, anon, authenticated;
grant  execute on function public.store_find(text), public.store_avail(uuid, text, text[]), public.store_catalog(text), public.store_track(text, text, text), public.store_place_order(text, jsonb, text, text) to service_role;
grant  execute on function public.support_open(uuid, text, text, text, text, text), public.support_mine(uuid), public.support_reply(bigint, text, text), public.admin_tickets() to authenticated;
revoke execute on function public.sig_code_gate(uuid)                     from public, anon, authenticated;
revoke execute on function public.sig_code_result(uuid, boolean)          from public, anon, authenticated;
revoke execute on function public.sig_save(uuid, text, text)              from public, anon, authenticated;
revoke execute on function public.sig_saved(uuid)                         from public, anon, authenticated;
revoke execute on function public.sig_attest(uuid, uuid, text, text, text, text, boolean, boolean) from public, anon, authenticated;
grant  execute on function public.sig_code_gate(uuid), public.sig_code_result(uuid, boolean), public.sig_save(uuid, text, text),
       public.sig_saved(uuid), public.sig_attest(uuid, uuid, text, text, text, text, boolean, boolean) to service_role;
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
revoke all on public.email_log from anon, authenticated;
revoke all on public.sanctions_entries from anon, authenticated;
revoke all on public.ai_log, public.platform_config, public.platform_admins,
              public.org_counters, public.lookup_log, public.sign_attestations, public.sign_code_log, public.email_log from anon, authenticated;

grant  execute on function public.pack_get(uuid, text, text), public.pack_countries(uuid), public.pack_request(uuid, text, text),
       public.admin_packs(), public.admin_pack_get(uuid), public.admin_pack_save(uuid, text, text, jsonb, jsonb, text, text), public.admin_pack_status(uuid, text) to authenticated;
revoke all on public.industry_packs, public.industry_pack_requests from anon, authenticated;

-- Recompute record counters (safe to re-run)
insert into public.org_counters (org_id, docs, bytes)
select org_id, count(*), coalesce(sum(public.doc_bytes(path, data)), 0) from public.docs group by org_id
on conflict (org_id) do update set docs = excluded.docs, bytes = excluded.bytes;

-- ============================================================================
-- Make yourself platform admin (after signing up once), then open /admin:
--   insert into public.platform_admins (user_id)
--   select id from auth.users where email = 'you@example.com';
-- ============================================================================

-- Open access (no trial, no limits) while plans are being prepared: lift existing trial workspaces
update public.orgs set plan = 'dedicated', status = 'active', trial_ends_at = null
 where coalesce((select value from public.platform_config where key = 'open_access'), 'true') = 'true'
   and (status = 'trial' or plan = 'trial');

-- Sign-up approval: the person's own status, and the platform admin's list and decision
create or replace function public.my_approval() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('approval', coalesce(p.approval, 'approved'), 'signed_up_at', p.signed_up_at, 'admin', is_platform_admin(), 'request', p.request)
    from profiles p where p.id = auth.uid()
$$;
create or replace function public.admin_signups() returns table (id uuid, full_name text, email text, approval text, signed_up_at timestamptz, approved_at timestamptz, workspaces bigint, request jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  return query select p.id, p.full_name, p.email, p.approval, p.signed_up_at, p.approved_at, (select count(*) from members m where m.user_id = p.id), p.request
    from profiles p where p.approval <> 'approved' or p.signed_up_at > now() - interval '30 days' order by (p.approval = 'pending') desc, p.signed_up_at desc nulls last limit 500;
end $$;
create or replace function public.admin_decide_signup(p_user uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Platform admins only.' using errcode = '42501'; end if;
  update profiles set approval = case when p_approve then 'approved' else 'rejected' end, approved_at = now(), approved_by = auth.uid() where id = p_user;
end $$;
-- invited by a company: joining that company approves the person
create or replace function public.approve_on_join() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' then update profiles set approval = 'approved', approved_at = coalesce(approved_at, now()) where id = new.user_id and approval = 'pending'; end if;
  return new;
end $$;
drop trigger if exists members_approve_on_join on public.members;
create trigger members_approve_on_join after insert or update of status on public.members for each row execute function public.approve_on_join();
revoke all on function public.admin_signups() from public, anon;
revoke all on function public.admin_decide_signup(uuid, boolean) from public, anon;
grant execute on function public.my_approval(), public.admin_signups(), public.admin_decide_signup(uuid, boolean) to authenticated;
-- the person describes what they need; the platform team sets the product up to match
create or replace function public.submit_request(p_request jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  update profiles set request = coalesce(p_request, '{}'::jsonb) || jsonb_build_object('sent_at', now()) where id = auth.uid();
end $$;
grant execute on function public.submit_request(jsonb) to authenticated;
