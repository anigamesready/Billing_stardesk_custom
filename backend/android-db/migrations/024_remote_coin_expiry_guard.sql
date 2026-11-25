-- Additive safety guard for the StarDesk Coin dashboard.
-- The client UI is not an authorization boundary: the database must reject
-- expired/inactive rentals before any future Coin-session request is accepted.
BEGIN;

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
    'can_start',
      coalesce(v_enabled,false)
      AND v_balance>0
      AND coalesce(r.status,'') NOT IN ('disabled','deleted','inactive','expired')
      AND r.expiry_at IS NOT NULL
      AND r.expiry_at>clock_timestamp()
      AND v_active.id IS NULL,
    'active_session',CASE WHEN v_active.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',v_active.id,'device_id',v_active.device_id,'status',v_active.status) END,
    'hosts',v_hosts,'server_time',clock_timestamp());
END;
$function$;

COMMENT ON FUNCTION api.remote_coin_dashboard(text)
  IS 'ani_remote_coin_expiry_guard_v1';

COMMIT;
