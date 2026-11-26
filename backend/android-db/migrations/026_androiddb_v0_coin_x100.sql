-- StarDesk Android DB v0: convert the active Admin/Remote Coin domain to x100 units.
-- Rp 8,000 = 6,000 AniCoin; rupiah prices and economic value remain unchanged.
-- This migration applies only to androiddb_v0. Older remote_play has its own 022 migration.
-- Existing wallet/order/lot/ledger/session/rate values are converted once and atomically.
BEGIN;

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_unit_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton IS TRUE),
  coin_scale integer NOT NULL CHECK (coin_scale IN (1,100)),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO androiddb_v0.coin_unit_config(singleton,coin_scale)
VALUES (true,1)
ON CONFLICT (singleton) DO NOTHING;

REVOKE ALL ON TABLE androiddb_v0.coin_unit_config FROM PUBLIC,ani_api_runtime;

DO $coin_x100_migration$
DECLARE
  current_scale integer;
BEGIN
  SELECT coin_scale INTO current_scale
  FROM androiddb_v0.coin_unit_config
  WHERE singleton IS TRUE
  FOR UPDATE;

  IF current_scale = 1 THEN
    UPDATE androiddb_v0.coin_wallets
      SET balance=balance*100,updated_at=now();
    UPDATE androiddb_v0.coin_topup_orders
      SET coin_amount=coin_amount*100;
    UPDATE androiddb_v0.coin_lots
      SET original_coins=original_coins*100,
          remaining_coins=remaining_coins*100;
    UPDATE androiddb_v0.coin_ledger
      SET amount_coins=amount_coins*100,
          balance_after=balance_after*100;
    UPDATE androiddb_v0.sessions
      SET reserved_coins=reserved_coins*100,
          debited_coins=debited_coins*100;
    UPDATE androiddb_v0.pc_coin_rates
      SET hourly_coins=hourly_coins*100,updated_at=now();

    UPDATE androiddb_v0.coin_unit_config
      SET coin_scale=100,updated_at=now()
      WHERE singleton IS TRUE;
  ELSIF current_scale <> 100 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_COIN_SCALE_UNSUPPORTED:%',current_scale;
  END IF;
