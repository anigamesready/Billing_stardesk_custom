-- Admin Coin Management overview and per-rental wallet detail API.
-- Runs after core, Remote Play, coin wallet and x100 coin unit migrations.
DO $$
DECLARE
  login_result jsonb;
  overview jsonb;
  detail jsonb;
  owner_token text;
  org_id uuid;
  device_id uuid;
  rental_id uuid;
  wallet_id uuid;
  lot_id uuid;
  order_id uuid;
BEGIN
  login_result:=api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  owner_token:=login_result->>'token';
  org_id:=(login_result->>'org_id')::uuid;
  IF coalesce(owner_token,'')='' OR org_id IS NULL THEN
    RAISE EXCEPTION 'COIN_ADMIN_TEST_OWNER_LOGIN_FAILED';
  END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status,last_seen_at)
  VALUES(org_id,'COIN-ADMIN-OVERVIEW-PC','PC RTX 5060 Admin Coin Overview','online',now())
  RETURNING id INTO device_id;

  INSERT INTO public.rental_accounts(
    org_id,code,category,remaining_seconds,status,client_label,expiry_at
  )
  VALUES(org_id,'COIN-ADMIN-OVERVIEW','reguler',0,'expired',
    'Admin Coin Overview Test',now()-interval '1 day')
  RETURNING id INTO rental_id;

  INSERT INTO remote_play.coin_wallets(rental_account_id,balance)
  VALUES(rental_id,12345) RETURNING id INTO wallet_id;

  INSERT INTO remote_play.coin_lots(
    wallet_id,original_coins,remaining_coins,expires_at
  )
  VALUES(wallet_id,15000,12345,now()+interval '5 days')
  RETURNING id INTO lot_id;

  INSERT INTO remote_play.coin_ledger(
    wallet_id,lot_id,event_type,amount_coins,balance_after,
    reference_type,reference_id,idempotency_key
  )
  VALUES(wallet_id,lot_id,'topup_credit',15000,12345,
    'admin_coin_overview_test',rental_id::text,'admin-overview-credit:'||rental_id::text);

  INSERT INTO remote_play.coin_topup_orders(
    rental_account_id,amount_rupiah,coin_amount,expiry_days,idempotency_key,status
  )
  VALUES(rental_id,10000,7500,3,'admin-overview-pending:'||rental_id::text,'pending')
  RETURNING id INTO order_id;

  PERFORM api.admin_remote_coin_set_device_rate(owner_token,device_id,'RTX 5060');
  PERFORM api.admin_remote_coin_link_stardesk_device(
    owner_token,device_id,'SD-COIN-ADMIN-OVERVIEW',true
  );

  overview:=api.admin_remote_coin_overview(owner_token,100);
  IF coalesce((overview->>'ok')::boolean,false) IS NOT TRUE
     OR NOT EXISTS(
       SELECT 1 FROM jsonb_array_elements(overview->'orders') x
       WHERE x->>'id'=order_id::text AND x->>'status'='pending'
         AND x->>'rental_code'='COIN-ADMIN-OVERVIEW'
     )
     OR NOT EXISTS(
       SELECT 1 FROM jsonb_array_elements(overview->'devices') x
       WHERE x->>'device_id'=device_id::text
         AND x->>'gpu_class'='RTX 5060'
         AND (x->>'hourly_rupiah')::integer=8000
         AND (x->>'hourly_coins')::numeric=6000
         AND x->>'stardesk_device_id'='SD-COIN-ADMIN-OVERVIEW'
         AND x->>'rate_enabled'='true'
         AND x->>'stardesk_link_enabled'='true'
     )
     OR coalesce((overview->'summary'->>'pending_orders')::integer,0)<1
     OR coalesce((overview->'summary'->>'pending_amount_rupiah')::bigint,0)<10000
     OR coalesce((overview->>'coin_unit_scale')::integer,0)<>100 THEN
    RAISE EXCEPTION 'COIN_ADMIN_OVERVIEW_MISSING_ORDER_DEVICE_RATE_OR_MAPPING';
  END IF;

  detail:=api.admin_remote_coin_wallet(owner_token,rental_id,50);
  IF coalesce((detail->>'ok')::boolean,false) IS NOT TRUE
     OR detail->'rental_account'->>'code'<>'COIN-ADMIN-OVERVIEW'
     OR (detail->'wallet'->>'balance')::numeric<>12345
     OR jsonb_array_length(detail->'lots')<>1
     OR jsonb_array_length(detail->'ledger')<>1
     OR jsonb_array_length(detail->'orders')<>1
     OR detail->'orders'->0->>'id'<>order_id::text THEN
    RAISE EXCEPTION 'COIN_ADMIN_WALLET_DETAIL_INCOMPLETE';
  END IF;

  IF NOT has_function_privilege(
       'ani_api_runtime','api.admin_remote_coin_overview(text,integer)','EXECUTE')
     OR NOT has_function_privilege(
       'ani_api_runtime','api.admin_remote_coin_wallet(text,uuid,integer)','EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_proc p,
         LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
       WHERE p.oid='api.admin_remote_coin_wallet(text,uuid,integer)'::regprocedure
         AND acl.grantee=0 AND acl.privilege_type='EXECUTE'
     ) THEN
    RAISE EXCEPTION 'COIN_ADMIN_READ_RPC_PRIVILEGES_INVALID';
  END IF;

  -- Tenant boundary: an unknown or foreign rental account must never leak a wallet.
  BEGIN
    PERFORM api.admin_remote_coin_wallet(owner_token,gen_random_uuid(),10);
    RAISE EXCEPTION 'COIN_ADMIN_WALLET_ORG_SCOPE_NOT_ENFORCED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='COIN_ADMIN_WALLET_ORG_SCOPE_NOT_ENFORCED' THEN RAISE; END IF;
    IF SQLERRM<>'RENTAL_NOT_FOUND' THEN
      RAISE EXCEPTION 'COIN_ADMIN_WALLET_ORG_SCOPE_UNEXPECTED_ERROR:%',SQLERRM;
    END IF;
  END;
END;
$$;

SELECT 'PASS: Admin Coin overview, top-up status feed, GPU/StarDesk configuration, per-rental wallet/lot/ledger detail, and org boundary' AS result;
