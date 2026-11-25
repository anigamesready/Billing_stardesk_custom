-- Ani Games Ready Admin Android DB v0 — isolated Coin rental domain.
-- Additive migration: does not read/write public.rental_accounts, rental_sessions,
-- remaining_seconds, or legacy expiry_at. Existing Admin auth/org and PC inventory
-- are referenced only for Owner authorization and device identity.
BEGIN;

CREATE SCHEMA IF NOT EXISTS androiddb_v0;
REVOKE ALL ON SCHEMA androiddb_v0 FROM PUBLIC;
REVOKE ALL ON SCHEMA androiddb_v0 FROM ani_api_runtime;

CREATE TABLE IF NOT EXISTS androiddb_v0.rental_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code text NOT NULL CHECK (code ~ '^[A-Z0-9_-]{3,40}$'),
  client_label text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','deleted')),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(org_id,code)
);
CREATE INDEX IF NOT EXISTS androiddb_v0_rentals_org_idx
  ON androiddb_v0.rental_accounts(org_id,code);

CREATE TABLE IF NOT EXISTS androiddb_v0.client_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  code_hash text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_unused_activation_per_rental
  ON androiddb_v0.client_credentials(rental_account_id)
  WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS androiddb_v0.client_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  refresh_token_hash text NOT NULL UNIQUE CHECK (refresh_token_hash ~ '^[0-9a-f]{64}$'),
  client_install_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  refresh_expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_active_client_per_rental
  ON androiddb_v0.client_sessions(rental_account_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS androiddb_v0_client_sessions_refresh_idx
  ON androiddb_v0.client_sessions(refresh_token_hash,refresh_expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL UNIQUE REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  balance numeric(18,8) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_topup_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  amount_rupiah bigint NOT NULL CHECK (amount_rupiah >= 1000),
  coin_amount numeric(18,8) NOT NULL CHECK (coin_amount > 0),
  expiry_days integer NOT NULL CHECK (expiry_days BETWEEN 3 AND 30),
  payment_method text NOT NULL DEFAULT 'qris_static' CHECK (payment_method='qris_static'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired')),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
  expires_at timestamptz NOT NULL DEFAULT (now()+interval '24 hours'),
  approved_by uuid,
  approved_at timestamptz,
  reviewed_by uuid,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(rental_account_id,idempotency_key)
);
CREATE INDEX IF NOT EXISTS androiddb_v0_topup_queue_idx
  ON androiddb_v0.coin_topup_orders(status,created_at DESC);

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES androiddb_v0.coin_wallets(id) ON DELETE CASCADE,
  source_order_id uuid UNIQUE REFERENCES androiddb_v0.coin_topup_orders(id) ON DELETE RESTRICT,
  original_coins numeric(18,8) NOT NULL CHECK (original_coins > 0),
  remaining_coins numeric(18,8) NOT NULL CHECK (remaining_coins >= 0 AND remaining_coins <= original_coins),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_coin_lots_fifo_idx
  ON androiddb_v0.coin_lots(wallet_id,expires_at,created_at,id)
  WHERE remaining_coins > 0;

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES androiddb_v0.coin_wallets(id) ON DELETE CASCADE,
  lot_id uuid REFERENCES androiddb_v0.coin_lots(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('topup_credit','session_debit','lot_expired','admin_adjustment')),
  amount_coins numeric(18,8) NOT NULL CHECK (amount_coins > 0),
  balance_after numeric(18,8) NOT NULL CHECK (balance_after >= 0),
  reference_type text NOT NULL,
  reference_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_coin_ledger_recent_idx
  ON androiddb_v0.coin_ledger(wallet_id,created_at DESC);

CREATE TABLE IF NOT EXISTS androiddb_v0.pc_coin_rates (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  gpu_class text NOT NULL CHECK (gpu_class IN ('GTX 1050','GTX 1660','RTX 3060','RTX 5060')),
  hourly_rupiah integer NOT NULL CHECK (hourly_rupiah > 0),
  hourly_coins numeric(12,8) NOT NULL CHECK (hourly_coins > 0),
  enabled boolean NOT NULL DEFAULT true,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS androiddb_v0.stardesk_device_links (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stardesk_device_id text NOT NULL UNIQUE CHECK (length(btrim(stardesk_device_id)) BETWEEN 1 AND 180),
  enabled boolean NOT NULL DEFAULT true,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS androiddb_v0.host_permissions (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  approved_by uuid,
  approved_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS androiddb_v0.host_enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code_hash text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS androiddb_v0.host_registrations (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  agent_version text,
  stardesk_device_id text,
  stardesk_ready boolean NOT NULL DEFAULT false,
  last_heartbeat_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

-- Reserved for the separate Coin session lifecycle. No legacy rental timer or
-- public.remote_play.sessions settlement is reused by this v0 module.
CREATE TABLE IF NOT EXISTS androiddb_v0.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  client_session_id uuid NOT NULL REFERENCES androiddb_v0.client_sessions(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','connecting','connected','ended','failed','cancelled')),
  idempotency_key text NOT NULL,
  reserved_coins numeric(18,8) NOT NULL DEFAULT 0 CHECK (reserved_coins >= 0),
  debited_coins numeric(18,8) NOT NULL DEFAULT 0 CHECK (debited_coins >= 0),
  connected_at timestamptz,
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz,
  UNIQUE(client_session_id,idempotency_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_open_session_per_rental
  ON androiddb_v0.sessions(rental_account_id)
  WHERE status IN ('requested','connecting','connected') AND settled_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_open_session_per_device
  ON androiddb_v0.sessions(device_id)
  WHERE status IN ('requested','connecting','connected') AND settled_at IS NULL;

CREATE TABLE IF NOT EXISTS androiddb_v0.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  actor_family text NOT NULL CHECK (actor_family IN ('admin','client','host','system')),
  actor_id text,
  event_name text NOT NULL,
  target_id text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_audit_recent_idx
  ON androiddb_v0.audit_events(org_id,created_at DESC);

ALTER TABLE androiddb_v0.rental_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.client_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.client_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.coin_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.coin_topup_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.coin_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.coin_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.pc_coin_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.stardesk_device_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.host_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.host_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.host_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.audit_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA androiddb_v0 FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA androiddb_v0 FROM ani_api_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA androiddb_v0 FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA androiddb_v0 FROM ani_api_runtime;

CREATE OR REPLACE FUNCTION private.androiddb_v0_require_admin(p_session_token text)
RETURNS public.admin_accounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
BEGIN
  a:=private.admin_account_by_token(p_session_token);
  IF a.role<>'SUPER_ADMIN' OR NOT EXISTS(
    SELECT 1 FROM public.org_members m
    WHERE m.auth_user_id=a.auth_user_id AND m.org_id=a.org_id AND m.role='owner'
  ) THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;
  RETURN a;
END;
$function$;

CREATE OR REPLACE FUNCTION private.androiddb_v0_get_client(p_session_token text)
RETURNS androiddb_v0.client_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE
  s androiddb_v0.client_sessions%ROWTYPE;
  a androiddb_v0.rental_accounts%ROWTYPE;
BEGIN
  IF NULLIF(BTRIM(p_session_token),'') IS NULL THEN RAISE EXCEPTION 'ANDROIDDB_V0_CLIENT_AUTH_REQUIRED'; END IF;
  SELECT * INTO s FROM androiddb_v0.client_sessions
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex')
    AND revoked_at IS NULL AND expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_CLIENT_SESSION_EXPIRED'; END IF;
  SELECT * INTO a FROM androiddb_v0.rental_accounts WHERE id=s.rental_account_id;
  IF NOT FOUND OR a.status<>'active' THEN RAISE EXCEPTION 'ANDROIDDB_V0_ACCOUNT_DISABLED'; END IF;
  UPDATE androiddb_v0.client_sessions SET last_seen_at=now() WHERE id=s.id;
  RETURN s;
END;
$function$;

CREATE OR REPLACE FUNCTION private.androiddb_v0_expire_wallet(p_wallet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $function$
DECLARE
  lot_row androiddb_v0.coin_lots%ROWTYPE;
  new_balance numeric(18,8);
BEGIN
  FOR lot_row IN
    SELECT * FROM androiddb_v0.coin_lots
    WHERE wallet_id=p_wallet_id AND remaining_coins>0 AND expires_at<=now()
    ORDER BY expires_at,created_at,id FOR UPDATE
  LOOP
    UPDATE androiddb_v0.coin_lots SET remaining_coins=0 WHERE id=lot_row.id;
    SELECT COALESCE(sum(remaining_coins),0) INTO new_balance
    FROM androiddb_v0.coin_lots WHERE wallet_id=p_wallet_id AND expires_at>now();
    INSERT INTO androiddb_v0.coin_ledger(wallet_id,lot_id,event_type,amount_coins,balance_after,
      reference_type,reference_id,idempotency_key)
    VALUES(p_wallet_id,lot_row.id,'lot_expired',lot_row.remaining_coins,new_balance,
      'coin_lot',lot_row.id::text,'androiddb-v0-expire:'||lot_row.id::text)
    ON CONFLICT(idempotency_key) DO NOTHING;
  END LOOP;
  SELECT COALESCE(sum(remaining_coins),0) INTO new_balance
  FROM androiddb_v0.coin_lots WHERE wallet_id=p_wallet_id AND expires_at>now();
  UPDATE androiddb_v0.coin_wallets SET balance=new_balance,updated_at=now() WHERE id=p_wallet_id;
  RETURN new_balance;
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_dashboard(
  p_session_token text,p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  lim integer:=greatest(1,least(200,coalesce(p_limit,100)));
  rentals jsonb; hosts jsonb; orders jsonb; summary jsonb;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.code),'[]'::jsonb) INTO rentals
  FROM (
    SELECT r.code,
      jsonb_build_object('id',r.id,'code',r.code,'client_label',r.client_label,'status',r.status,
        'created_at',r.created_at,
        'coin_balance',coalesce((SELECT sum(l.remaining_coins) FROM androiddb_v0.coin_wallets w
          JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
          WHERE w.rental_account_id=r.id AND l.expires_at>now()),0),
        'activation_issued',EXISTS(SELECT 1 FROM androiddb_v0.client_credentials c
          WHERE c.rental_account_id=r.id AND c.consumed_at IS NULL AND c.revoked_at IS NULL AND c.expires_at>now()),
        'client_logged_in',EXISTS(SELECT 1 FROM androiddb_v0.client_sessions cs
          WHERE cs.rental_account_id=r.id AND cs.revoked_at IS NULL AND cs.expires_at>now())) AS item
    FROM androiddb_v0.rental_accounts r
    WHERE r.org_id=a.org_id
    ORDER BY r.code LIMIT lim
  ) q;
  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.device_name,q.client_id),'[]'::jsonb) INTO hosts
  FROM (
    SELECT d.device_name,d.client_id,
      jsonb_build_object('device_id',d.id,'device_name',d.device_name,'client_id',d.client_id,
        'device_online',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false),
        'host_permission_enabled',coalesce(hp.enabled,false),
        'host_agent_online',coalesce(hr.last_heartbeat_at>now()-interval '60 seconds',false),
        'host_agent_ready',coalesce(hr.stardesk_ready AND hr.last_heartbeat_at>now()-interval '60 seconds',false),
        'agent_version',hr.agent_version,'host_last_seen_at',hr.last_heartbeat_at,
        'gpu_class',rate.gpu_class,'hourly_rupiah',rate.hourly_rupiah,'hourly_coins',rate.hourly_coins,
        'rate_enabled',coalesce(rate.enabled,false),
        'stardesk_device_id',link.stardesk_device_id,'stardesk_link_enabled',coalesce(link.enabled,false),
        'active_session',EXISTS(SELECT 1 FROM androiddb_v0.sessions s
          WHERE s.device_id=d.id AND s.status IN ('requested','connecting','connected') AND s.settled_at IS NULL)
      ) AS item
    FROM public.devices d
    LEFT JOIN androiddb_v0.host_permissions hp ON hp.device_id=d.id AND hp.org_id=d.org_id
    LEFT JOIN androiddb_v0.host_registrations hr ON hr.device_id=d.id AND hr.org_id=d.org_id AND hr.revoked_at IS NULL
    LEFT JOIN androiddb_v0.pc_coin_rates rate ON rate.device_id=d.id AND rate.org_id=d.org_id
    LEFT JOIN androiddb_v0.stardesk_device_links link ON link.device_id=d.id AND link.org_id=d.org_id
    WHERE d.org_id=a.org_id
  ) q;
  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC),'[]'::jsonb) INTO orders
  FROM (SELECT id,rental_account_id,amount_rupiah,coin_amount,expiry_days,status,created_at,expires_at
    FROM androiddb_v0.coin_topup_orders
    WHERE rental_account_id IN (SELECT id FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id)
    ORDER BY created_at DESC LIMIT lim) o;
  SELECT jsonb_build_object(
    'rental_accounts',(SELECT count(*) FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id AND status='active'),
    'pending_orders',(SELECT count(*) FROM androiddb_v0.coin_topup_orders o JOIN androiddb_v0.rental_accounts r ON r.id=o.rental_account_id WHERE r.org_id=a.org_id AND o.status='pending'),
    'wallet_accounts',(SELECT count(*) FROM androiddb_v0.coin_wallets w JOIN androiddb_v0.rental_accounts r ON r.id=w.rental_account_id WHERE r.org_id=a.org_id)
  ) INTO summary;
  RETURN jsonb_build_object('ok',true,'rental_accounts',rentals,'host_devices',hosts,'orders',orders,
    'summary',summary,'coin_unit_scale',1,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_create_rental(
  p_session_token text,p_code text,p_client_label text DEFAULT ''
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF coalesce(p_code,'') !~ '^[A-Za-z0-9_-]{3,40}$' THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_CODE_INVALID'; END IF;
  IF length(coalesce(p_client_label,''))>120 THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_LABEL_INVALID'; END IF;
  INSERT INTO androiddb_v0.rental_accounts(org_id,code,client_label,created_by)
  VALUES(a.org_id,upper(p_code),coalesce(btrim(p_client_label),''),a.auth_user_id)
  RETURNING * INTO r;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id);
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'rental_created',r.id::text,jsonb_build_object('code',r.code));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'code',r.code,'status',r.status);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_set_rental_status(
  p_session_token text,p_rental_account_id uuid,p_enabled boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  UPDATE androiddb_v0.rental_accounts SET status=CASE WHEN p_enabled THEN 'active' ELSE 'disabled' END,updated_at=now()
  WHERE id=p_rental_account_id AND org_id=a.org_id RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_NOT_FOUND'; END IF;
  IF NOT p_enabled THEN
    UPDATE androiddb_v0.client_credentials SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
    UPDATE androiddb_v0.client_sessions SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
  END IF;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'rental_status_changed',r.id::text,jsonb_build_object('enabled',p_enabled));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'status',r.status);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_issue_activation(
  p_session_token text,p_rental_account_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  code text:=encode(extensions.gen_random_bytes(8),'hex');
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts
  WHERE id=p_rental_account_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'active' THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_NOT_ACTIVE'; END IF;
  UPDATE androiddb_v0.client_credentials SET revoked_at=coalesce(revoked_at,now())
  WHERE rental_account_id=r.id AND revoked_at IS NULL;
  UPDATE androiddb_v0.client_sessions SET revoked_at=coalesce(revoked_at,now())
  WHERE rental_account_id=r.id AND revoked_at IS NULL;
  INSERT INTO androiddb_v0.client_credentials(rental_account_id,code_hash,created_by,expires_at)
  VALUES(r.id,encode(extensions.digest(code,'sha256'),'hex'),a.auth_user_id,now()+interval '24 hours');
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'activation_issued',r.id::text,jsonb_build_object('expires_at',now()+interval '24 hours'));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'rental_code',r.code,
    'activation_code',code,'expires_at',now()+interval '24 hours');
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_wallet(
  p_session_token text,p_rental_account_id uuid,p_history_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE; lim integer:=greatest(1,least(100,coalesce(p_history_limit,50)));
  v_balance numeric(18,8); v_lots jsonb; v_ledger jsonb; v_orders jsonb;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts
  WHERE id=p_rental_account_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_NOT_FOUND'; END IF;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  v_balance:=private.androiddb_v0_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.expires_at,x.created_at),'[]'::jsonb) INTO v_lots
  FROM (SELECT id,original_coins,remaining_coins,expires_at,created_at
    FROM androiddb_v0.coin_lots WHERE wallet_id=w.id ORDER BY expires_at,created_at LIMIT lim) x;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_ledger
  FROM (SELECT event_type,amount_coins,balance_after,reference_type,reference_id,created_at
    FROM androiddb_v0.coin_ledger WHERE wallet_id=w.id ORDER BY created_at DESC LIMIT lim) x;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_orders
  FROM (SELECT id,amount_rupiah,coin_amount,expiry_days,status,created_at,expires_at,approved_at,rejection_reason
    FROM androiddb_v0.coin_topup_orders WHERE rental_account_id=r.id ORDER BY created_at DESC LIMIT lim) x;
  RETURN jsonb_build_object('ok',true,'rental_account',jsonb_build_object('id',r.id,'code',r.code,
    'client_label',r.client_label,'status',r.status),'wallet',jsonb_build_object('id',w.id,'balance',v_balance),
    'lots',v_lots,'ledger',v_ledger,'orders',v_orders,'coin_unit_scale',1,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_approve_topup(
  p_session_token text,p_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; o androiddb_v0.coin_topup_orders%ROWTYPE;
  r androiddb_v0.rental_accounts%ROWTYPE; w androiddb_v0.coin_wallets%ROWTYPE;
  new_balance numeric(18,8);
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO o FROM androiddb_v0.coin_topup_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_ORDER_NOT_FOUND'; END IF;
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=o.rental_account_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
  IF o.status='approved' THEN RETURN jsonb_build_object('ok',true,'idempotent',true,'order_id',o.id,'status',o.status); END IF;
  IF o.status<>'pending' THEN RAISE EXCEPTION 'ANDROIDDB_V0_ORDER_NOT_PENDING'; END IF;
  IF o.expires_at<=now() THEN
    UPDATE androiddb_v0.coin_topup_orders SET status='expired',reviewed_by=a.auth_user_id,reviewed_at=now() WHERE id=o.id;
    RETURN jsonb_build_object('ok',false,'order_id',o.id,'status','expired');
  END IF;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  PERFORM private.androiddb_v0_expire_wallet(w.id);
  UPDATE androiddb_v0.coin_topup_orders SET status='approved',approved_by=a.auth_user_id,approved_at=now(),
    reviewed_by=a.auth_user_id,reviewed_at=now() WHERE id=o.id;
  INSERT INTO androiddb_v0.coin_lots(wallet_id,source_order_id,original_coins,remaining_coins,expires_at)
  VALUES(w.id,o.id,o.coin_amount,o.coin_amount,now()+make_interval(days=>o.expiry_days));
  SELECT COALESCE(sum(remaining_coins),0) INTO new_balance FROM androiddb_v0.coin_lots
  WHERE wallet_id=w.id AND expires_at>now();
  UPDATE androiddb_v0.coin_wallets SET balance=new_balance,updated_at=now() WHERE id=w.id;
  INSERT INTO androiddb_v0.coin_ledger(wallet_id,event_type,amount_coins,balance_after,reference_type,reference_id,idempotency_key)
  VALUES(w.id,'topup_credit',o.coin_amount,new_balance,'topup_order',o.id::text,'androiddb-v0-topup:'||o.id::text)
  ON CONFLICT(idempotency_key) DO NOTHING;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'topup_approved',o.id::text,jsonb_build_object('rental_account_id',r.id,'coins',o.coin_amount));
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'status','approved','balance',new_balance,'coin_amount',o.coin_amount);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_reject_topup(
  p_session_token text,p_order_id uuid,p_reason text DEFAULT 'Pembayaran belum terverifikasi'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; o androiddb_v0.coin_topup_orders%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO o FROM androiddb_v0.coin_topup_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_ORDER_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM androiddb_v0.rental_accounts r WHERE r.id=o.rental_account_id AND r.org_id=a.org_id) THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
  IF o.status<>'pending' THEN RAISE EXCEPTION 'ANDROIDDB_V0_ORDER_NOT_PENDING'; END IF;
  UPDATE androiddb_v0.coin_topup_orders SET status='rejected',reviewed_by=a.auth_user_id,reviewed_at=now(),
    rejection_reason=left(coalesce(nullif(btrim(p_reason),''),'Pembayaran belum terverifikasi'),180)
  WHERE id=o.id;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'topup_rejected',o.id::text,jsonb_build_object('reason',left(coalesce(p_reason,''),180)));
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'status','rejected');
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_set_device_rate(
  p_session_token text,p_device_id uuid,p_gpu_class text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; device_row public.devices%ROWTYPE;
  rupiah integer; coins numeric(12,8);
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO device_row FROM public.devices WHERE id=p_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  CASE p_gpu_class
    WHEN 'GTX 1050' THEN rupiah:=6000; coins:=45;
    WHEN 'GTX 1660' THEN rupiah:=6000; coins:=45;
    WHEN 'RTX 3060' THEN rupiah:=7000; coins:=52.5;
    WHEN 'RTX 5060' THEN rupiah:=8000; coins:=60;
    ELSE RAISE EXCEPTION 'ANDROIDDB_V0_GPU_CLASS_INVALID';
  END CASE;
  INSERT INTO androiddb_v0.pc_coin_rates(device_id,org_id,gpu_class,hourly_rupiah,hourly_coins,enabled,updated_by,updated_at)
  VALUES(p_device_id,a.org_id,p_gpu_class,rupiah,coins,true,a.auth_user_id,now())
  ON CONFLICT(device_id) DO UPDATE SET gpu_class=EXCLUDED.gpu_class,hourly_rupiah=EXCLUDED.hourly_rupiah,
    hourly_coins=EXCLUDED.hourly_coins,enabled=true,updated_by=a.auth_user_id,updated_at=now();
  RETURN jsonb_build_object('ok',true,'device_id',p_device_id,'gpu_class',p_gpu_class,'hourly_rupiah',rupiah,'hourly_coins',coins);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_link_stardesk_device(
  p_session_token text,p_device_id uuid,p_stardesk_device_id text,p_enabled boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF NOT EXISTS(SELECT 1 FROM public.devices WHERE id=p_device_id AND org_id=a.org_id) THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  IF length(btrim(coalesce(p_stardesk_device_id,''))) NOT BETWEEN 1 AND 180 THEN RAISE EXCEPTION 'ANDROIDDB_V0_STAR_DESK_ID_INVALID'; END IF;
  INSERT INTO androiddb_v0.stardesk_device_links(device_id,org_id,stardesk_device_id,enabled,updated_by,updated_at)
  VALUES(p_device_id,a.org_id,btrim(p_stardesk_device_id),coalesce(p_enabled,true),a.auth_user_id,now())
  ON CONFLICT(device_id) DO UPDATE SET stardesk_device_id=EXCLUDED.stardesk_device_id,
    enabled=EXCLUDED.enabled,updated_by=a.auth_user_id,updated_at=now();
  RETURN jsonb_build_object('ok',true,'device_id',p_device_id,'stardesk_device_id',btrim(p_stardesk_device_id),'enabled',coalesce(p_enabled,true));
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_set_host_permission(
  p_session_token text,p_device_id uuid,p_enabled boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF NOT EXISTS(SELECT 1 FROM public.devices WHERE id=p_device_id AND org_id=a.org_id) THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  INSERT INTO androiddb_v0.host_permissions(device_id,org_id,enabled,approved_by,approved_at,updated_at)
  VALUES(p_device_id,a.org_id,p_enabled,a.auth_user_id,CASE WHEN p_enabled THEN now() ELSE NULL END,now())
  ON CONFLICT(device_id) DO UPDATE SET enabled=EXCLUDED.enabled,approved_by=a.auth_user_id,
    approved_at=CASE WHEN EXCLUDED.enabled THEN now() ELSE androiddb_v0.host_permissions.approved_at END,updated_at=now();
  IF NOT p_enabled THEN
    UPDATE androiddb_v0.host_registrations SET revoked_at=coalesce(revoked_at,now()),updated_at=now()
    WHERE device_id=p_device_id AND revoked_at IS NULL;
    UPDATE androiddb_v0.sessions SET status='cancelled',ended_at=coalesce(ended_at,now()),
      end_reason='host_permission_revoked',settled_at=coalesce(settled_at,now())
    WHERE device_id=p_device_id AND status IN ('requested','connecting','connected') AND settled_at IS NULL;
  END IF;
  RETURN jsonb_build_object('ok',true,'device_id',p_device_id,'enabled',p_enabled);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_issue_host_enrollment(
  p_session_token text,p_device_id uuid,p_valid_minutes integer DEFAULT 15
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; code text:=encode(extensions.gen_random_bytes(32),'hex');
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF NOT EXISTS(SELECT 1 FROM androiddb_v0.host_permissions WHERE device_id=p_device_id AND org_id=a.org_id AND enabled) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOST_PERMISSION_REQUIRED';
  END IF;
  UPDATE androiddb_v0.host_enrollments SET consumed_at=coalesce(consumed_at,now())
  WHERE device_id=p_device_id AND consumed_at IS NULL;
  INSERT INTO androiddb_v0.host_enrollments(device_id,org_id,code_hash,expires_at,created_by)
  VALUES(p_device_id,a.org_id,encode(extensions.digest(code,'sha256'),'hex'),
    now()+make_interval(mins=>greatest(5,least(30,coalesce(p_valid_minutes,15)))),a.auth_user_id);
  RETURN jsonb_build_object('ok',true,'enrollment_code',code,'expires_at',now()+make_interval(mins=>greatest(5,least(30,coalesce(p_valid_minutes,15)))));
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_host_enroll(
  p_enrollment_code text,p_agent_version text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE e androiddb_v0.host_enrollments%ROWTYPE; p androiddb_v0.host_permissions%ROWTYPE;
  token text:=encode(extensions.gen_random_bytes(32),'hex');
BEGIN
  SELECT * INTO e FROM androiddb_v0.host_enrollments
  WHERE code_hash=encode(extensions.digest(p_enrollment_code,'sha256'),'hex')
    AND consumed_at IS NULL AND expires_at>now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_HOST_ENROLLMENT_INVALID'; END IF;
  SELECT * INTO p FROM androiddb_v0.host_permissions WHERE device_id=e.device_id AND org_id=e.org_id AND enabled;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_HOST_PERMISSION_REQUIRED'; END IF;
  UPDATE androiddb_v0.host_enrollments SET consumed_at=now() WHERE id=e.id;
  INSERT INTO androiddb_v0.host_registrations(device_id,org_id,token_hash,agent_version,stardesk_ready,last_heartbeat_at,created_at,updated_at,revoked_at)
  VALUES(e.device_id,e.org_id,encode(extensions.digest(token,'sha256'),'hex'),left(p_agent_version,80),false,now(),now(),now(),NULL)
  ON CONFLICT(device_id) DO UPDATE SET token_hash=EXCLUDED.token_hash,agent_version=EXCLUDED.agent_version,
    stardesk_ready=false,last_heartbeat_at=now(),updated_at=now(),revoked_at=NULL;
  RETURN jsonb_build_object('ok',true,'device_id',e.device_id,'host_token',token,'stardesk_ready',false);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_host_heartbeat(
  p_host_token text,p_stardesk_ready boolean,p_agent_version text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE h androiddb_v0.host_registrations%ROWTYPE; p androiddb_v0.host_permissions%ROWTYPE;
  l androiddb_v0.stardesk_device_links%ROWTYPE;
BEGIN
  SELECT * INTO h FROM androiddb_v0.host_registrations
  WHERE token_hash=encode(extensions.digest(p_host_token,'sha256'),'hex') AND revoked_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_HOST_REVOKED'; END IF;
  SELECT * INTO p FROM androiddb_v0.host_permissions WHERE device_id=h.device_id AND org_id=h.org_id AND enabled;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_HOST_PERMISSION_REQUIRED'; END IF;
  SELECT * INTO l FROM androiddb_v0.stardesk_device_links
  WHERE device_id=h.device_id AND org_id=h.org_id AND enabled;
  UPDATE androiddb_v0.host_registrations SET stardesk_ready=coalesce(p_stardesk_ready,false) AND l.device_id IS NOT NULL,
    last_heartbeat_at=now(),agent_version=coalesce(nullif(p_agent_version,''),agent_version),stardesk_device_id=l.stardesk_device_id,updated_at=now()
  WHERE device_id=h.device_id;
  RETURN jsonb_build_object('ok',true,'stardesk_ready',coalesce(p_stardesk_ready,false) AND l.device_id IS NOT NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_login(
  p_rental_code text,p_activation_code text,p_client_install_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE r androiddb_v0.rental_accounts%ROWTYPE; c androiddb_v0.client_credentials%ROWTYPE;
  raw_token text:=encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh text:=encode(extensions.gen_random_bytes(32),'hex'); sid uuid;
BEGIN
  IF length(coalesce(p_rental_code,'')) NOT BETWEEN 3 AND 40
    OR length(coalesce(p_activation_code,'')) NOT BETWEEN 16 AND 64
    OR length(coalesce(p_client_install_id,'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;
  SELECT * INTO r FROM androiddb_v0.rental_accounts
  WHERE upper(code)=upper(btrim(p_rental_code)) FOR UPDATE;
  IF NOT FOUND OR r.status<>'active' THEN RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS'; END IF;
  SELECT * INTO c FROM androiddb_v0.client_credentials
  WHERE rental_account_id=r.id AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>now()
  FOR UPDATE;
  IF NOT FOUND OR c.code_hash<>encode(extensions.digest(p_activation_code,'sha256'),'hex') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;
  UPDATE androiddb_v0.client_sessions SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
  UPDATE androiddb_v0.client_credentials SET consumed_at=now() WHERE id=c.id;
  INSERT INTO androiddb_v0.client_sessions(rental_account_id,token_hash,refresh_token_hash,client_install_id,expires_at,refresh_expires_at)
  VALUES(r.id,encode(extensions.digest(raw_token,'sha256'),'hex'),encode(extensions.digest(raw_refresh,'sha256'),'hex'),
    left(p_client_install_id,128),now()+interval '12 hours',now()+interval '30 days')
  RETURNING id INTO sid;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(r.org_id,'client',sid::text,'client_login',r.id::text,jsonb_build_object('client_install_id',left(p_client_install_id,128)));
  RETURN jsonb_build_object('ok',true,'access_token',raw_token,'refresh_token',raw_refresh,
    'token_type','bearer','expires_at',now()+interval '12 hours','refresh_expires_at',now()+interval '30 days','client_session_id',sid);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_refresh(p_refresh_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE s androiddb_v0.client_sessions%ROWTYPE; token text:=encode(extensions.gen_random_bytes(32),'hex');
  refresh text:=encode(extensions.gen_random_bytes(32),'hex');
BEGIN
  SELECT * INTO s FROM androiddb_v0.client_sessions
  WHERE refresh_token_hash=encode(extensions.digest(p_refresh_token,'sha256'),'hex')
    AND revoked_at IS NULL AND refresh_expires_at>now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_REFRESH_EXPIRED'; END IF;
  UPDATE androiddb_v0.client_sessions SET token_hash=encode(extensions.digest(token,'sha256'),'hex'),
    refresh_token_hash=encode(extensions.digest(refresh,'sha256'),'hex'),
    expires_at=now()+interval '12 hours',refresh_expires_at=now()+interval '30 days',last_seen_at=now()
  WHERE id=s.id;
  RETURN jsonb_build_object('ok',true,'access_token',token,'refresh_token',refresh,
    'expires_at',now()+interval '12 hours','refresh_expires_at',now()+interval '30 days');
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE n integer;
BEGIN
  UPDATE androiddb_v0.client_sessions SET revoked_at=coalesce(revoked_at,now())
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND revoked_at IS NULL;
  GET DIAGNOSTICS n=ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'revoked',n>0);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_coin_wallet(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; w androiddb_v0.coin_wallets%ROWTYPE;
  bal numeric(18,8); lots jsonb;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(c.rental_account_id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'original_coins',original_coins,
    'remaining_coins',remaining_coins,'expires_at',expires_at,'created_at',created_at)
    ORDER BY expires_at,created_at),'[]'::jsonb) INTO lots
  FROM androiddb_v0.coin_lots WHERE wallet_id=w.id AND remaining_coins>0 AND expires_at>now();
  RETURN jsonb_build_object('ok',true,'balance',bal,'lots',lots,'coin_unit_scale',1,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_coin_history(p_session_token text,p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; w androiddb_v0.coin_wallets%ROWTYPE;
  led jsonb; ord jsonb; bal numeric(18,8); lim integer:=greatest(1,least(100,coalesce(p_limit,50)));
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(c.rental_account_id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO led
  FROM (SELECT event_type,amount_coins,balance_after,reference_type,reference_id,created_at
    FROM androiddb_v0.coin_ledger WHERE wallet_id=w.id ORDER BY created_at DESC LIMIT lim) x;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO ord
  FROM (SELECT id,amount_rupiah,coin_amount,expiry_days,status,created_at,approved_at,expires_at
    FROM androiddb_v0.coin_topup_orders WHERE rental_account_id=c.rental_account_id ORDER BY created_at DESC LIMIT lim) x;
  RETURN jsonb_build_object('ok',true,'balance',bal,'ledger',led,'orders',ord);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE; bal numeric(18,8); hosts jsonb; active boolean;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  SELECT EXISTS(SELECT 1 FROM androiddb_v0.sessions
    WHERE rental_account_id=r.id AND status IN ('requested','connecting','connected') AND settled_at IS NULL)
  INTO active;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'device_id',d.id,'client_id',d.client_id,'device_name',d.device_name,
    'online',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false),
    'billing_online',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false),
    'host_agent_online',coalesce(hr.last_heartbeat_at>now()-interval '60 seconds',false),
    'host_agent_ready',coalesce(hr.stardesk_ready AND hr.last_heartbeat_at>now()-interval '60 seconds',false),
    'available',r.status='active' AND bal>0 AND NOT active
      AND coalesce(hp.enabled,false) AND coalesce(rate.enabled,false) AND coalesce(link.enabled,false)
      AND coalesce(hr.stardesk_ready AND hr.last_heartbeat_at>now()-interval '60 seconds',false)
      AND NOT EXISTS(SELECT 1 FROM androiddb_v0.sessions s WHERE s.device_id=d.id
        AND s.status IN ('requested','connecting','connected') AND s.settled_at IS NULL),
    'remote_play_enabled',coalesce(hp.enabled,false),
    'gpu_class',rate.gpu_class,'hourly_rupiah',rate.hourly_rupiah,'hourly_coins',rate.hourly_coins,
    'rate_configured',coalesce(rate.enabled,false),'stardesk_device_id',link.stardesk_device_id,
    'stardesk_linked',coalesce(link.enabled,false)
  ) ORDER BY d.device_name),'[]'::jsonb) INTO hosts
  FROM public.devices d
  LEFT JOIN androiddb_v0.host_permissions hp ON hp.device_id=d.id AND hp.org_id=d.org_id
  LEFT JOIN androiddb_v0.pc_coin_rates rate ON rate.device_id=d.id AND rate.org_id=d.org_id
  LEFT JOIN androiddb_v0.stardesk_device_links link ON link.device_id=d.id AND link.org_id=d.org_id
  LEFT JOIN androiddb_v0.host_registrations hr ON hr.device_id=d.id AND hr.org_id=d.org_id AND hr.revoked_at IS NULL
  WHERE d.org_id=r.org_id;
  RETURN jsonb_build_object('ok',true,'rental_account',jsonb_build_object('id',r.id,'code',r.code,
    'client_label',r.client_label,'status',r.status),'wallet',jsonb_build_object('balance',bal),
    'can_start',r.status='active' AND bal>0 AND NOT active,'active_session',NULL,'hosts',hosts,
    'coin_unit_scale',1,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_coin_create_topup(
  p_session_token text,p_amount_rupiah bigint,p_idempotency_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE; o androiddb_v0.coin_topup_orders%ROWTYPE;
  current_balance numeric(18,8); coins numeric(18,8); projected numeric(18,8); days integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id;
  IF p_amount_rupiah<1000 OR p_amount_rupiah>10000000 OR p_amount_rupiah%1000<>0
    OR length(coalesce(p_idempotency_key,'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_TOPUP_INVALID';
  END IF;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  current_balance:=private.androiddb_v0_expire_wallet(w.id);
  coins:=round(p_amount_rupiah::numeric*60/8000,8);
  projected:=current_balance+coins;
  days:=CASE WHEN projected<300 THEN 3 WHEN projected<600 THEN 7 WHEN projected<900 THEN 10
    WHEN projected<1200 THEN 14 WHEN projected<1500 THEN 17 WHEN projected<1800 THEN 21
    WHEN projected<2100 THEN 24 WHEN projected<2400 THEN 28 ELSE 30 END;
  INSERT INTO androiddb_v0.coin_topup_orders(rental_account_id,amount_rupiah,coin_amount,expiry_days,idempotency_key)
  VALUES(r.id,p_amount_rupiah,coins,days,p_idempotency_key)
  ON CONFLICT(rental_account_id,idempotency_key) DO NOTHING
  RETURNING * INTO o;
  IF NOT FOUND THEN SELECT * INTO o FROM androiddb_v0.coin_topup_orders
    WHERE rental_account_id=r.id AND idempotency_key=p_idempotency_key; END IF;
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'amount_rupiah',o.amount_rupiah,'coin_amount',o.coin_amount,
    'expiry_days',o.expiry_days,'status',o.status,'expires_at',o.expires_at,'payment_method',o.payment_method,
    'wallet_balance',current_balance);
END;
$function$;

-- Explicit allowlist: API users can execute only these purpose-built RPCs.
REVOKE ALL ON FUNCTION private.androiddb_v0_require_admin(text) FROM PUBLIC,ani_api_runtime;
REVOKE ALL ON FUNCTION private.androiddb_v0_get_client(text) FROM PUBLIC,ani_api_runtime;
REVOKE ALL ON FUNCTION private.androiddb_v0_expire_wallet(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_create_rental(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_set_rental_status(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_issue_activation(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_wallet(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_approve_topup(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_reject_topup(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_set_device_rate(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_link_stardesk_device(text,uuid,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_set_host_permission(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_issue_host_enrollment(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_host_enroll(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_host_heartbeat(text,boolean,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_refresh(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_logout(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_coin_wallet(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_coin_history(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_dashboard(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_coin_create_topup(text,bigint,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_create_rental(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_set_rental_status(text,uuid,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_issue_activation(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_wallet(text,uuid,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_approve_topup(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_reject_topup(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_set_device_rate(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_link_stardesk_device(text,uuid,text,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_set_host_permission(text,uuid,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_issue_host_enrollment(text,uuid,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_host_enroll(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_host_heartbeat(text,boolean,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_refresh(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_coin_wallet(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_coin_history(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_dashboard(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_coin_create_topup(text,bigint,text) TO ani_api_runtime;

COMMIT;
