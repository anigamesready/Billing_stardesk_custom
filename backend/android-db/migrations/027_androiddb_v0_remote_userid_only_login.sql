-- StarDesk Android DB v0: User ID-only renter login.
-- Removes Admin-issued Remote activation codes from the renter authentication path.
-- Windows Host Agent enrollment remains a separate, independent flow.
-- Existing valid client_sessions are preserved until the next login/revocation.

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
    UPDATE androiddb_v0.client_sessions SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
  END IF;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'rental_status_changed',r.id::text,jsonb_build_object('enabled',p_enabled));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'status',r.status);
END;
$function$;


-- Remove the old Admin-issued activation entry point and old three-argument login.
DROP FUNCTION IF EXISTS api.androiddb_v0_admin_issue_activation(text,uuid);
DROP FUNCTION IF EXISTS api.androiddb_v0_remote_login(text,text,text);

-- Activation hashes have no further use after User ID-only login.
DROP TABLE IF EXISTS androiddb_v0.client_credentials;

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

  -- User ID is the only renter-entered login value. The installation ID is
  -- generated inside the Android app and is not an Admin-issued approval code.
  SELECT * INTO r
  FROM androiddb_v0.rental_accounts
  WHERE upper(code)=upper(btrim(p_rental_code))
  FOR UPDATE;

  IF NOT FOUND OR r.status<>'active' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  -- Keep one active Remote installation/session per rental account.
  -- Logging in on this device/session revokes the previous installation.
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
  VALUES(
    r.org_id,'client',sid::text,'client_login_userid_only',r.id::text,
    jsonb_build_object('client_install_id',left(btrim(p_client_install_id),128))
  );

  RETURN jsonb_build_object(
    'ok',true,'access_token',raw_token,'refresh_token',raw_refresh,
    'token_type','bearer','expires_at',now()+interval '12 hours',
    'refresh_expires_at',now()+interval '30 days','client_session_id',sid
  );
END;
$function$;


REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text) TO ani_api_runtime;

COMMIT;
