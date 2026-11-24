-- Disposable PostgreSQL fixture for validating the additive WoL migration.
-- This is test-only and is never applied to the user's Android DB.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS private;
CREATE SCHEMA IF NOT EXISTS api;
CREATE SCHEMA IF NOT EXISTS remote_play;

CREATE TABLE public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL DEFAULT 'Test org'
);
CREATE TABLE public.admin_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  role text NOT NULL,
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  status text NOT NULL DEFAULT 'active'
);
CREATE TABLE public.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  device_name text,
  client_id text,
  status text NOT NULL DEFAULT 'offline',
  last_heartbeat_at timestamptz,
  last_seen_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE public.audit_logs (
  id bigserial PRIMARY KEY,
  org_id uuid NOT NULL,
  actor_user_id uuid,
  actor_device_id uuid,
  action text NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION private.remote_play_require_admin(p_session_token text)
RETURNS public.admin_accounts
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE a public.admin_accounts%ROWTYPE;
BEGIN
  IF p_session_token <> 'test-admin-token' THEN RAISE EXCEPTION 'ADMIN_SESSION_INVALID'; END IF;
  SELECT * INTO a FROM public.admin_accounts WHERE role='SUPER_ADMIN' AND status='active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;
  RETURN a;
END;
$$;
CREATE OR REPLACE FUNCTION private.admin_can_access_device(p_device_id uuid,p_org_id uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER
AS $$ SELECT EXISTS(SELECT 1 FROM public.devices WHERE id=p_device_id AND org_id=p_org_id) $$;

INSERT INTO public.organizations(id,name) VALUES ('10000000-0000-4000-8000-000000000001','Test org');
INSERT INTO public.admin_accounts(auth_user_id,role,org_id,status)
VALUES ('20000000-0000-4000-8000-000000000002','SUPER_ADMIN','10000000-0000-4000-8000-000000000001','active');
INSERT INTO public.devices(id,org_id,device_name,client_id,status,metadata)
VALUES ('30000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001',
        'PC Test','PC-TEST','offline','{"wolLanMac":"AA:BB:CC:DD:EE:FF"}');
