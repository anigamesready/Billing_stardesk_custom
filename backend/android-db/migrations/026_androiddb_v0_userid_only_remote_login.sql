-- StarDesk Custom v0 — User ID-only renter authentication.
-- This migration applies only inside stardesk_custom_v0. It replaces the old
-- activation-code login contract; Admin-issued host enrollment remains separate.
-- The API applies IP + User ID rate limiting before calling this RPC.
BEGIN;

DO $drop_activation_login$
BEGIN
  IF to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text,text) FROM PUBLIC, ani_api_runtime';
    EXECUTE 'DROP FUNCTION api.androiddb_v0_remote_login(text,text,text)';
  END IF;
END;
$drop_activation_login$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_login(
  p_rental_code text,
  p_client_install_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE
  r androiddb_v0.rental_accounts%ROWTYPE;
  s androiddb_v0.client_sessions%ROWTYPE;
  raw_token text := encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh text := encode(extensions.gen_random_bytes(32),'hex');
  session_id uuid;
BEGIN
  IF length(coalesce(btrim(p_rental_code),'')) NOT BETWEEN 3 AND 40
     OR length(coalesce(btrim(p_client_install_id),'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  -- Lock the rental row so simultaneous logins serialize before rotating its
  -- single active client session.
  SELECT * INTO r
  FROM androiddb_v0.rental_accounts
  WHERE code=upper(btrim(p_rental_code))
  FOR UPDATE;

  IF NOT FOUND OR r.status<>'active' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  SELECT * INTO s
  FROM androiddb_v0.client_sessions
  WHERE rental_account_id=r.id AND revoked_at IS NULL
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    UPDATE androiddb_v0.client_sessions
    SET token_hash=encode(extensions.digest(raw_token,'sha256'),'hex'),
        refresh_token_hash=encode(extensions.digest(raw_refresh,'sha256'),'hex'),
        client_install_id=left(btrim(p_client_install_id),128),
        expires_at=now()+interval '12 hours',
        refresh_expires_at=now()+interval '30 days',
        last_seen_at=now()
    WHERE id=s.id
    RETURNING id INTO session_id;
  ELSE
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
    RETURNING id INTO session_id;
  END IF;

  INSERT INTO androiddb_v0.audit_events(
    org_id,actor_family,actor_id,event_name,target_id,payload
  )
  VALUES(
    r.org_id,'client',session_id::text,'client_login',r.id::text,
    jsonb_build_object(
      'auth_method','user_id_only',
      'client_install_id',left(btrim(p_client_install_id),128),
      'session_rotated',s.id IS NOT NULL
    )
  );

  RETURN jsonb_build_object(
    'ok',true,
    'access_token',raw_token,
    'refresh_token',raw_refresh,
    'token_type','bearer',
    'expires_at',now()+interval '12 hours',
    'refresh_expires_at',now()+interval '30 days',
    'client_session_id',session_id,
    'auth_method','user_id_only'
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text) TO ani_api_runtime;
COMMENT ON FUNCTION api.androiddb_v0_remote_login(text,text)
  IS 'StarDesk Custom v0 renter login using User ID only; one active session, 5 attempts/IP+UserID enforced by the Node API.';

COMMIT;