END
$coin_x100_migration$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_dashboard(
  p_session_token text,p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  lim integer:=greatest(1,least(200,coalesce(p_limit,100)));
  rentals jsonb; hosts jsonb; orders jsonb; summary jsonb; unit_scale integer;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.code),'[]'::jsonb) INTO rentals
  FROM (
    SELECT r.code,
      jsonb_build_object('id',r.id,'code',r.code,'client_label',r.client_label,'status',r.status,
        'created_at',r.created_at,
        'coin_balance',coalesce((SELECT sum(l.remaining_coins) FROM androiddb_v0.coin_wallets w
          JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
          WHERE w.rental_account_id=r.id AND l.expires_at>now()),0),
        'activation_issued',EXISTS(SELECT 1 FROM androiddb_v0.client_credentials c
          WHERE c.rental_account_id=r.id AND c.revoked_at IS NULL),
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
    'summary',summary,'coin_unit_scale',unit_scale,'server_time',now());
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
  v_balance numeric(18,8); v_lots jsonb; v_ledger jsonb; v_orders jsonb; unit_scale integer;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
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
    'lots',v_lots,'ledger',v_ledger,'orders',v_orders,'coin_unit_scale',unit_scale,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_set_device_rate(
  p_session_token text,p_device_id uuid,p_gpu_class text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; device_row public.devices%ROWTYPE;
  rupiah integer; coins numeric(12,8); unit_scale integer;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  SELECT * INTO device_row FROM public.devices WHERE id=p_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  CASE p_gpu_class
    WHEN 'GTX 1050' THEN rupiah:=6000; coins:=45*unit_scale;
    WHEN 'GTX 1660' THEN rupiah:=6000; coins:=45*unit_scale;
    WHEN 'RTX 3060' THEN rupiah:=7000; coins:=52.5*unit_scale;
    WHEN 'RTX 5060' THEN rupiah:=8000; coins:=60*unit_scale;
    ELSE RAISE EXCEPTION 'ANDROIDDB_V0_GPU_CLASS_INVALID';
  END CASE;
  INSERT INTO androiddb_v0.pc_coin_rates(device_id,org_id,gpu_class,hourly_rupiah,hourly_coins,enabled,updated_by,updated_at)
  VALUES(p_device_id,a.org_id,p_gpu_class,rupiah,coins,true,a.auth_user_id,now())
  ON CONFLICT(device_id) DO UPDATE SET gpu_class=EXCLUDED.gpu_class,hourly_rupiah=EXCLUDED.hourly_rupiah,
    hourly_coins=EXCLUDED.hourly_coins,enabled=true,updated_by=a.auth_user_id,updated_at=now();
  RETURN jsonb_build_object('ok',true,'device_id',p_device_id,'gpu_class',p_gpu_class,'hourly_rupiah',rupiah,'hourly_coins',coins);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_coin_wallet(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; w androiddb_v0.coin_wallets%ROWTYPE;
  bal numeric(18,8); lots jsonb; unit_scale integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(c.rental_account_id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'original_coins',original_coins,
    'remaining_coins',remaining_coins,'expires_at',expires_at,'created_at',created_at)
    ORDER BY expires_at,created_at),'[]'::jsonb) INTO lots
  FROM androiddb_v0.coin_lots WHERE wallet_id=w.id AND remaining_coins>0 AND expires_at>now();
  RETURN jsonb_build_object('ok',true,'balance',bal,'lots',lots,'coin_unit_scale',unit_scale,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_coin_history(p_session_token text,p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; w androiddb_v0.coin_wallets%ROWTYPE;
  led jsonb; ord jsonb; bal numeric(18,8); unit_scale integer; lim integer:=greatest(1,least(100,coalesce(p_limit,50)));
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(c.rental_account_id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=c.rental_account_id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO led
  FROM (SELECT event_type,amount_coins,balance_after,reference_type,reference_id,created_at
    FROM androiddb_v0.coin_ledger WHERE wallet_id=w.id ORDER BY created_at DESC LIMIT lim) x;
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO ord
  FROM (SELECT id,amount_rupiah,coin_amount,expiry_days,status,created_at,approved_at,expires_at
    FROM androiddb_v0.coin_topup_orders WHERE rental_account_id=c.rental_account_id ORDER BY created_at DESC LIMIT lim) x;
  RETURN jsonb_build_object('ok',true,'balance',bal,'ledger',led,'orders',ord,'coin_unit_scale',unit_scale);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE; bal numeric(18,8); hosts jsonb; active boolean; unit_scale integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
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
    'coin_unit_scale',unit_scale,'server_time',now());
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
  current_balance numeric(18,8); coins numeric(18,8); projected numeric(18,8); days integer; unit_scale integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id;
  IF p_amount_rupiah<1000 OR p_amount_rupiah>10000000 OR p_amount_rupiah%1000<>0
    OR length(coalesce(p_idempotency_key,'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_TOPUP_INVALID';
  END IF;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  current_balance:=private.androiddb_v0_expire_wallet(w.id);
  coins:=round(p_amount_rupiah::numeric*60*unit_scale/8000,8);
  projected:=current_balance+coins;
  days:=CASE WHEN projected<300*unit_scale THEN 3 WHEN projected<600*unit_scale THEN 7 WHEN projected<900*unit_scale THEN 10
    WHEN projected<1200*unit_scale THEN 14 WHEN projected<1500*unit_scale THEN 17 WHEN projected<1800*unit_scale THEN 21
    WHEN projected<2100*unit_scale THEN 24 WHEN projected<2400*unit_scale THEN 28 ELSE 30 END;
  INSERT INTO androiddb_v0.coin_topup_orders(rental_account_id,amount_rupiah,coin_amount,expiry_days,idempotency_key)
  VALUES(r.id,p_amount_rupiah,coins,days,p_idempotency_key)
  ON CONFLICT(rental_account_id,idempotency_key) DO NOTHING
  RETURNING * INTO o;
  IF NOT FOUND THEN
    SELECT * INTO o FROM androiddb_v0.coin_topup_orders
    WHERE rental_account_id=r.id AND idempotency_key=p_idempotency_key;
    IF o.id IS NULL OR o.amount_rupiah<>p_amount_rupiah THEN
      RAISE EXCEPTION 'ANDROIDDB_V0_IDEMPOTENCY_CONFLICT';
    END IF;
  END IF;
  RETURN jsonb_build_object('ok',true,'order_id',o.id,'amount_rupiah',o.amount_rupiah,'coin_amount',o.coin_amount,
    'expiry_days',o.expiry_days,'status',o.status,'expires_at',o.expires_at,'payment_method',o.payment_method,
    'wallet_balance',current_balance,'coin_unit_scale',unit_scale);
END;
$function$;


COMMIT;
