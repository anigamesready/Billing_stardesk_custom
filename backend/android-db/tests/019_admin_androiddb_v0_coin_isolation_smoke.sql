-- Admin Android DB v0 isolation and end-to-end Coin API regression.
-- Disposable PostgreSQL only. Requires tests 001-010 to provision CI-OWNER.
DO $$
DECLARE
  login_result jsonb;
  owner_token text;
  v_org uuid;
  device_id uuid;
  legacy_rental_id uuid;
  v0_rental_id uuid;
  create_result jsonb;
  remote_login jsonb;
  second_remote_login jsonb;
  refresh_result jsonb;
  topup_result jsonb;
  topup_duplicate jsonb;
  approve_result jsonb;
  approve_duplicate jsonb;
  reject_result jsonb;
  wallet_result jsonb;
  dashboard jsonb;
  admin_dashboard jsonb;
  admin_wallet jsonb;
  rate_result jsonb;
  link_result jsonb;
  host_permission jsonb;
  host_enrollment jsonb;
  host_result jsonb;
  heartbeat_result jsonb;
  access_token text;
  refresh_token text;
  host_token text;
  order_id uuid;
  rejected_order_id uuid;
  old_seconds bigint;
  old_expiry timestamptz;
  error_text text;
  expired_lot_id uuid;
  expired_ledger_count integer;
