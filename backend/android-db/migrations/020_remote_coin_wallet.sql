-- StarDesk Android DB: additive Coin Wallet + StarDesk device map.
-- Provenance: remote-play control plane 013-019 ported from
-- anigamesready/PC-Billing@bd11d9b4e53ece362715a772f210c7e3b13adba1.
-- This migration does NOT alter legacy rental balances or settlement functions.
-- Apply only after the Android DB baseline and Remote Play migrations 013-019.
BEGIN;

CREATE TABLE IF NOT EXISTS remote_play.coin_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL UNIQUE REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  balance numeric(18,8) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS remote_play.coin_topup_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  amount_rupiah bigint NOT NULL CHECK (amount_rupiah >= 1000),
  coin_amount numeric(18,8) NOT NULL CHECK (coin_amount > 0),
  expiry_days integer NOT NULL CHECK (expiry_days BETWEEN 3 AND 30),
  payment_method text NOT NULL DEFAULT 'qris_static' CHECK (payment_method='qris_static'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','expired')),
  idempotency_key text NOT NULL,
  expires_at timestamptz NOT NULL DEFAULT (now()+interval '24 hours'),
  approved_by uuid,
  approved_at timestamptz,
  reviewed_by uuid,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(rental_account_id,idempotency_key)
);
CREATE INDEX IF NOT EXISTS coin_topup_pending_org_idx
  ON remote_play.coin_topup_orders(status,created_at DESC);

CREATE TABLE IF NOT EXISTS remote_play.coin_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES remote_play.coin_wallets(id) ON DELETE CASCADE,
  source_order_id uuid UNIQUE REFERENCES remote_play.coin_topup_orders(id) ON DELETE RESTRICT,
  original_coins numeric(18,8) NOT NULL CHECK (original_coins > 0),
  remaining_coins numeric(18,8) NOT NULL CHECK (remaining_coins >= 0 AND remaining_coins <= original_coins),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coin_lots_spendable_fifo_idx
  ON remote_play.coin_lots(wallet_id,expires_at,created_at,id)
  WHERE remaining_coins > 0;

CREATE TABLE IF NOT EXISTS remote_play.coin_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES remote_play.coin_wallets(id) ON DELETE CASCADE,
  lot_id uuid REFERENCES remote_play.coin_lots(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('topup_credit','session_debit','lot_expired','admin_adjustment')),
  amount_coins numeric(18,8) NOT NULL CHECK (amount_coins > 0),
  balance_after numeric(18,8) NOT NULL CHECK (balance_after >= 0),
  reference_type text NOT NULL,
  reference_id text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coin_ledger_wallet_recent_idx
  ON remote_play.coin_ledger(wallet_id,created_at DESC);

