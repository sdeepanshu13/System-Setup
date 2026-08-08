-- System-Setup: encrypted user profile storage
-- Run this once in the Supabase SQL Editor (Dashboard -> SQL Editor -> New query).
--
-- Only ciphertext is stored. The AES key is derived from a passphrase that never
-- leaves the user's machine, so nobody with database access -- including the
-- project owner -- can read a user's selections.

create table if not exists public.user_profiles (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    salt       text        not null,
    iv         text        not null,
    mac        text        not null,
    cipher     text        not null,
    iterations integer     not null default 200000,
    updated_at timestamptz not null default now()
);

alter table public.user_profiles enable row level security;

-- Each user may only touch their own row.
drop policy if exists "own profile select" on public.user_profiles;
create policy "own profile select" on public.user_profiles
    for select to authenticated
    using ((select auth.uid()) = user_id);

drop policy if exists "own profile insert" on public.user_profiles;
create policy "own profile insert" on public.user_profiles
    for insert to authenticated
    with check ((select auth.uid()) = user_id);

drop policy if exists "own profile update" on public.user_profiles;
create policy "own profile update" on public.user_profiles
    for update to authenticated
    using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);

drop policy if exists "own profile delete" on public.user_profiles;
create policy "own profile delete" on public.user_profiles
    for delete to authenticated
    using ((select auth.uid()) = user_id);


-- ---------------------------------------------------------------------------
-- Error reporting
-- ---------------------------------------------------------------------------
-- Install failures are pushed here so they can be reviewed and fixed centrally.
--
-- Access model is deliberately asymmetric: clients may INSERT but never SELECT.
-- If users could read this table they'd see other people's machine names and
-- paths. Only the project owner reads it -- from the dashboard or with the
-- secret key from a trusted machine (never from the shipped app).

create table if not exists public.setup_errors (
    id          bigint generated always as identity primary key,
    user_id     uuid references auth.users (id) on delete set null,
    platform    text        not null default 'unknown',   -- windows | macos
    phase       text        not null default 'unknown',   -- packages | bootstrap | profile | ui
    package     text,                                     -- failing package, when applicable
    message     text        not null,
    detail      text,                                     -- exit code, stack, log excerpt
    app_version text,
    os_version  text,
    resolved    boolean     not null default false,
    created_at  timestamptz not null default now()
);

create index if not exists setup_errors_unresolved_idx
    on public.setup_errors (created_at desc) where not resolved;

alter table public.setup_errors enable row level security;

-- Anyone running the installer may report a failure, signed in or not.
drop policy if exists "anyone can report an error" on public.setup_errors;
create policy "anyone can report an error" on public.setup_errors
    for insert to anon, authenticated
    with check (true);

-- No select/update/delete policies: only the service role (owner) can read,
-- triage and clear these rows.
