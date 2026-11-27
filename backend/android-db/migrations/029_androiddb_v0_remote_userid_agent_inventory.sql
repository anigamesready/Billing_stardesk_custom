-- StarDesk Custom 029: User ID-only Remote login and Agent-owned PC inventory.
-- Applies after isolated StarDesk migrations 027/028. Legacy public.devices is not queried.
BEGIN;

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
        'client_logged_in',EXISTS(SELECT 1 FROM androiddb_v0.client_sessions cs
          WHERE cs.rental_account_id=r.id AND cs.revoked_at IS NULL AND cs.expires_at>now())) AS item
    FROM androiddb_v0.rental_accounts r
    WHERE r.org_id=a.org_id
    ORDER BY r.code LIMIT lim
  ) q;

  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.device_name,q.client_id),'[]'::jsonb) INTO hosts
  FROM (
    SELECT pc.display_name AS device_name,d.computer_name AS client_id,
      jsonb_build_object('device_id',d.id,'device_name',pc.display_name,'client_id',d.computer_name,
        'device_online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
        'host_permission_enabled',pc.enabled,
        'host_agent_online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
        'host_agent_ready',false,
        'agent_version',d.agent_version,'host_last_seen_at',d.last_heartbeat_at,
        'gpu_class',pc.gpu_class,'hourly_rupiah',pc.hourly_rupiah,
        'hourly_coins',pc.hourly_coin_units::numeric/100,
        'rate_enabled',pc.enabled,
        'stardesk_device_id',NULL,'stardesk_link_enabled',false,
        'active_session',false
      ) AS item
    FROM androiddb_v0.agent_devices d
    JOIN androiddb_v0.rental_pcs pc ON pc.id=d.rental_pc_id
    WHERE d.org_id=a.org_id AND d.revoked_at IS NULL
  ) q;

  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC),'[]'::jsonb) INTO orders
  FROM (
    SELECT id,rental_account_id,amount_rupiah,coin_amount,expiry_days,status,created_at,expires_at
    FROM androiddb_v0.coin_topup_orders
    WHERE rental_account_id IN (SELECT id FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id)
    ORDER BY created_at DESC LIMIT lim
  ) o;

  SELECT jsonb_build_object(
    'rental_accounts',(SELECT count(*) FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id AND status='active'),
    'pending_orders',(SELECT count(*) FROM androiddb_v0.coin_topup_orders o JOIN androiddb_v0.rental_accounts r ON r.id=o.rental_account_id WHERE r.org_id=a.org_id AND o.status='pending'),
    'wallet_accounts',(SELECT count(*) FROM androiddb_v0.coin_wallets w JOIN androiddb_v0.rental_accounts r ON r.id=w.rental_account_id WHERE r.org_id=a.org_id)
  ) INTO summary;

  RETURN jsonb_build_object('ok',true,'rental_accounts',rentals,'host_devices',hosts,'orders',orders,
    'summary',summary,'coin_unit_scale',unit_scale,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_login(
  p_rental_code text,p_client_install_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE
  r androiddb_v0.rental_accounts%ROWTYPE;
  raw_token text:=encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh text:=encode(extensions.gen_random_bytes(32),'hex');
  sid uuid;
BEGIN
  IF length(coalesce(btrim(p_rental_code),'')) NOT BETWEEN 3 AND 40
    OR length(coalesce(btrim(p_client_install_id),'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  SELECT * INTO r
  FROM androiddb_v0.rental_accounts
  WHERE upper(code)=upper(btrim(p_rental_code))
  FOR UPDATE;

  IF NOT FOUND OR r.status<>'active' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  UPDATE androiddb_v0.client_sessions
  SET revoked_at=coalesce(revoked_at,now())
  WHERE rental_account_id=r.id AND revoked_at IS NULL;

  INSERT INTO androiddb_v0.client_sessions(
    rental_account_id,token_hash,refresh_token_hash,client_install_id,
    expires_at,refresh_expires_at
  )
  VALUES(
    r.id,
    encode(extensions.digest(raw_token,'sha256'),'hex'),
    encode(extensions.digest(raw_refresh,'sha256'),'hex'),
    left(btrim(p_client_install_id),128),
    now()+interval '12 hours',
    now()+interval '30 days'
  )
  RETURNING id INTO sid;

  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(r.org_id,'client',sid::text,'client_login_userid_only',r.id::text,
    jsonb_build_object('client_install_id',left(btrim(p_client_install_id),128)));

  RETURN jsonb_build_object(
    'ok',true,'access_token',raw_token,'refresh_token',raw_refresh,
    'token_type','bearer','expires_at',now()+interval '12 hours',
    'refresh_expires_at',now()+interval '30 days','client_session_id',sid
  );
END;
$function$;

DROP FUNCTION IF EXISTS api.androiddb_v0_admin_issue_activation(text,uuid);
DROP FUNCTION IF EXISTS api.androiddb_v0_remote_login(text,text,text);
DROP TABLE IF EXISTS androiddb_v0.client_credentials;

REVOKE ALL ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) TO stardesk_v0_runtime;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text) TO stardesk_v0_runtime;

COMMIT;
