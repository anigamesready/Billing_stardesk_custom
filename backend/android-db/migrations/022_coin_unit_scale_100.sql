-- StarDesk Android DB: one-time conversion to 100 display/value units per legacy coin.
-- Additive and idempotent. Historical migration 020 is intentionally immutable.
-- This migration scales only remote_play coin quantities; rupiah and rental-time core remain unchanged.
BEGIN;

CREATE TABLE IF NOT EXISTS remote_play.coin_unit_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton IS TRUE),
  coin_scale integer NOT NULL CHECK (coin_scale IN (1,100)),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO remote_play.coin_unit_config(singleton,coin_scale)
VALUES(true,1) ON CONFLICT(singleton) DO NOTHING;
REVOKE ALL ON TABLE remote_play.coin_unit_config FROM PUBLIC,ani_api_runtime;

DO $coin_scale_migration$
DECLARE
  current_scale integer;
BEGIN
  SELECT coin_scale INTO current_scale
  FROM remote_play.coin_unit_config
  WHERE singleton IS TRUE
  FOR UPDATE;

  IF current_scale = 1 THEN
    UPDATE remote_play.coin_wallets
      SET balance=balance*100,updated_at=now();
    UPDATE remote_play.coin_topup_orders
      SET coin_amount=coin_amount*100;
    UPDATE remote_play.coin_lots
      SET original_coins=original_coins*100,
          remaining_coins=remaining_coins*100;
    UPDATE remote_play.coin_ledger
      SET amount_coins=amount_coins*100,
          balance_after=balance_after*100;
    UPDATE remote_play.pc_coin_rates
      SET hourly_coins=hourly_coins*100,updated_at=now();

    UPDATE remote_play.coin_unit_config
      SET coin_scale=100,updated_at=now()
      WHERE singleton IS TRUE;
  ELSIF current_scale <> 100 THEN
    RAISE EXCEPTION 'COIN_UNIT_SCALE_UNSUPPORTED:%',current_scale;
  END IF;
END
$coin_scale_migration$;



-- New top-ups and Owner GPU rate updates use the same x100 unit system.
-- Existing rupiah prices, order IDs, lot expiries and ledger references are retained.
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
  v_coins:=round(p_amount_rupiah::numeric*6000/8000,8);
  v_after:=current_balance+v_coins;
  v_days:=CASE
    WHEN v_after<30000 THEN 3 WHEN v_after<60000 THEN 7 WHEN v_after<90000 THEN 10
    WHEN v_after<120000 THEN 14 WHEN v_after<150000 THEN 17 WHEN v_after<180000 THEN 21
    WHEN v_after<210000 THEN 24 WHEN v_after<240000 THEN 28 ELSE 30 END;
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
    WHEN 'GTX 1050' THEN v_class:='GTX 1050';v_rupiah:=6000;v_coins:=4500;
    WHEN 'GTX 1660' THEN v_class:='GTX 1660';v_rupiah:=6000;v_coins:=45;
    WHEN 'RTX 3060' THEN v_class:='RTX 3060';v_rupiah:=7000;v_coins:=5250;
    WHEN 'RTX 5060' THEN v_class:='RTX 5060';v_rupiah:=8000;v_coins:=6000;
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

COMMIT;