CREATE TABLE IF NOT EXISTS remote_play.pc_coin_rates (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  gpu_class text NOT NULL CHECK (gpu_class IN ('GTX 1050','GTX 1660','RTX 3060','RTX 5060')),
  hourly_rupiah integer NOT NULL CHECK (hourly_rupiah > 0),
  hourly_coins numeric(12,8) NOT NULL CHECK (hourly_coins > 0),
  enabled boolean NOT NULL DEFAULT true,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- StarDesk's own device identifier is not assumed to equal public.devices.id.
-- Owner must explicitly map the existing Android DB device to its StarDesk ID.
CREATE TABLE IF NOT EXISTS remote_play.stardesk_device_links (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stardesk_device_id text NOT NULL UNIQUE CHECK (length(btrim(stardesk_device_id)) BETWEEN 1 AND 180),
  enabled boolean NOT NULL DEFAULT true,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE remote_play.coin_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.coin_topup_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.coin_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.coin_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.pc_coin_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.stardesk_device_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA remote_play FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA remote_play FROM PUBLIC;
REVOKE ALL ON TABLE remote_play.coin_wallets,remote_play.coin_topup_orders,
  remote_play.coin_lots,remote_play.coin_ledger,remote_play.pc_coin_rates,
  remote_play.stardesk_device_links FROM ani_api_runtime;

CREATE OR REPLACE FUNCTION private.remote_coin_expire_wallet(p_wallet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','pg_catalog'
AS $function$
DECLARE
  lot_row remote_play.coin_lots%ROWTYPE;
  new_balance numeric(18,8);
BEGIN
  FOR lot_row IN
    SELECT * FROM remote_play.coin_lots
    WHERE wallet_id=p_wallet_id AND remaining_coins>0 AND expires_at<=now()
    ORDER BY expires_at,created_at,id FOR UPDATE
  LOOP
    UPDATE remote_play.coin_lots SET remaining_coins=0 WHERE id=lot_row.id;
    SELECT COALESCE(sum(remaining_coins),0) INTO new_balance
      FROM remote_play.coin_lots WHERE wallet_id=p_wallet_id AND expires_at>now();
    INSERT INTO remote_play.coin_ledger(wallet_id,lot_id,event_type,amount_coins,balance_after,
      reference_type,reference_id,idempotency_key)
    VALUES(p_wallet_id,lot_row.id,'lot_expired',lot_row.remaining_coins,new_balance,
      'coin_lot',lot_row.id::text,'expire:'||lot_row.id::text)
    ON CONFLICT(idempotency_key) DO NOTHING;
  END LOOP;
  SELECT COALESCE(sum(remaining_coins),0) INTO new_balance
    FROM remote_play.coin_lots WHERE wallet_id=p_wallet_id AND expires_at>now();
  UPDATE remote_play.coin_wallets SET balance=new_balance,updated_at=now() WHERE id=p_wallet_id;
  RETURN new_balance;
END;
$function$;

REVOKE ALL ON FUNCTION private.remote_coin_expire_wallet(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.remote_coin_expire_wallet(uuid) FROM ani_api_runtime;

CREATE OR REPLACE FUNCTION api.remote_coin_wallet(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  v_balance numeric(18,8);
  v_lots jsonb;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  INSERT INTO remote_play.coin_wallets(rental_account_id)
  VALUES(c.rental_account_id)
  ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets
    WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  v_balance:=private.remote_coin_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',l.id,'original_coins',l.original_coins,'remaining_coins',l.remaining_coins,
    'expires_at',l.expires_at,'created_at',l.created_at)
    ORDER BY l.expires_at,l.created_at),'[]'::jsonb)
  INTO v_lots
  FROM remote_play.coin_lots l
  WHERE l.wallet_id=w.id AND l.remaining_coins>0 AND l.expires_at>now();
  RETURN jsonb_build_object('ok',true,'balance',v_balance,'lots',v_lots,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_coin_create_topup(
  p_session_token text,p_amount_rupiah bigint,p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  o remote_play.coin_topup_orders%ROWTYPE;
  current_balance numeric(18,8);
  v_coins numeric(18,8);
  v_after numeric(18,8);
  v_days integer;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  IF p_amount_rupiah<1000 OR p_amount_rupiah>10000000 OR p_amount_rupiah%1000<>0
     OR length(coalesce(p_idempotency_key,''))<8 OR length(p_idempotency_key)>128 THEN
    RAISE EXCEPTION 'REMOTE_COIN_TOPUP_INVALID';
  END IF;
  INSERT INTO remote_play.coin_wallets(rental_account_id)
  VALUES(c.rental_account_id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets
    WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  current_balance:=private.remote_coin_expire_wallet(w.id);
  v_coins:=round(p_amount_rupiah::numeric*60/8000,8);
  v_after:=current_balance+v_coins;
  v_days:=CASE
    WHEN v_after<300 THEN 3 WHEN v_after<600 THEN 7 WHEN v_after<900 THEN 10
    WHEN v_after<1200 THEN 14 WHEN v_after<1500 THEN 17 WHEN v_after<1800 THEN 21
    WHEN v_after<2100 THEN 24 WHEN v_after<2400 THEN 28 ELSE 30 END;
  INSERT INTO remote_play.coin_topup_orders(
    rental_account_id,amount_rupiah,coin_amount,expiry_days,idempotency_key
  ) VALUES(c.rental_account_id,p_amount_rupiah,v_coins,v_days,p_idempotency_key)
  ON CONFLICT(rental_account_id,idempotency_key) DO NOTHING
  RETURNING * INTO o;
  IF NOT FOUND THEN
    SELECT * INTO o FROM remote_play.coin_topup_orders
      WHERE rental_account_id=c.rental_account_id AND idempotency_key=p_idempotency_key;
  END IF;
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'amount_rupiah',o.amount_rupiah,
    'coin_amount',o.coin_amount,'expiry_days',o.expiry_days,'status',o.status,
    'expires_at',o.expires_at,'payment_method',o.payment_method,'wallet_balance',current_balance);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_coin_history(p_session_token text,p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  v_ledger jsonb;
  v_orders jsonb;
  v_balance numeric(18,8);
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  INSERT INTO remote_play.coin_wallets(rental_account_id)
  VALUES(c.rental_account_id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  v_balance:=private.remote_coin_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_ledger
  FROM (SELECT event_type,amount_coins,balance_after,reference_type,reference_id,created_at
    FROM remote_play.coin_ledger WHERE wallet_id=w.id ORDER BY created_at DESC LIMIT greatest(1,least(coalesce(p_limit,50),100))) x;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_orders
  FROM (SELECT id,amount_rupiah,coin_amount,expiry_days,status,created_at,approved_at,expires_at
    FROM remote_play.coin_topup_orders WHERE rental_account_id=c.rental_account_id
    ORDER BY created_at DESC LIMIT greatest(1,least(coalesce(p_limit,50),100))) x;
  RETURN jsonb_build_object('ok',true,'balance',v_balance,'ledger',v_ledger,'orders',v_orders);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_coin_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  v_balance numeric(18,8);
  v_enabled boolean;
  v_active remote_play.sessions%ROWTYPE;
  v_hosts jsonb;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO r FROM public.rental_accounts WHERE id=c.rental_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  SELECT enabled INTO v_enabled FROM remote_play.rental_permissions WHERE rental_account_id=r.id;
  INSERT INTO remote_play.coin_wallets(rental_account_id)
  VALUES(r.id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  v_balance:=private.remote_coin_expire_wallet(w.id);
  SELECT * INTO v_active FROM remote_play.sessions
    WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
    ORDER BY started_at DESC LIMIT 1;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'device_id',d.id,'client_id',d.client_id,'device_name',d.device_name,
    'online',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false),
    'available',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false)
      AND coalesce(hp.enabled,false)
      AND coalesce(rate.enabled,false)
      AND coalesce(link.enabled,false)
      AND NOT EXISTS(SELECT 1 FROM remote_play.sessions s
        WHERE s.device_id=d.id AND s.status IN ('starting','active') AND s.settled_at IS NULL)
      AND NOT EXISTS(SELECT 1 FROM public.rental_sessions rs
        WHERE rs.org_id=d.org_id AND rs.device_id=d.id AND rs.status IN ('active','paused')),
    'remote_play_enabled',coalesce(hp.enabled,false),
    'gpu_class',rate.gpu_class,'hourly_rupiah',rate.hourly_rupiah,
    'hourly_coins',rate.hourly_coins,'rate_configured',coalesce(rate.enabled,false),
    'stardesk_device_id',link.stardesk_device_id,'stardesk_linked',coalesce(link.enabled,false)
  ) ORDER BY d.device_name),'[]'::jsonb)
  INTO v_hosts
  FROM public.devices d
  LEFT JOIN remote_play.host_permissions hp ON hp.device_id=d.id AND hp.org_id=d.org_id
  LEFT JOIN remote_play.pc_coin_rates rate ON rate.device_id=d.id AND rate.org_id=d.org_id
  LEFT JOIN remote_play.stardesk_device_links link ON link.device_id=d.id AND link.org_id=d.org_id
  WHERE d.org_id=r.org_id;
  RETURN jsonb_build_object('ok',true,
    'rental_account',jsonb_build_object('id',r.id,'code',r.code,'category',r.category,
      'status',r.status,'expiry_at',r.expiry_at,'client_label',r.client_label),
    'wallet',jsonb_build_object('balance',v_balance),
    'remote_play_enabled',coalesce(v_enabled,false),
    'can_start',coalesce(v_enabled,false) AND v_balance>0
      AND r.status NOT IN ('disabled','deleted','inactive') AND v_active.id IS NULL,
    'active_session',CASE WHEN v_active.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',v_active.id,'device_id',v_active.device_id,'status',v_active.status) END,
    'hosts',v_hosts,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_topups(p_session_token text,p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  v_orders jsonb;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO v_orders
  FROM (
    SELECT o.id,o.rental_account_id,r.code,o.amount_rupiah,o.coin_amount,o.expiry_days,
      o.status,o.created_at,o.expires_at
    FROM remote_play.coin_topup_orders o
    JOIN public.rental_accounts r ON r.id=o.rental_account_id
    WHERE r.org_id=a.org_id AND o.status='pending'
    ORDER BY o.created_at DESC LIMIT greatest(1,least(coalesce(p_limit,100),300))
  ) x;
  RETURN jsonb_build_object('ok',true,'orders',v_orders);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_approve_topup(p_session_token text,p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  o remote_play.coin_topup_orders%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  lot_id uuid;
  v_balance numeric(18,8);
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO o FROM remote_play.coin_topup_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COIN_TOPUP_ORDER_NOT_FOUND'; END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE id=o.rental_account_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COIN_TOPUP_ORG_MISMATCH'; END IF;
  IF o.status='approved' THEN
    SELECT * INTO w FROM remote_play.coin_wallets WHERE rental_account_id=r.id;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'order_id',o.id,'status',o.status,'balance',coalesce(w.balance,0));
  END IF;
  IF o.status<>'pending' OR o.expires_at<=now() THEN
    RAISE EXCEPTION 'COIN_TOPUP_ORDER_NOT_PENDING';
  END IF;
  INSERT INTO remote_play.coin_wallets(rental_account_id)
    VALUES(r.id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  v_balance:=private.remote_coin_expire_wallet(w.id);
  INSERT INTO remote_play.coin_lots(wallet_id,source_order_id,original_coins,remaining_coins,expires_at)
  VALUES(w.id,o.id,o.coin_amount,o.coin_amount,now()+make_interval(days=>o.expiry_days))
  ON CONFLICT(source_order_id) DO NOTHING
  RETURNING id INTO lot_id;
  IF lot_id IS NULL THEN
    UPDATE remote_play.coin_topup_orders SET status='approved',approved_by=a.auth_user_id,
      approved_at=coalesce(approved_at,now()) WHERE id=o.id;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'order_id',o.id,'status','approved','balance',v_balance);
  END IF;
  v_balance:=v_balance+o.coin_amount;
  UPDATE remote_play.coin_wallets SET balance=v_balance,updated_at=now() WHERE id=w.id;
  INSERT INTO remote_play.coin_ledger(wallet_id,lot_id,event_type,amount_coins,balance_after,
    reference_type,reference_id,idempotency_key)
  VALUES(w.id,lot_id,'topup_credit',o.coin_amount,v_balance,'topup_order',o.id::text,'topup:'||o.id::text)
  ON CONFLICT(idempotency_key) DO NOTHING;
  UPDATE remote_play.coin_topup_orders SET status='approved',approved_by=a.auth_user_id,
    approved_at=now(),reviewed_by=a.auth_user_id,reviewed_at=now()
    WHERE id=o.id;
  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'coin_topup_approved',o.id::text,
    jsonb_build_object('rental_account_id',r.id,'amount_rupiah',o.amount_rupiah,'coin_amount',o.coin_amount));
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'status','approved',
    'coin_amount',o.coin_amount,'balance',v_balance,'lot_id',lot_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_reject_topup(
  p_session_token text,p_order_id uuid,p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  o remote_play.coin_topup_orders%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO o FROM remote_play.coin_topup_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COIN_TOPUP_ORDER_NOT_FOUND'; END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE id=o.rental_account_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'COIN_TOPUP_ORG_MISMATCH'; END IF;
  IF o.status='rejected' THEN RETURN jsonb_build_object('ok',true,'idempotent',true,'order_id',o.id,'status',o.status); END IF;
  IF o.status<>'pending' THEN RAISE EXCEPTION 'COIN_TOPUP_ORDER_NOT_PENDING'; END IF;
  UPDATE remote_play.coin_topup_orders SET status='rejected',
    rejection_reason=left(coalesce(nullif(btrim(p_reason),''),'Rejected by Owner'),180),
    reviewed_by=a.auth_user_id,reviewed_at=now()
  WHERE id=o.id;
  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'coin_topup_rejected',o.id::text,
    jsonb_build_object('rental_account_id',r.id,'reason',left(coalesce(nullif(btrim(p_reason),''),'Rejected by Owner'),180)));
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'status','rejected');
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_set_device_rate(
  p_session_token text,p_device_id uuid,p_gpu_class text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  v_class text:=regexp_replace(upper(btrim(coalesce(p_gpu_class,''))),'[[:space:]]+',' ','g');
  v_rupiah integer;
  v_coins numeric(12,8);
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  CASE v_class
    WHEN 'GTX 1050' THEN v_class:='GTX 1050';v_rupiah:=6000;v_coins:=45;
    WHEN 'GTX 1660' THEN v_class:='GTX 1660';v_rupiah:=6000;v_coins:=45;
    WHEN 'RTX 3060' THEN v_class:='RTX 3060';v_rupiah:=7000;v_coins:=52.5;
    WHEN 'RTX 5060' THEN v_class:='RTX 5060';v_rupiah:=8000;v_coins:=60;
    ELSE RAISE EXCEPTION 'COIN_GPU_CLASS_NOT_APPROVED';
  END CASE;
  INSERT INTO remote_play.pc_coin_rates(device_id,org_id,gpu_class,hourly_rupiah,hourly_coins,enabled,updated_by,updated_at)
  VALUES(d.id,d.org_id,v_class,v_rupiah,v_coins,true,a.auth_user_id,now())
  ON CONFLICT(device_id) DO UPDATE SET org_id=EXCLUDED.org_id,gpu_class=EXCLUDED.gpu_class,
    hourly_rupiah=EXCLUDED.hourly_rupiah,hourly_coins=EXCLUDED.hourly_coins,
    enabled=true,updated_by=a.auth_user_id,updated_at=now();
  RETURN jsonb_build_object('ok',true,'device_id',d.id,'gpu_class',v_class,
    'hourly_rupiah',v_rupiah,'hourly_coins',v_coins,'enabled',true);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_link_stardesk_device(
  p_session_token text,p_device_id uuid,p_stardesk_device_id text,p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  v_id text:=btrim(coalesce(p_stardesk_device_id,''));
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  IF length(v_id)<1 OR length(v_id)>180 OR p_enabled IS NULL THEN
    RAISE EXCEPTION 'STAR_DESK_DEVICE_LINK_INVALID';
  END IF;
  INSERT INTO remote_play.stardesk_device_links(device_id,org_id,stardesk_device_id,enabled,updated_by,updated_at)
  VALUES(d.id,d.org_id,v_id,p_enabled,a.auth_user_id,now())
  ON CONFLICT(device_id) DO UPDATE SET org_id=EXCLUDED.org_id,
    stardesk_device_id=EXCLUDED.stardesk_device_id,enabled=EXCLUDED.enabled,
    updated_by=a.auth_user_id,updated_at=now();
  RETURN jsonb_build_object('ok',true,'device_id',d.id,'stardesk_device_id',v_id,'enabled',p_enabled);
END;
$function$;

REVOKE ALL ON FUNCTION api.remote_coin_wallet(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_coin_create_topup(text,bigint,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_coin_history(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_coin_dashboard(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_topups(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_approve_topup(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_reject_topup(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_set_device_rate(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_link_stardesk_device(text,uuid,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.remote_coin_wallet(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_coin_create_topup(text,bigint,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_coin_history(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_coin_dashboard(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_topups(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_approve_topup(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_reject_topup(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_set_device_rate(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_link_stardesk_device(text,uuid,text,boolean) TO ani_api_runtime;

COMMIT;
