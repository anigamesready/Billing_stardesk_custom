-- Android DB coin wallet / top-up / rates / StarDesk mapping smoke tests.
-- Requires tests 001-010 to have provisioned CI-OWNER and the baseline Remote Play migrations.
DO $$
DECLARE
  login_result jsonb;
  owner_token text;
  org_id uuid;
  device_id uuid;
  rental_id uuid;
  client_credential jsonb;
  client_login jsonb;
  activation_code text;
  client_token text;
  order_one jsonb;
  order_dup jsonb;
  order_two jsonb;
  reject_order jsonb;
  approve_one jsonb;
  approve_dup jsonb;
  wallet_result jsonb;
  dashboard jsonb;
  history_result jsonb;
  rate_result jsonb;
  link_result jsonb;
  order_id uuid;
  order_two_id uuid;
  rejected_id uuid;
  initial_remaining bigint;
BEGIN
  login_result:=api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  owner_token:=login_result->>'token';
  org_id:=(login_result->>'org_id')::uuid;
  IF coalesce(owner_token,'')='' OR org_id IS NULL THEN
    RAISE EXCEPTION 'COIN_TEST_OWNER_LOGIN_FAILED';
  END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status,last_seen_at)
  VALUES(org_id,'COIN-CI-DEVICE','PC RTX 5060 Coin CI','online',now())
  RETURNING id INTO device_id;
  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status,client_label,expiry_at)
  VALUES(org_id,'COIN-CI-EXPIRED','reguler',0,'expired','Coin Wallet Test',now()-interval '3 days')
  RETURNING id INTO rental_id;
  initial_remaining:=0;

  PERFORM api.admin_remote_play_set_host_permission(owner_token,device_id,true);
  PERFORM api.admin_remote_play_set_rental_permission(owner_token,rental_id,true);

  rate_result:=api.admin_remote_coin_set_device_rate(owner_token,device_id,'RTX 5060');
  IF rate_result->>'hourly_rupiah'<>'8000' OR (rate_result->>'hourly_coins')::numeric<>60 THEN
    RAISE EXCEPTION 'COIN_RATE_CONFIGURATION_WRONG';
  END IF;
  link_result:=api.admin_remote_coin_link_stardesk_device(owner_token,device_id,'SD-CI-DEVICE-5060',true);
  IF link_result->>'stardesk_device_id'<>'SD-CI-DEVICE-5060' THEN
    RAISE EXCEPTION 'STAR_DESK_DEVICE_LINK_FAILED';
  END IF;

  client_credential:=api.admin_remote_play_issue_client_credential(owner_token,rental_id);
  activation_code:=client_credential->>'activation_code';
  client_login:=api.remote_play_login('COIN-CI-EXPIRED',activation_code,'coin-ci-android-install');
  client_token:=client_login->>'access_token';
  IF length(coalesce(client_token,''))<>64 THEN
    RAISE EXCEPTION 'COIN_TEST_REMOTE_CLIENT_LOGIN_FAILED';
  END IF;

  wallet_result:=api.remote_coin_wallet(client_token);
  IF coalesce((wallet_result->>'balance')::numeric,-1)<>0 THEN
    RAISE EXCEPTION 'COIN_WALLET_INITIAL_BALANCE_NOT_ZERO';
  END IF;

  order_one:=api.remote_coin_create_topup(client_token,10000,'coin-ci-idempotency-0001');
  order_dup:=api.remote_coin_create_topup(client_token,10000,'coin-ci-idempotency-0001');
  order_id:=(order_one->>'order_id')::uuid;
  IF order_id IS NULL OR (order_dup->>'order_id')::uuid<>order_id
     OR (order_one->>'coin_amount')::numeric<>75
     OR (order_one->>'expiry_days')::integer<>3
     OR order_one->>'status'<>'pending' THEN
    RAISE EXCEPTION 'COIN_TOPUP_CREATE_OR_IDEMPOTENCY_FAILED';
  END IF;

  dashboard:=api.admin_remote_coin_topups(owner_token,100);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(dashboard->'orders') x WHERE x->>'id'=order_id::text) THEN
    RAISE EXCEPTION 'COIN_TOPUP_PENDING_ADMIN_LIST_MISSING';
  END IF;

  approve_one:=api.admin_remote_coin_approve_topup(owner_token,order_id);
  approve_dup:=api.admin_remote_coin_approve_topup(owner_token,order_id);
  IF approve_one->>'status'<>'approved'
     OR coalesce((approve_dup->>'idempotent')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'COIN_TOPUP_APPROVAL_IDEMPOTENCY_FAILED';
  END IF;

  wallet_result:=api.remote_coin_wallet(client_token);
  IF (wallet_result->>'balance')::numeric<>75
     OR jsonb_array_length(wallet_result->'lots')<>1 THEN
    RAISE EXCEPTION 'COIN_TOPUP_CREDIT_OR_LOT_FAILED';
  END IF;

  -- New-lot expiry tier uses the total valid balance after the credit.
  order_two:=api.remote_coin_create_topup(client_token,40000,'coin-ci-idempotency-0002');
  order_two_id:=(order_two->>'order_id')::uuid;
  IF (order_two->>'coin_amount')::numeric<>300 OR (order_two->>'expiry_days')::integer<>7 THEN
    RAISE EXCEPTION 'COIN_EXPIRY_TIER_SNAPSHOT_FAILED';
  END IF;
  PERFORM api.admin_remote_coin_approve_topup(owner_token,order_two_id);
  wallet_result:=api.remote_coin_wallet(client_token);
  IF (wallet_result->>'balance')::numeric<>375 OR jsonb_array_length(wallet_result->'lots')<>2 THEN
    RAISE EXCEPTION 'COIN_SECOND_TOPUP_FAILED';
  END IF;

  -- Rejected orders must not credit coins; repeating the rejection is idempotent.
  reject_order:=api.remote_coin_create_topup(client_token,1000,'coin-ci-idempotency-0003');
  rejected_id:=(reject_order->>'order_id')::uuid;
  PERFORM api.admin_remote_coin_reject_topup(owner_token,rejected_id,'CI rejection test');
  reject_order:=api.admin_remote_coin_reject_topup(owner_token,rejected_id,'duplicate');
  IF reject_order->>'status'<>'rejected'
     OR coalesce((reject_order->>'idempotent')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'COIN_TOPUP_REJECTION_IDEMPOTENCY_FAILED';
  END IF;
  wallet_result:=api.remote_coin_wallet(client_token);
  IF (wallet_result->>'balance')::numeric<>375 THEN
    RAISE EXCEPTION 'COIN_REJECTED_ORDER_CHANGED_WALLET';
  END IF;

  history_result:=api.remote_coin_history(client_token,50);
  IF jsonb_array_length(history_result->'ledger')<>2
     OR jsonb_array_length(history_result->'orders')<>3 THEN
    RAISE EXCEPTION 'COIN_WALLET_HISTORY_INVALID';
  END IF;

  -- Expired lots are removed from spendable balance and recorded once.
  UPDATE remote_play.coin_lots
  SET expires_at=now()-interval '1 second'
  WHERE source_order_id=order_id;
  wallet_result:=api.remote_coin_wallet(client_token);
  IF (wallet_result->>'balance')::numeric<>300 THEN
    RAISE EXCEPTION 'COIN_EXPIRED_LOT_REMAINS_SPENDABLE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.coin_ledger
      WHERE lot_id=(SELECT id FROM remote_play.coin_lots WHERE source_order_id=order_id)
        AND event_type='lot_expired') THEN
    RAISE EXCEPTION 'COIN_EXPIRED_LOT_LEDGER_EVENT_MISSING';
  END IF;

  dashboard:=api.remote_coin_dashboard(client_token);
  IF dashboard->>'can_start'<>'true'
     OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(dashboard->'hosts') h
       WHERE h->>'device_id'=device_id::text
         AND h->>'online'='true'
         AND h->>'available'='true'
         AND h->>'rate_configured'='true'
         AND h->>'gpu_class'='RTX 5060'
         AND (h->>'hourly_coins')::numeric=60
         AND h->>'stardesk_linked'='true'
         AND h->>'stardesk_device_id'='SD-CI-DEVICE-5060') THEN
    RAISE EXCEPTION 'COIN_DASHBOARD_OR_STAR_DESK_MAPPING_INVALID';
  END IF;

  IF (SELECT remaining_seconds FROM public.rental_accounts WHERE id=rental_id)<>initial_remaining
     OR (SELECT status FROM public.rental_accounts WHERE id=rental_id)<>'expired' THEN
    RAISE EXCEPTION 'COIN_WALLET_MUTATED_LEGACY_RENTAL_BALANCE_OR_STATUS';
  END IF;
  IF has_table_privilege('ani_api_runtime','remote_play.coin_wallets','SELECT')
     OR has_table_privilege('ani_api_runtime','remote_play.coin_lots','SELECT')
     OR has_table_privilege('ani_api_runtime','remote_play.coin_ledger','SELECT') THEN
    RAISE EXCEPTION 'COIN_WALLET_TABLE_LEAKED_TO_RUNTIME_ROLE';
  END IF;
  IF NOT has_function_privilege('ani_api_runtime','api.remote_coin_wallet(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.remote_coin_create_topup(text,bigint,text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.admin_remote_coin_approve_topup(text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'COIN_RPC_RUNTIME_GRANTS_MISSING';
  END IF;
END;
$$;

SELECT 'PASS: Android DB coin wallet, QRIS top-up idempotency, Owner approval/rejection, coin-lot expiry, GPU rates, StarDesk mapping and legacy rental isolation' AS result;
