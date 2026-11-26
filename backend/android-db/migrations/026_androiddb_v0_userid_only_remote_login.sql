-- User-ID-only Remote login for Android DB v0.
-- Replaces the one-time Admin activation flow without changing or deleting v0 rental/wallet data.
-- Login is rate-limited in the Node API and rotates the single active device session for this rental.
BEGIN;

REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text,text) FROM PUBLIC,ani_api_runtime;
DROP FUNCTION IF EXISTS api.androiddb_v0_remote_login(text,text,text);

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
  IF length(coalesce(trim(p_rental_code),'')) NOT BETWEEN 3 AND 40
     OR length(coalesce(trim(p_client_install_id),'')) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  -- The rental code is globally unique in this isolated v0 domain.
  -- Lock the account so simultaneous logins cannot create two active sessions.
  SELECT * INTO r
  FROM androiddb_v0.rental_accounts
  WHERE upper(code)=upper(btrim(p_rental_code))
  FOR UPDATE;

  IF NOT FOUND OR r.status<>'active' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_INVALID_CREDENTIALS';
  END IF;

  -- One active device session per rental. A new login rotates the existing
  -- access/refresh hashes in place, invalidating the previous device/session.
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
        client_install_id=left(trim(p_client_install_id),128),
        expires_at=now()+interval '12 hours',
        refresh_expires_at=now()+interval '30 days',
        last_seen_at=now()
    WHERE id=s.id
    RETURNING id INTO session_id;
  ELSE
    INSERT INTO androiddb_v0.client_sessions(
      rental_account_id,token_hash,refresh_token_hash,client_install_id,expires_at,refresh_expires_at
    )
    VALUES(
      r.id,
      encode(extensions.digest(raw_token,'sha256'),'hex'),
      encode(extensions.digest(raw_refresh,'sha256'),'hex'),
      left(trim(p_client_install_id),128),
      now()+interval '12 hours',
      now()+interval '30 days'
    )
    RETURNING id INTO session_id;
  END IF;

  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(
    r.org_id,'client',session_id::text,'client_login',r.id::text,
    jsonb_build_object('client_install_id',left(trim(p_client_install_id),128),'auth_method','user_id_only')
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

REVOKE ALL ON FUNCTION api.androiddb_v0_remote_login(text,text) FROM PUBLIC,ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text) TO ani_api_runtime;

COMMIT;
