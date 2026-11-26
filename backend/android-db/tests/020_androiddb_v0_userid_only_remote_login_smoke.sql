-- StarDesk Custom v0 User ID-only Remote authentication regression.
-- Requires the disposable CI Android DB core + migration 025 + 026.
DO $$
DECLARE
  login_result jsonb;
  login_again jsonb;
  owner_token text;
  v_org uuid;
  rental_id uuid;
  first_access text;
  first_refresh text;
  access_token text;
  refresh_token text;
  session_id uuid;
  active_sessions integer;
  dashboard jsonb;
  error_text text;
BEGIN
  login_result:=api.admin_login('stardesk-owner-smoke','StarDesk-Smoke-Pass-2026!');
  owner_token:=login_result->>'token';
  v_org:=(login_result->>'org_id')::uuid;
  IF coalesce(owner_token,'')='' OR v_org IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_OWNER_LOGIN_FAILED';
  END IF;

  IF to_regprocedure('api.androiddb_v0_remote_login(text,text)') IS NULL
     OR to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_LOGIN_OVERLOAD_MISSING';
  END IF;

  PERFORM api.androiddb_v0_admin_create_rental(owner_token,'V0-CI-USERID','User ID Only Test');
  SELECT id INTO rental_id FROM androiddb_v0.rental_accounts
  WHERE androiddb_v0.rental_accounts.org_id=v_org AND code='V0-CI-USERID';
  IF rental_id IS NULL THEN RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_RENTAL_CREATE_FAILED'; END IF;

  -- No activation credential is issued or supplied. A valid active User ID is
  -- sufficient for first login on the client device.
  login_result:=api.androiddb_v0_remote_login('V0-CI-USERID','android-userid-install-0001');
  first_access:=login_result->>'access_token';
  first_refresh:=login_result->>'refresh_token';
  session_id:=(login_result->>'client_session_id')::uuid;
  IF length(coalesce(first_access,''))<>64
     OR length(coalesce(first_refresh,''))<>64
     OR session_id IS NULL
     OR login_result->>'auth_method'<>'user_id_only' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_ONLY_FIRST_LOGIN_FAILED';
  END IF;

  login_again:=api.androiddb_v0_remote_login('v0-ci-userid','android-userid-install-0002');
  access_token:=login_again->>'access_token';
  refresh_token:=login_again->>'refresh_token';
  IF length(coalesce(access_token,''))<>64 OR length(coalesce(refresh_token,''))<>64
     OR (login_again->>'client_session_id')::uuid<>session_id
     OR access_token=first_access OR refresh_token=first_refresh
     OR login_again->>'auth_method'<>'user_id_only' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_ONLY_SESSION_ROTATION_FAILED';
  END IF;

  SELECT count(*) INTO active_sessions FROM androiddb_v0.client_sessions
  WHERE rental_account_id=rental_id AND revoked_at IS NULL;
  IF active_sessions<>1 OR NOT EXISTS(
    SELECT 1 FROM androiddb_v0.client_sessions
    WHERE id=session_id AND client_install_id='android-userid-install-0002'
  ) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_ONLY_SINGLE_ACTIVE_SESSION_FAILED';
  END IF;

  BEGIN
    PERFORM api.androiddb_v0_remote_dashboard(first_access);
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_OLD_ACCESS_TOKEN_STILL_VALID';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_CLIENT_SESSION_EXPIRED' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM api.androiddb_v0_remote_refresh(first_refresh);
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_OLD_REFRESH_TOKEN_STILL_VALID';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_REFRESH_EXPIRED' THEN RAISE; END IF;
  END;

  dashboard:=api.androiddb_v0_remote_dashboard(access_token);
  IF dashboard->>'ok'<>'true' OR dashboard->'rental_account'->>'code'<>'V0-CI-USERID' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_ONLY_DASHBOARD_FAILED';
  END IF;

  -- Invalid/disabled User IDs fail closed.
  BEGIN
    PERFORM api.androiddb_v0_remote_login('V0-CI-UNKNOWN','android-userid-install-0003');
    RAISE EXCEPTION 'ANDROIDDB_V0_UNKNOWN_USER_ID_ACCEPTED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_INVALID_CREDENTIALS' THEN RAISE; END IF;
  END;

  PERFORM api.androiddb_v0_admin_set_rental_status(owner_token,rental_id,false);
  BEGIN
    PERFORM api.androiddb_v0_remote_login('V0-CI-USERID','android-userid-install-0004');
    RAISE EXCEPTION 'ANDROIDDB_V0_DISABLED_USER_ID_ACCEPTED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS error_text=MESSAGE_TEXT;
    IF error_text<>'ANDROIDDB_V0_INVALID_CREDENTIALS' THEN RAISE; END IF;
  END;

  IF has_table_privilege('stardesk_v0_runtime','androiddb_v0.rental_accounts','SELECT')
     OR has_table_privilege('stardesk_v0_runtime','androiddb_v0.client_sessions','SELECT')
     OR NOT has_function_privilege('stardesk_v0_runtime','api.androiddb_v0_remote_login(text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_USER_ID_ONLY_RUNTIME_PRIVILEGE_CONTRACT_FAILED';
  END IF;
END;
$$;

SELECT 'PASS: StarDesk v0 User ID-only login, same-session token rotation, old-token revocation, disabled/unknown account rejection, and isolated DB privileges' AS result;