BEGIN
  login_result:=api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  owner_token:=login_result->>'token';
  v_org:=(login_result->>'org_id')::uuid;
  IF coalesce(owner_token,'')='' OR v_org IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_OWNER_LOGIN_FAILED';
  END IF;

  -- Legacy rental exists alongside v0. It must never be read or mutated by v0.
  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status,client_label,expiry_at)
  VALUES(v_org,'V0-LEGACY-KEEP','reguler',9876,'active','Legacy keep row',now()+interval '11 days')
  RETURNING id,remaining_seconds,expiry_at INTO legacy_rental_id,old_seconds,old_expiry;

  INSERT INTO public.devices(org_id,client_id,device_name,status,last_seen_at)
  VALUES(v_org,'V0-CI-RTX5060','V0 CI RTX 5060','online',now())
  RETURNING id INTO device_id;

  IF EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='androiddb_v0' AND table_name='rental_accounts'
      AND column_name IN ('remaining_seconds','expiry_at','rental_session_id')
  ) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_LEGACY_TIMER_OR_EXPIRY_COLUMN_FOUND';
  END IF;

  create_result:=api.androiddb_v0_admin_create_rental(owner_token,'V0-CI-MEMBER','Member Coin Only');
  v0_rental_id:=(create_result->>'rental_account_id')::uuid;
  IF coalesce((create_result->>'ok')::boolean,false) IS NOT TRUE OR v0_rental_id IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_CREATE_FAILED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.rental_accounts WHERE upper(code)='V0-CI-MEMBER') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_LEAKED_TO_LEGACY_PUBLIC_RENTALS';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM androiddb_v0.rental_accounts WHERE id=v0_rental_id AND org_id=v_org) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_NOT_STORED_IN_V0_SCHEMA';
  END IF;

  -- User ID alone authenticates a rental on a new device; no Admin-issued activation is created.
  IF EXISTS(SELECT 1 FROM androiddb_v0.client_credentials WHERE rental_account_id=v0_rental_id) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_TEST_FIXTURE_UNEXPECTED_ACTIVATION_CREDENTIAL';
  END IF;
  remote_login:=api.androiddb_v0_remote_login('V0-CI-MEMBER','v0-android-test-device-0001');
  access_token:=remote_login->>'access_token';
  refresh_token:=remote_login->>'refresh_token';
  IF length(coalesce(access_token,''))<>64 OR length(coalesce(refresh_token,''))<>64
     OR remote_login->>'auth_method'<>'user_id_only' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_REMOTE_USERID_LOGIN_FAILED';
  END IF;

  -- A second phone using the same User ID rotates the sole active session.
  second_remote_login:=api.androiddb_v0_remote_login('V0-CI-MEMBER','v0-android-test-device-0002');
  IF second_remote_login->>'client_session_id' IS DISTINCT FROM remote_login->>'client_session_id'
     OR (SELECT count(*) FROM androiddb_v0.client_sessions
         WHERE rental_account_id=v0_rental_id AND revoked_at IS NULL)<>1
     OR NOT EXISTS(SELECT 1 FROM androiddb_v0.client_sessions
       WHERE rental_account_id=v0_rental_id AND revoked_at IS NULL
         AND client_install_id='v0-android-test-device-0002') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_SINGLE_ACTIVE_SESSION_ROTATION_FAILED';
  END IF;
  BEGIN
    PERFORM api.androiddb_v0_remote_coin_wallet(access_token);
    RAISE EXCEPTION 'ANDROIDDB_V0_OLD_ACCESS_TOKEN_REMAINED_VALID';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_CLIENT_SESSION_EXPIRED' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM api.androiddb_v0_remote_refresh(refresh_token);
    RAISE EXCEPTION 'ANDROIDDB_V0_OLD_REFRESH_TOKEN_REMAINED_VALID';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_REFRESH_EXPIRED' THEN RAISE; END IF;
  END;
  access_token:=second_remote_login->>'access_token';
  refresh_token:=second_remote_login->>'refresh_token';

  refresh_result:=api.androiddb_v0_remote_refresh(refresh_token);
  access_token:=refresh_result->>'access_token';
  refresh_token:=refresh_result->>'refresh_token';
  IF length(coalesce(access_token,''))<>64 OR length(coalesce(refresh_token,''))<>64 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_REFRESH_ROTATION_FAILED';
  END IF;

  wallet_result:=api.androiddb_v0_remote_coin_wallet(access_token);
  IF coalesce((wallet_result->>'balance')::numeric,-1)<>0 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INITIAL_WALLET_NOT_ZERO';
  END IF;

  topup_result:=api.androiddb_v0_remote_coin_create_topup(access_token,8000,'androiddb-v0-topup-idem-0001');
  topup_duplicate:=api.androiddb_v0_remote_coin_create_topup(access_token,8000,'androiddb-v0-topup-idem-0001');
  order_id:=(topup_result->>'order_id')::uuid;
  IF order_id IS NULL OR (topup_duplicate->>'order_id')::uuid<>order_id
     OR (topup_result->>'coin_amount')::numeric<>60
     OR topup_result->>'status'<>'pending'
     OR topup_result->>'expiry_days'<>'3' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_TOPUP_OR_IDEMPOTENCY_FAILED';
  END IF;
  BEGIN
    PERFORM api.androiddb_v0_remote_coin_create_topup(access_token,5000,'androiddb-v0-topup-idem-0001');
    RAISE EXCEPTION 'ANDROIDDB_V0_IDEMPOTENCY_AMOUNT_CONFLICT_ACCEPTED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_IDEMPOTENCY_CONFLICT' THEN RAISE; END IF;
  END;
  approve_result:=api.androiddb_v0_admin_approve_topup(owner_token,order_id);
  approve_duplicate:=api.androiddb_v0_admin_approve_topup(owner_token,order_id);
  IF approve_result->>'status'<>'approved'
     OR coalesce((approve_duplicate->>'idempotent')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_APPROVAL_IDEMPOTENCY_FAILED';
  END IF;
  wallet_result:=api.androiddb_v0_remote_coin_wallet(access_token);
  IF (wallet_result->>'balance')::numeric<>60 OR jsonb_array_length(wallet_result->'lots')<>1 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_APPROVAL_DID_NOT_CREDIT_ONE_COIN_LOT';
  END IF;
  IF (SELECT count(*) FROM androiddb_v0.coin_ledger l
      JOIN androiddb_v0.coin_wallets w ON w.id=l.wallet_id
      WHERE w.rental_account_id=v0_rental_id AND l.event_type='topup_credit')<>1 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_DUPLICATE_TOPUP_LEDGER_ENTRY';
  END IF;

  -- Rejecting a different top-up must not create a lot or credit the wallet.
  topup_result:=api.androiddb_v0_remote_coin_create_topup(access_token,40000,'androiddb-v0-topup-idem-0002');
  IF topup_result->>'expiry_days'<>'7' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_TOPUP_EXPIRY_TIER_7_DAYS_FAILED';
  END IF;
  rejected_order_id:=(topup_result->>'order_id')::uuid;
  reject_result:=api.androiddb_v0_admin_reject_topup(owner_token,rejected_order_id,'CI reject path');
  wallet_result:=api.androiddb_v0_remote_coin_wallet(access_token);
  IF reject_result->>'status'<>'rejected' OR (wallet_result->>'balance')::numeric<>60
     OR jsonb_array_length(wallet_result->'lots')<>1 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_REJECTED_TOPUP_CREDITED_WALLET';
  END IF;

  rate_result:=api.androiddb_v0_admin_set_device_rate(owner_token,device_id,'GTX 1050');
  IF rate_result->>'hourly_rupiah'<>'6000' OR (rate_result->>'hourly_coins')::numeric<>45 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_GPU_RATE_GTX1050_WRONG';
  END IF;
  rate_result:=api.androiddb_v0_admin_set_device_rate(owner_token,device_id,'GTX 1660');
  IF rate_result->>'hourly_rupiah'<>'6000' OR (rate_result->>'hourly_coins')::numeric<>45 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_GPU_RATE_GTX1660_WRONG';
  END IF;
  rate_result:=api.androiddb_v0_admin_set_device_rate(owner_token,device_id,'RTX 3060');
  IF rate_result->>'hourly_rupiah'<>'7000' OR (rate_result->>'hourly_coins')::numeric<>52.5 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_GPU_RATE_RTX3060_WRONG';
  END IF;
  rate_result:=api.androiddb_v0_admin_set_device_rate(owner_token,device_id,'RTX 5060');
  IF rate_result->>'hourly_rupiah'<>'8000' OR (rate_result->>'hourly_coins')::numeric<>60 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_GPU_RATE_RTX5060_WRONG';
  END IF;
  link_result:=api.androiddb_v0_admin_link_stardesk_device(owner_token,device_id,'CI-STAR-DESK-RTX5060',true);
  IF link_result->>'stardesk_device_id'<>'CI-STAR-DESK-RTX5060' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_STAR_DESK_MAPPING_FAILED';
  END IF;
  host_permission:=api.androiddb_v0_admin_set_host_permission(owner_token,device_id,true);
  IF host_permission->>'enabled'<>'true' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOST_PERMISSION_ENABLE_FAILED';
  END IF;
  host_enrollment:=api.androiddb_v0_admin_issue_host_enrollment(owner_token,device_id,15);
  IF length(coalesce(host_enrollment->>'enrollment_code',''))<>64 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOST_ENROLLMENT_CODE_INVALID';
  END IF;
  host_result:=api.androiddb_v0_host_enroll(host_enrollment->>'enrollment_code','ci-v0-agent');
  host_token:=host_result->>'host_token';
  IF length(coalesce(host_token,''))<>64 OR (host_result->>'device_id')::uuid<>device_id THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOST_ENROLLMENT_FAILED';
  END IF;
  heartbeat_result:=api.androiddb_v0_host_heartbeat(host_token,true,'ci-v0-agent');
  IF heartbeat_result->>'stardesk_ready'<>'true' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOST_HEARTBEAT_NOT_READY_WITH_MAPPING';
  END IF;
  dashboard:=api.androiddb_v0_remote_dashboard(access_token);
  IF coalesce((dashboard->>'can_start')::boolean,false) IS NOT TRUE
     OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(dashboard->'hosts') h
       WHERE h->>'device_id'=device_id::text AND h->>'available'='true'
         AND h->>'host_agent_ready'='true' AND h->>'stardesk_linked'='true') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_REMOTE_DASHBOARD_READINESS_CONTRACT_FAILED';
  END IF;
  admin_dashboard:=api.androiddb_v0_admin_dashboard(owner_token,100);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(admin_dashboard->'rental_accounts') r
      WHERE r->>'id'=v0_rental_id::text AND r->>'activation_issued'='false'
        AND (r->>'coin_balance')::numeric=60) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_ADMIN_RENTAL_OVERVIEW_FAILED';
  END IF;
  admin_wallet:=api.androiddb_v0_admin_wallet(owner_token,v0_rental_id,50);
  IF (admin_wallet->'wallet'->>'balance')::numeric<>60
     OR jsonb_array_length(admin_wallet->'lots')<>1 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_ADMIN_WALLET_DETAIL_FAILED';
  END IF;

  -- Force the approved lot to expire and prove balance + ledger expiry are idempotent.
  SELECT l.id INTO expired_lot_id
  FROM androiddb_v0.coin_lots l
  JOIN androiddb_v0.coin_wallets w ON w.id=l.wallet_id
  WHERE w.rental_account_id=v0_rental_id AND l.remaining_coins>0;
  IF expired_lot_id IS NULL THEN RAISE EXCEPTION 'ANDROIDDB_V0_EXPIRY_FIXTURE_LOT_MISSING'; END IF;
  UPDATE androiddb_v0.coin_lots SET expires_at=now()-interval '1 second' WHERE id=expired_lot_id;
  wallet_result:=api.androiddb_v0_remote_coin_wallet(access_token);
  IF (wallet_result->>'balance')::numeric<>0 OR jsonb_array_length(wallet_result->'lots')<>0 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_EXPIRED_LOT_REMAINS_SPENDABLE';
  END IF;
  SELECT count(*) INTO expired_ledger_count FROM androiddb_v0.coin_ledger
  WHERE lot_id=expired_lot_id AND event_type='lot_expired';
  IF expired_ledger_count<>1 THEN RAISE EXCEPTION 'ANDROIDDB_V0_EXPIRY_LEDGER_MISSING_OR_DUPLICATED'; END IF;
  -- A second wallet read must not create a duplicate expiry ledger row.
  PERFORM api.androiddb_v0_remote_coin_wallet(access_token);
  SELECT count(*) INTO expired_ledger_count FROM androiddb_v0.coin_ledger
  WHERE lot_id=expired_lot_id AND event_type='lot_expired';
  IF expired_ledger_count<>1 THEN RAISE EXCEPTION 'ANDROIDDB_V0_EXPIRY_NOT_IDEMPOTENT'; END IF;

  -- Disable revokes v0 client credentials/sessions; it does not touch legacy rows.
  PERFORM api.androiddb_v0_admin_set_rental_status(owner_token,v0_rental_id,false);
  BEGIN
    PERFORM api.androiddb_v0_remote_dashboard(access_token);
    RAISE EXCEPTION 'ANDROIDDB_V0_DISABLED_RENTAL_SESSION_WAS_ACCEPTED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_CLIENT_SESSION_EXPIRED' THEN RAISE; END IF;
  END;

  -- Legacy rental seconds and expiry are byte-for-byte unchanged by all v0 actions.
  IF NOT EXISTS(SELECT 1 FROM public.rental_accounts
    WHERE id=legacy_rental_id AND remaining_seconds=old_seconds AND expiry_at=old_expiry) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_MODIFIED_LEGACY_RENTAL_DATA';
  END IF;

  IF has_table_privilege('ani_api_runtime','androiddb_v0.rental_accounts','SELECT')
     OR has_table_privilege('ani_api_runtime','androiddb_v0.coin_wallets','SELECT')
     OR has_table_privilege('ani_api_runtime','androiddb_v0.coin_ledger','SELECT') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_RUNTIME_HAS_DIRECT_TABLE_READ';
  END IF;
  IF NOT has_function_privilege('ani_api_runtime','api.androiddb_v0_admin_dashboard(text,integer)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.androiddb_v0_remote_dashboard(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.androiddb_v0_remote_login(text,text)','EXECUTE')
     OR to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_RUNTIME_USERID_LOGIN_GRANTS_INVALID';
  END IF;
END;
$$;

SELECT 'PASS: Android DB v0 isolated rentals, activation, top-up, wallet lots, expiry model, GPU rates, Host enrollment, Remote dashboard, Owner controls and legacy timer isolation' AS result;
