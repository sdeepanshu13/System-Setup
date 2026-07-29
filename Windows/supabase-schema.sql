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
