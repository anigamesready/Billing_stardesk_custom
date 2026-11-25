-- Assert migration 022 converted every pre-existing coin quantity exactly once.
DO $$
DECLARE
  rental_id uuid;
  wallet_balance numeric;
  stored_coin_amount numeric;
  lot_original numeric;
  lot_remaining numeric;
  ledger_amount numeric;
  ledger_balance numeric;
  rate_coins numeric;
  rupiah_amount bigint;
  remaining_seconds bigint;
  rental_status text;
  scale_value integer;
BEGIN
  SELECT coin_scale INTO scale_value FROM remote_play.coin_unit_config WHERE singleton IS TRUE;
  IF scale_value<>100 THEN RAISE EXCEPTION 'COIN_SCALE_CONFIG_NOT_100'; END IF;

  SELECT r.id,r.remaining_seconds,r.status
    INTO rental_id,remaining_seconds,rental_status
    FROM public.rental_accounts r WHERE r.code='COIN-SCALE-CI';
  IF rental_id IS NULL THEN RAISE EXCEPTION 'COIN_SCALE_FIXTURE_RENTAL_MISSING'; END IF;

  SELECT balance INTO wallet_balance FROM remote_play.coin_wallets WHERE rental_account_id=rental_id;
  SELECT amount_rupiah,coin_amount INTO rupiah_amount,stored_coin_amount
    FROM remote_play.coin_topup_orders WHERE rental_account_id=rental_id;
  SELECT l.original_coins,l.remaining_coins INTO lot_original,lot_remaining
    FROM remote_play.coin_lots l JOIN remote_play.coin_wallets w ON w.id=l.wallet_id
    WHERE w.rental_account_id=rental_id;
  SELECT l.amount_coins,l.balance_after INTO ledger_amount,ledger_balance
    FROM remote_play.coin_ledger l JOIN remote_play.coin_wallets w ON w.id=l.wallet_id
    WHERE w.rental_account_id=rental_id;
  SELECT hourly_coins INTO rate_coins FROM remote_play.pc_coin_rates
    WHERE device_id=(SELECT id FROM public.devices WHERE client_id='COIN-SCALE-CI-PC');

  IF wallet_balance<>7500 OR stored_coin_amount<>7500
     OR lot_original<>7500 OR lot_remaining<>7500
     OR ledger_amount<>7500 OR ledger_balance<>7500
     OR rate_coins<>6000 OR rupiah_amount<>10000 THEN
    RAISE EXCEPTION 'COIN_SCALE_MIGRATION_VALUE_MISMATCH';
  END IF;
  IF remaining_seconds<>123456 OR rental_status<>'active' THEN
    RAISE EXCEPTION 'COIN_SCALE_CHANGED_LEGACY_RENTAL_CORE';
  END IF;
END
$$;

SELECT 'PASS: wallet, order, lot, ledger and hourly rate converted once; Rupiah and legacy rental time preserved' AS result;
