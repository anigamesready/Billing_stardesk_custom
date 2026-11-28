\set ON_ERROR_STOP on

CREATE ROLE stardesk_v0_runtime NOLOGIN;
CREATE SCHEMA androiddb_v0;
CREATE SCHEMA private;
CREATE SCHEMA api;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.organizations (
  id uuid PRIMARY KEY
);

CREATE TABLE androiddb_v0.rental_accounts (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  code text NOT NULL,
  client_label text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'active'
);

CREATE TABLE androiddb_v0.rental_pcs (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  display_name text NOT NULL,
  gpu_class text NOT NULL DEFAULT 'RTX 3060',
  hourly_rupiah integer NOT NULL DEFAULT 10000,
  hourly_coin_units integer NOT NULL,
  enabled boolean NOT NULL DEFAULT true
);

CREATE TABLE androiddb_v0.agent_devices (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  rental_pc_id uuid NOT NULL REFERENCES androiddb_v0.rental_pcs(id),
  agent_token_hash text NOT NULL UNIQUE,
  revoked_at timestamptz,
  status text NOT NULL DEFAULT 'online',
  last_heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.stardesk_pairings (
  rental_pc_id uuid PRIMARY KEY REFERENCES androiddb_v0.rental_pcs(id),
  org_id uuid NOT NULL REFERENCES public.organizations(id),
  stardesk_device_id text NOT NULL UNIQUE,
  verification_ciphertext text NOT NULL,
  verification_nonce text NOT NULL,
  verification_tag text NOT NULL,
  status text NOT NULL DEFAULT 'captured',
  captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.client_sessions (
  id uuid PRIMARY KEY,
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id),
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.coin_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL UNIQUE REFERENCES androiddb_v0.rental_accounts(id),
  balance numeric(18,8) NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.coin_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES androiddb_v0.coin_wallets(id),
  remaining_coins numeric(18,8) NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.coin_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES androiddb_v0.coin_wallets(id),
  lot_id uuid REFERENCES androiddb_v0.coin_lots(id),
  event_type text NOT NULL,
  amount_coins numeric(18,8) NOT NULL,
  balance_after numeric(18,8) NOT NULL,
  reference_type text NOT NULL,
  reference_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE androiddb_v0.coin_unit_config (
  singleton boolean PRIMARY KEY DEFAULT true,
  coin_scale integer NOT NULL DEFAULT 100
);

CREATE FUNCTION private.androiddb_v0_expire_wallet(p_wallet_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $$
  SELECT balance FROM androiddb_v0.coin_wallets WHERE id=p_wallet_id
$$;

CREATE FUNCTION private.androiddb_v0_get_client(p_session_token text)
RETURNS androiddb_v0.client_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $$
DECLARE s androiddb_v0.client_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s FROM androiddb_v0.client_sessions
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex')
    AND revoked_at IS NULL AND expires_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_CLIENT_SESSION_EXPIRED'; END IF;
  UPDATE androiddb_v0.client_sessions SET last_seen_at=clock_timestamp() WHERE id=s.id;
  RETURN s;
END;
$$;

CREATE FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(
  text,text,text,text,text
) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;

INSERT INTO androiddb_v0.coin_unit_config(singleton,coin_scale) VALUES(true,100);

\echo 'Applying migration 031 to a temporary PostgreSQL database'
\i backend/android-db/migrations/031_stardesk_invite_coin_sessions.sql

DO $$
DECLARE
  org_id uuid:=gen_random_uuid();
  account_id uuid:=gen_random_uuid();
  pc_id uuid:=gen_random_uuid();
  agent_id uuid:=gen_random_uuid();
  client_id uuid:=gen_random_uuid();
  wallet_id uuid:=gen_random_uuid();
  lot_id uuid:=gen_random_uuid();
  client_token text:='test-client-token-031';
  agent_token text:='test-agent-token-031';
  request_result jsonb;
  connected_result jsonb;
  tick_result jsonb;
  ended_result jsonb;
  session_id uuid;
  tick_id uuid:=gen_random_uuid();
  actual_balance numeric;
  debited numeric;
  session_status text;
BEGIN
  INSERT INTO public.organizations(id) VALUES(org_id);
  INSERT INTO androiddb_v0.rental_accounts(id,org_id,code,client_label,status)
    VALUES(account_id,org_id,'TEST-031','Smoke Test','active');
  INSERT INTO androiddb_v0.rental_pcs(id,org_id,display_name,hourly_coin_units,enabled)
    VALUES(pc_id,org_id,'CI-PC-60-COIN-HOUR',6000,true);
  INSERT INTO androiddb_v0.agent_devices(
    id,org_id,rental_pc_id,agent_token_hash,status,last_heartbeat_at,updated_at
  ) VALUES(
    agent_id,org_id,pc_id,
    encode(extensions.digest(agent_token,'sha256'),'hex'),
    'online',clock_timestamp(),clock_timestamp()
  );
  INSERT INTO androiddb_v0.stardesk_pairings(
    rental_pc_id,org_id,stardesk_device_id,verification_ciphertext,
    verification_nonce,verification_tag,status
  ) VALUES(pc_id,org_id,'861260101','encrypted-code','0123456789abcdef',
    '0123456789abcdefghijklmn','captured');

  INSERT INTO androiddb_v0.client_sessions(id,rental_account_id,token_hash,expires_at)
    VALUES(client_id,account_id,encode(extensions.digest(client_token,'sha256'),'hex'),
      clock_timestamp()+interval '1 day');

  INSERT INTO androiddb_v0.coin_wallets(id,rental_account_id,balance)
    VALUES(wallet_id,account_id,12000);
  INSERT INTO androiddb_v0.coin_lots(id,wallet_id,remaining_coins,expires_at)
    VALUES(lot_id,wallet_id,12000,clock_timestamp()+interval '7 days');

  PERFORM api.androiddb_v0_agent_ui_monitor_heartbeat(agent_token);
  request_result:=api.androiddb_v0_remote_request_session(client_token,pc_id,'ci-session-031-001');
  session_id:=(request_result->>'session_id')::uuid;
  IF request_result->>'status'<>'requested' THEN
    RAISE EXCEPTION 'Expected requested session, got %', request_result;
  END IF;
  SELECT balance INTO actual_balance FROM androiddb_v0.coin_wallets WHERE id=wallet_id;
  IF actual_balance<>12000 THEN
    RAISE EXCEPTION 'Coin must not be deducted on request; expected 12000 units, got %',actual_balance;
  END IF;

  connected_result:=api.androiddb_v0_agent_stardesk_session_event(agent_token,'connected',gen_random_uuid());
  IF connected_result->>'status'<>'connected' OR connected_result->>'session_id'<>session_id::text THEN
    RAISE EXCEPTION 'Connected event did not claim the matching pending reservation: %',connected_result;
  END IF;

  UPDATE androiddb_v0.coin_rental_sessions
    SET last_billed_at=clock_timestamp()-interval '1 hour'
    WHERE id=session_id;

  tick_result:=api.androiddb_v0_agent_stardesk_session_tick(agent_token,tick_id);
  SELECT balance INTO actual_balance FROM androiddb_v0.coin_wallets WHERE id=wallet_id;
  SELECT debited_coin_units INTO debited FROM androiddb_v0.coin_rental_sessions WHERE id=session_id;
  IF actual_balance<>6000 OR debited<>6000 THEN
    RAISE EXCEPTION 'One hour at 60 Coin/hour must debit 60 Coin (6000 x100 units); balance %, debited %',
      actual_balance,debited;
  END IF;

  PERFORM api.androiddb_v0_agent_stardesk_session_tick(agent_token,tick_id);
  SELECT balance INTO actual_balance FROM androiddb_v0.coin_wallets WHERE id=wallet_id;
  IF actual_balance<>6000 THEN
    RAISE EXCEPTION 'Duplicate tick event must be idempotent; balance is %',actual_balance;
  END IF;

  ended_result:=api.androiddb_v0_agent_stardesk_session_event(agent_token,'ended',gen_random_uuid());
  SELECT status INTO session_status FROM androiddb_v0.coin_rental_sessions WHERE id=session_id;
  IF session_status<>'ended' THEN
    RAISE EXCEPTION 'Ended event did not stop the session; status %',session_status;
  END IF;
END;
$$;

DO $$
DECLARE
  org_id uuid:=gen_random_uuid();
  account_id uuid:=gen_random_uuid();
  pc_id uuid:=gen_random_uuid();
  agent_id uuid:=gen_random_uuid();
  client_id uuid:=gen_random_uuid();
  wallet_id uuid:=gen_random_uuid();
  lot_id uuid:=gen_random_uuid();
  agent_token text:='test-agent-stale-031';
  session_id uuid:=gen_random_uuid();
  result jsonb;
  debited numeric;
  end_reason text;
BEGIN
  INSERT INTO public.organizations(id) VALUES(org_id);
  INSERT INTO androiddb_v0.rental_accounts(id,org_id,code,status)
    VALUES(account_id,org_id,'TEST-STALE-031','active');
  INSERT INTO androiddb_v0.rental_pcs(id,org_id,display_name,hourly_coin_units)
    VALUES(pc_id,org_id,'CI-PC-STALE',6000);
  INSERT INTO androiddb_v0.agent_devices(
    id,org_id,rental_pc_id,agent_token_hash,status,last_heartbeat_at,updated_at,last_ui_monitor_at
  ) VALUES(agent_id,org_id,pc_id,
    encode(extensions.digest(agent_token,'sha256'),'hex'),'online',
    clock_timestamp()-interval '2 minutes',clock_timestamp(),clock_timestamp()-interval '2 minutes');
  INSERT INTO androiddb_v0.client_sessions(id,rental_account_id,token_hash,expires_at)
    VALUES(client_id,account_id,encode(extensions.digest('test-client-stale-031','sha256'),'hex'),
      clock_timestamp()+interval '1 day');
  INSERT INTO androiddb_v0.coin_wallets(id,rental_account_id,balance)
    VALUES(wallet_id,account_id,12000);
  INSERT INTO androiddb_v0.coin_lots(id,wallet_id,remaining_coins,expires_at)
    VALUES(lot_id,wallet_id,12000,clock_timestamp()+interval '7 days');
  INSERT INTO androiddb_v0.coin_rental_sessions(
    id,org_id,rental_account_id,rental_pc_id,agent_device_id,client_session_id,
    status,idempotency_key,hourly_coin_units,connected_at,last_billed_at
  ) VALUES(session_id,org_id,account_id,pc_id,agent_id,client_id,
    'connected','ci-stale-session-031',6000,
    clock_timestamp()-interval '20 minutes',clock_timestamp()-interval '20 minutes');

  result:=api.androiddb_v0_agent_stardesk_session_event(agent_token,'ended',gen_random_uuid());
  SELECT debited_coin_units,end_reason INTO debited,end_reason
    FROM androiddb_v0.coin_rental_sessions WHERE id=session_id;
  IF debited>75.000001 OR debited<74.999999 OR end_reason<>'agent_heartbeat_timeout' THEN
    RAISE EXCEPTION 'Stale monitor should cap the charge at 45 seconds (75 x100 units); debited %, reason %',
      debited,end_reason;
  END IF;
END;
$$;

\echo 'PASS: reservation has no upfront debit; connected starts billing; 60 Coin/hour = 6000 x100 units/hour; duplicate tick is idempotent; end stops billing; stale monitor caps charge at 45 seconds.'
