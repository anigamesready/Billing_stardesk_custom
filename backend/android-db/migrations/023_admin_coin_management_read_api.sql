-- StarDesk Android DB: Admin read APIs for complete Coin Management screens.
-- Additive only: no legacy rental, Remote Play session, or billing settlement logic is changed.
BEGIN;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_overview(
  p_session_token text,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  v_orders jsonb;
  v_devices jsonb;
  v_rentals jsonb;
  v_summary jsonb;
  row_limit integer := greatest(1,least(200,coalesce(p_limit,100)));
BEGIN
  a:=private.remote_play_require_admin(p_session_token);

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
  INTO v_orders
  FROM (
    SELECT o.id,o.rental_account_id,r.code AS rental_code,
      r.client_label,o.amount_rupiah,o.coin_amount,o.expiry_days,
      o.payment_method,o.status,o.idempotency_key,
      o.created_at,o.expires_at,o.approved_at,o.reviewed_at,
      o.rejection_reason
    FROM remote_play.coin_topup_orders o
    JOIN public.rental_accounts r ON r.id=o.rental_account_id
    WHERE r.org_id=a.org_id
    ORDER BY o.created_at DESC
    LIMIT row_limit
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.device_name,x.client_id),'[]'::jsonb)
  INTO v_devices
  FROM (
    SELECT d.id AS device_id,d.client_id,d.device_name,d.status,d.last_seen_at,
      rate.gpu_class,rate.hourly_rupiah,rate.hourly_coins,
      coalesce(rate.enabled,false) AS rate_enabled,
      link.stardesk_device_id,
      coalesce(link.enabled,false) AS stardesk_link_enabled,
      coalesce(hp.enabled,false) AS remote_play_enabled
    FROM public.devices d
    LEFT JOIN remote_play.pc_coin_rates rate
      ON rate.device_id=d.id AND rate.org_id=d.org_id
    LEFT JOIN remote_play.stardesk_device_links link
      ON link.device_id=d.id AND link.org_id=d.org_id
    LEFT JOIN remote_play.host_permissions hp
      ON hp.device_id=d.id AND hp.org_id=d.org_id
    WHERE d.org_id=a.org_id
  ) x;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id',r.id,'code',r.code,'client_label',r.client_label,
      'category',r.category,'status',r.status,'expiry_at',r.expiry_at
    ) ORDER BY r.code),'[]'::jsonb)
  INTO v_rentals
  FROM public.rental_accounts r
  WHERE r.org_id=a.org_id AND upper(r.code)<>'__TEST10__';

  SELECT jsonb_build_object(
    'pending_orders',count(*) FILTER (WHERE o.status='pending'),
    'pending_amount_rupiah',coalesce(sum(o.amount_rupiah) FILTER (WHERE o.status='pending'),0),
    'approved_orders',count(*) FILTER (WHERE o.status='approved'),
    'rejected_orders',count(*) FILTER (WHERE o.status='rejected'),
    'expired_orders',count(*) FILTER (WHERE o.status='expired'),
    'wallet_accounts',(SELECT count(*) FROM remote_play.coin_wallets w
      JOIN public.rental_accounts r ON r.id=w.rental_account_id WHERE r.org_id=a.org_id)
  )
  INTO v_summary
  FROM remote_play.coin_topup_orders o
  JOIN public.rental_accounts r ON r.id=o.rental_account_id
  WHERE r.org_id=a.org_id;

  RETURN jsonb_build_object(
    'ok',true,
    'summary',v_summary,
    'orders',v_orders,
    'devices',v_devices,
    'rentals',v_rentals,
    'coin_unit_scale',coalesce((SELECT coin_scale FROM remote_play.coin_unit_config WHERE singleton IS TRUE),1),
    'server_time',now()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_coin_wallet(
  p_session_token text,
  p_rental_account_id uuid,
  p_history_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  w remote_play.coin_wallets%ROWTYPE;
  v_balance numeric(18,8);
  v_lots jsonb;
  v_ledger jsonb;
  v_orders jsonb;
  row_limit integer := greatest(1,least(100,coalesce(p_history_limit,50)));
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id=p_rental_account_id AND org_id=a.org_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  INSERT INTO remote_play.coin_wallets(rental_account_id)
  VALUES(r.id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM remote_play.coin_wallets
  WHERE rental_account_id=r.id FOR UPDATE;

  -- Expiry is reconciled on this wallet only; other accounts are never touched.
  v_balance:=private.remote_coin_expire_wallet(w.id);

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.expires_at,x.created_at),'[]'::jsonb)
  INTO v_lots
  FROM (
    SELECT id,source_order_id,original_coins,remaining_coins,expires_at,created_at,
      (expires_at<=now()) AS expired
    FROM remote_play.coin_lots
    WHERE wallet_id=w.id
    ORDER BY expires_at,created_at,id
    LIMIT row_limit
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
  INTO v_ledger
  FROM (
    SELECT event_type,amount_coins,balance_after,reference_type,reference_id,created_at
    FROM remote_play.coin_ledger
    WHERE wallet_id=w.id
    ORDER BY created_at DESC
    LIMIT row_limit
  ) x;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
  INTO v_orders
  FROM (
    SELECT id,amount_rupiah,coin_amount,expiry_days,payment_method,status,
      created_at,expires_at,approved_at,reviewed_at,rejection_reason
    FROM remote_play.coin_topup_orders
    WHERE rental_account_id=r.id
    ORDER BY created_at DESC
    LIMIT row_limit
  ) x;

  RETURN jsonb_build_object(
    'ok',true,
    'rental_account',jsonb_build_object(
      'id',r.id,'code',r.code,'client_label',r.client_label,
      'status',r.status,'expiry_at',r.expiry_at
    ),
    'wallet',jsonb_build_object('id',w.id,'balance',v_balance,'updated_at',w.updated_at),
    'lots',v_lots,
    'ledger',v_ledger,
    'orders',v_orders,
    'coin_unit_scale',coalesce((SELECT coin_scale FROM remote_play.coin_unit_config WHERE singleton IS TRUE),1),
    'server_time',now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.admin_remote_coin_overview(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_coin_wallet(text,uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_overview(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_coin_wallet(text,uuid,integer) TO ani_api_runtime;

COMMIT;
