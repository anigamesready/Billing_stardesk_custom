-- Seed version-1 coin rows before migration 022 to prove one-time conversion.
-- Runs only in the disposable CI database after core/coin migrations 000-020.
DO $$
DECLARE
  login_result jsonb;
  org_id uuid;
  rental_id uuid;
  device_id uuid;
  v_wallet_id uuid;
  order_id uuid;
BEGIN
  login_result:=api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  org_id:=(login_result->>'org_id')::uuid;
  IF org_id IS NULL THEN RAISE EXCEPTION 'COIN_SCALE_SEED_OWNER_MISSING'; END IF;

  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status,client_label,expiry_at)
  VALUES(org_id,'COIN-SCALE-CI','reguler',123456,'active','Coin x100 migration fixture',now()+interval '30 days')
  RETURNING id INTO rental_id;

  INSERT INTO public.devices(org_id,client_id,device_name,status,last_seen_at)
  VALUES(org_id,'COIN-SCALE-CI-PC','Coin x100 Migration PC','online',now())
  RETURNING id INTO device_id;

  INSERT INTO remote_play.coin_wallets(rental_account_id,balance)
  VALUES(rental_id,75) RETURNING id INTO v_wallet_id;

  INSERT INTO remote_play.coin_topup_orders(
    rental_account_id,amount_rupiah,coin_amount,expiry_days,status,idempotency_key,
    approved_at,expires_at
  ) VALUES(
    rental_id,10000,75,3,'approved','coin-scale-seed-order-0001',now(),now()+interval '24 hours'
  ) RETURNING id INTO order_id;

  INSERT INTO remote_play.coin_lots(wallet_id,source_order_id,original_coins,remaining_coins,expires_at)
  VALUES(v_wallet_id,order_id,75,75,now()+interval '3 days');

  INSERT INTO remote_play.coin_ledger(
    wallet_id,lot_id,event_type,amount_coins,balance_after,reference_type,reference_id,idempotency_key
  )
  SELECT v_wallet_id,l.id,'topup_credit',75,75,'topup_order',order_id::text,'coin-scale-seed-ledger-0001'
  FROM remote_play.coin_lots l WHERE l.source_order_id=order_id;

  INSERT INTO remote_play.pc_coin_rates(
    device_id,org_id,gpu_class,hourly_rupiah,hourly_coins,enabled
  ) VALUES(device_id,org_id,'RTX 5060',8000,60,true);
END
$$;

SELECT 'PASS: seeded version-1 coin quantities before x100 migration' AS result;
