create table if not exists public.stardesk_client_sessions (
  id uuid primary key default gen_random_uuid(),
  rental_account_id uuid not null references public.rental_accounts(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  client_id text not null check (char_length(client_id) between 8 and 128),
  device_name text not null default 'Android client' check (char_length(device_name) between 1 and 120),
  app_version text not null default '0.1.0' check (char_length(app_version) <= 64),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  revoked_at timestamptz
);

create index if not exists stardesk_client_sessions_account_idx
  on public.stardesk_client_sessions (rental_account_id, created_at desc);
create index if not exists stardesk_client_sessions_expiry_idx
  on public.stardesk_client_sessions (expires_at)
  where revoked_at is null;

alter table public.stardesk_client_sessions enable row level security;
revoke all on table public.stardesk_client_sessions from anon, authenticated;
grant all on table public.stardesk_client_sessions to service_role;
