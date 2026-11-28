-- Ani Games Ready StarDesk Custom 031: three-field invite capture + Agent-owned Coin sessions.
-- Additive only. Keeps legacy androiddb_v0.sessions (public.devices.id) untouched.
BEGIN;

ALTER TABLE androiddb_v0.stardesk_pairings
  ADD COLUMN IF NOT EXISTS invite_url_ciphertext text,
  ADD COLUMN IF NOT EXISTS invite_url_nonce text,
  ADD COLUMN IF NOT EXISTS invite_url_tag text,
  ADD COLUMN IF NOT EXISTS capture_fingerprint text NOT NULL DEFAULT '';

ALTER TABLE androiddb_v0.stardesk_pairings
  DROP CONSTRAINT IF EXISTS stardesk_pairings_invite_cipher_tuple_check;
ALTER TABLE androiddb_v0.stardesk_pairings
  ADD CONSTRAINT stardesk_pairings_invite_cipher_tuple_check CHECK (
    (invite_url_ciphertext IS NULL AND invite_url_nonce IS NULL AND invite_url_tag IS NULL)
    OR
    (length(invite_url_ciphertext) BETWEEN 1 AND 4096
      AND length(invite_url_nonce)=16 AND length(invite_url_tag)=24)
  );
ALTER TABLE androiddb_v0.stardesk_pairings
  DROP CONSTRAINT IF EXISTS stardesk_pairings_capture_fingerprint_check;
ALTER TABLE androiddb_v0.stardesk_pairings
  ADD CONSTRAINT stardesk_pairings_capture_fingerprint_check
  CHECK (capture_fingerprint='' OR capture_fingerprint ~ '^[0-9a-f]{64}$');

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_rental_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES androiddb_v0.rental_accounts(id) ON DELETE CASCADE,
  rental_pc_id uuid NOT NULL REFERENCES androiddb_v0.rental_pcs(id) ON DELETE RESTRICT,
  agent_device_id uuid NOT NULL REFERENCES androiddb_v0.agent_devices(id) ON DELETE RESTRICT,
  client_session_id uuid NOT NULL REFERENCES androiddb_v0.client_sessions(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested','connected','ended','failed','cancelled')),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 8 AND 128),
  hourly_coin_units integer NOT NULL CHECK (hourly_coin_units BETWEEN 1 AND 100000000),
  coin_scale integer NOT NULL DEFAULT 100 CHECK (coin_scale=100),
  requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  request_expires_at timestamptz NOT NULL DEFAULT (clock_timestamp()+interval '5 minutes'),
  connected_at timestamptz,
  last_billed_at timestamptz,
  ended_at timestamptz,
  end_reason text,
  debited_coin_units numeric(20,8) NOT NULL DEFAULT 0 CHECK (debited_coin_units>=0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(client_session_id,idempotency_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_open_coin_session_per_rental
  ON androiddb_v0.coin_rental_sessions(rental_account_id)
  WHERE status IN ('requested','connected');
CREATE UNIQUE INDEX IF NOT EXISTS androiddb_v0_one_open_coin_session_per_pc
  ON androiddb_v0.coin_rental_sessions(rental_pc_id)
  WHERE status IN ('requested','connected');
CREATE INDEX IF NOT EXISTS androiddb_v0_coin_rental_sessions_agent_idx
  ON androiddb_v0.coin_rental_sessions(agent_device_id,status,last_billed_at);
CREATE INDEX IF NOT EXISTS androiddb_v0_coin_rental_sessions_account_idx
  ON androiddb_v0.coin_rental_sessions(rental_account_id,created_at DESC);

CREATE TABLE IF NOT EXISTS androiddb_v0.coin_session_billing_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES androiddb_v0.coin_rental_sessions(id) ON DELETE CASCADE,
  event_id uuid NOT NULL,
  charged_coin_units numeric(20,8) NOT NULL DEFAULT 0 CHECK (charged_coin_units>=0),
  billed_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(session_id,event_id)
);
CREATE INDEX IF NOT EXISTS androiddb_v0_coin_session_billing_events_recent_idx
  ON androiddb_v0.coin_session_billing_events(session_id,created_at DESC);

ALTER TABLE androiddb_v0.coin_rental_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.coin_session_billing_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE androiddb_v0.coin_rental_sessions FROM PUBLIC,stardesk_v0_runtime;
REVOKE ALL ON TABLE androiddb_v0.coin_session_billing_events FROM PUBLIC,stardesk_v0_runtime;

-- The 1 unit in rental_pcs.hourly_coin_units and wallet/lot amounts is 0.01 displayed Coin.
-- Example: 6000 units/hour = 60.00 Coin/hour; server time is authoritative.
CREATE OR REPLACE FUNCTION private.androiddb_v0_coin_rental_charge(
  p_session_id uuid,
  p_event_id uuid,
  p_until timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE
  s androiddb_v0.coin_rental_sessions%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE;
  lot_row androiddb_v0.coin_lots%ROWTYPE;
  existing_event androiddb_v0.coin_session_billing_events%ROWTYPE;
  v_now timestamptz:=least(coalesce(p_until,clock_timestamp()),clock_timestamp());
  v_elapsed numeric(20,8);
  v_due numeric(20,8);
  v_available numeric(20,8);
  v_charge numeric(20,8);
  v_left numeric(20,8);
  v_taken numeric(20,8);
  v_balance_after numeric(20,8);
  v_effective_until timestamptz;
  v_exhausted boolean:=false;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_EVENT_ID_REQUIRED'; END IF;

  SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
  WHERE id=p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_SESSION_NOT_FOUND'; END IF;

  SELECT * INTO existing_event
  FROM androiddb_v0.coin_session_billing_events
  WHERE session_id=s.id AND event_id=p_event_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'session_id',s.id,
      'status',s.status,'charged_coin_units',existing_event.charged_coin_units,
      'balance',coalesce((SELECT balance FROM androiddb_v0.coin_wallets WHERE rental_account_id=s.rental_account_id),0)/100);
  END IF;

  IF s.status<>'connected' OR s.last_billed_at IS NULL THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'session_id',s.id,
      'status',s.status,'charged_coin_units',0,'balance',0);
  END IF;

  INSERT INTO androiddb_v0.coin_wallets(rental_account_id)
    VALUES(s.rental_account_id) ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets
    WHERE rental_account_id=s.rental_account_id FOR UPDATE;
  v_available:=private.androiddb_v0_expire_wallet(w.id);
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE id=w.id FOR UPDATE;
  v_available:=w.balance;

  v_elapsed:=greatest(0,extract(epoch FROM (v_now-s.last_billed_at)))::numeric;
  v_due:=round(s.hourly_coin_units::numeric*v_elapsed/3600,8);
  v_charge:=least(v_due,v_available);
  v_exhausted:=v_due>v_available;
  IF v_exhausted AND s.hourly_coin_units>0 THEN
    v_effective_until:=s.last_billed_at+
      make_interval(secs=>(v_charge*3600/s.hourly_coin_units)::double precision);
  ELSE
    v_effective_until:=v_now;
  END IF;

  v_left:=v_charge;
  v_balance_after:=v_available;
  FOR lot_row IN
    SELECT * FROM androiddb_v0.coin_lots
    WHERE wallet_id=w.id AND remaining_coins>0 AND expires_at>v_now
    ORDER BY expires_at,created_at,id
    FOR UPDATE
  LOOP
    EXIT WHEN v_left<=0;
    v_taken:=least(lot_row.remaining_coins,v_left);
    UPDATE androiddb_v0.coin_lots
      SET remaining_coins=remaining_coins-v_taken
      WHERE id=lot_row.id;
    v_left:=v_left-v_taken;
    v_balance_after:=greatest(0,v_balance_after-v_taken);
    IF v_taken>0 THEN
      INSERT INTO androiddb_v0.coin_ledger(
        wallet_id,lot_id,event_type,amount_coins,balance_after,
        reference_type,reference_id,idempotency_key
      ) VALUES(
        w.id,lot_row.id,'session_debit',v_taken,v_balance_after,
        'coin_rental_session',s.id::text,
        'coin-session:'||s.id::text||':'||p_event_id::text||':'||lot_row.id::text
      ) ON CONFLICT(idempotency_key) DO NOTHING;
    END IF;
  END LOOP;

  IF v_left>0.00000001 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_COIN_LOT_BALANCE_MISMATCH';
  END IF;

  UPDATE androiddb_v0.coin_wallets SET balance=v_balance_after,updated_at=clock_timestamp()
    WHERE id=w.id;

  INSERT INTO androiddb_v0.coin_session_billing_events(session_id,event_id,charged_coin_units,billed_until)
  VALUES(s.id,p_event_id,v_charge,v_effective_until);

  UPDATE androiddb_v0.coin_rental_sessions SET
    debited_coin_units=debited_coin_units+v_charge,
    last_billed_at=v_effective_until,
    status=CASE WHEN v_exhausted THEN 'ended' ELSE status END,
    ended_at=CASE WHEN v_exhausted THEN v_effective_until ELSE ended_at END,
    end_reason=CASE WHEN v_exhausted THEN 'coin_exhausted' ELSE end_reason END,
    updated_at=clock_timestamp()
  WHERE id=s.id;

  RETURN jsonb_build_object(
    'ok',true,'idempotent',false,'session_id',s.id,
    'status',CASE WHEN v_exhausted THEN 'ended' ELSE 'connected' END,
    'end_reason',CASE WHEN v_exhausted THEN 'coin_exhausted' ELSE NULL END,
    'charged_coin_units',v_charge,'charged_coins',v_charge/100,
    'balance_units',v_balance_after,'balance',v_balance_after/100,
    'billed_until',v_effective_until,'coin_exhausted',v_exhausted
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(
  p_agent_token text,
  p_stardesk_device_id text,
  p_verification_ciphertext text,
  p_verification_nonce text,
  p_verification_tag text,
  p_invite_url_ciphertext text,
  p_invite_url_nonce text,
  p_invite_url_tag text,
  p_capture_fingerprint text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE
  d androiddb_v0.agent_devices%ROWTYPE;
  pc androiddb_v0.rental_pcs%ROWTYPE;
  device_id text:=btrim(coalesce(p_stardesk_device_id,''));
  changed boolean:=false;
  affected_rows integer:=0;
BEGIN
  IF length(device_id) NOT BETWEEN 1 AND 180
     OR length(coalesce(p_verification_ciphertext,'')) NOT BETWEEN 1 AND 1024
     OR length(coalesce(p_verification_nonce,''))<>16
     OR length(coalesce(p_verification_tag,''))<>24
     OR length(coalesce(p_invite_url_ciphertext,'')) NOT BETWEEN 1 AND 4096
     OR length(coalesce(p_invite_url_nonce,''))<>16
     OR length(coalesce(p_invite_url_tag,''))<>24
     OR coalesce(p_capture_fingerprint,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_STARDESK_CAPTURE_INVALID';
  END IF;

  SELECT * INTO d FROM androiddb_v0.agent_devices
  WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
    AND revoked_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;

  SELECT * INTO pc FROM androiddb_v0.rental_pcs
  WHERE id=d.rental_pc_id AND org_id=d.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PC_NOT_FOUND'; END IF;

  INSERT INTO androiddb_v0.stardesk_pairings AS current_pairing(
    rental_pc_id,org_id,stardesk_device_id,verification_ciphertext,
    verification_nonce,verification_tag,invite_url_ciphertext,invite_url_nonce,
    invite_url_tag,capture_fingerprint,status,captured_at,updated_at
  ) VALUES (
    pc.id,pc.org_id,device_id,p_verification_ciphertext,
    p_verification_nonce,p_verification_tag,p_invite_url_ciphertext,
    p_invite_url_nonce,p_invite_url_tag,p_capture_fingerprint,'captured',
    clock_timestamp(),clock_timestamp()
  )
  ON CONFLICT(rental_pc_id) DO UPDATE SET
    org_id=EXCLUDED.org_id,
    stardesk_device_id=EXCLUDED.stardesk_device_id,
    verification_ciphertext=EXCLUDED.verification_ciphertext,
    verification_nonce=EXCLUDED.verification_nonce,
    verification_tag=EXCLUDED.verification_tag,
    invite_url_ciphertext=EXCLUDED.invite_url_ciphertext,
    invite_url_nonce=EXCLUDED.invite_url_nonce,
    invite_url_tag=EXCLUDED.invite_url_tag,
    capture_fingerprint=EXCLUDED.capture_fingerprint,
    status='captured',
    captured_at=CASE WHEN current_pairing.capture_fingerprint IS DISTINCT FROM EXCLUDED.capture_fingerprint
      THEN clock_timestamp() ELSE current_pairing.captured_at END,
    updated_at=CASE WHEN current_pairing.capture_fingerprint IS DISTINCT FROM EXCLUDED.capture_fingerprint
      THEN clock_timestamp() ELSE current_pairing.updated_at END
  WHERE current_pairing.capture_fingerprint IS DISTINCT FROM EXCLUDED.capture_fingerprint;

  GET DIAGNOSTICS affected_rows = ROW_COUNT;
  changed:=affected_rows>0;
  RETURN jsonb_build_object('ok',true,'changed',coalesce(changed,false),
    'agent_device_id',d.id,'rental_pc_id',pc.id,'stardesk_device_id',device_id,
    'has_invite_url',true,'status','captured',
    'captured_at',(SELECT captured_at FROM androiddb_v0.stardesk_pairings WHERE rental_pc_id=pc.id));
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_request_session(
  p_session_token text,
  p_rental_pc_id uuid,
  p_idempotency_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  c androiddb_v0.client_sessions%ROWTYPE;
  r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE;
  pc androiddb_v0.rental_pcs%ROWTYPE;
  d androiddb_v0.agent_devices%ROWTYPE;
  sp androiddb_v0.stardesk_pairings%ROWTYPE;
  s androiddb_v0.coin_rental_sessions%ROWTYPE;
  bal numeric(20,8);
BEGIN
  IF length(coalesce(p_idempotency_key,'')) NOT BETWEEN 8 AND 128 OR p_rental_pc_id IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_COIN_SESSION_REQUEST_INVALID';
  END IF;
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id FOR UPDATE;
  IF NOT FOUND OR r.status<>'active' THEN RAISE EXCEPTION 'ANDROIDDB_V0_RENTAL_NOT_ACTIVE'; END IF;

  SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
    WHERE client_session_id=c.id AND idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF s.rental_pc_id<>p_rental_pc_id THEN RAISE EXCEPTION 'ANDROIDDB_V0_IDEMPOTENCY_CONFLICT'; END IF;
    SELECT * INTO sp FROM androiddb_v0.stardesk_pairings WHERE rental_pc_id=s.rental_pc_id;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'session_id',s.id,
      'status',s.status,'rental_pc_id',s.rental_pc_id,'hourly_coin_units',s.hourly_coin_units,
      'invite_url_ciphertext',sp.invite_url_ciphertext,'invite_url_nonce',sp.invite_url_nonce,
      'invite_url_tag',sp.invite_url_tag,'coin_unit_scale',100,'server_time',clock_timestamp());
  END IF;

  UPDATE androiddb_v0.coin_rental_sessions SET status='failed',ended_at=clock_timestamp(),
    end_reason='request_timeout',updated_at=clock_timestamp()
  WHERE rental_account_id=r.id AND status='requested'
    AND request_expires_at<=clock_timestamp();

  SELECT * INTO pc FROM androiddb_v0.rental_pcs
    WHERE id=p_rental_pc_id AND org_id=r.org_id AND enabled FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_PC_UNAVAILABLE'; END IF;

  SELECT * INTO d FROM androiddb_v0.agent_devices
    WHERE rental_pc_id=pc.id AND org_id=pc.org_id AND revoked_at IS NULL
      AND last_heartbeat_at>clock_timestamp()-interval '60 seconds'
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_AGENT_OFFLINE'; END IF;

  SELECT * INTO sp FROM androiddb_v0.stardesk_pairings
    WHERE rental_pc_id=pc.id AND org_id=pc.org_id AND status='captured'
      AND invite_url_ciphertext IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_STARDESK_INVITE_NOT_READY'; END IF;
  IF pc.hourly_coin_units<=0 THEN RAISE EXCEPTION 'ANDROIDDB_V0_PC_COIN_RATE_INVALID'; END IF;

  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id)
    ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets
    WHERE rental_account_id=r.id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  IF bal<=0 THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_BALANCE_EMPTY'; END IF;

  INSERT INTO androiddb_v0.coin_rental_sessions(
    org_id,rental_account_id,rental_pc_id,agent_device_id,client_session_id,
    idempotency_key,hourly_coin_units,status
  ) VALUES(
    r.org_id,r.id,pc.id,d.id,c.id,p_idempotency_key,pc.hourly_coin_units,'requested'
  ) RETURNING * INTO s;

  RETURN jsonb_build_object('ok',true,'idempotent',false,'session_id',s.id,
    'status',s.status,'rental_pc_id',pc.id,'device_name',pc.display_name,
    'hourly_coin_units',pc.hourly_coin_units,'hourly_coins',pc.hourly_coin_units::numeric/100,
    'invite_url_ciphertext',sp.invite_url_ciphertext,'invite_url_nonce',sp.invite_url_nonce,
    'invite_url_tag',sp.invite_url_tag,'coin_unit_scale',100,'server_time',clock_timestamp());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_stardesk_session_event(
  p_agent_token text,
  p_event_type text,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE
  d androiddb_v0.agent_devices%ROWTYPE;
  s androiddb_v0.coin_rental_sessions%ROWTYPE;
  charge jsonb;
  event_name text:=lower(btrim(coalesce(p_event_type,'')));
BEGIN
  IF event_name NOT IN ('connected','ended') OR p_event_id IS NULL THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_STARDESK_SESSION_EVENT_INVALID';
  END IF;
  SELECT * INTO d FROM androiddb_v0.agent_devices
    WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
      AND revoked_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;

  IF event_name='connected' THEN
    SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
    WHERE rental_pc_id=d.rental_pc_id AND agent_device_id=d.id
      AND status='requested' AND request_expires_at>clock_timestamp()
    ORDER BY requested_at DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN
      SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
      WHERE rental_pc_id=d.rental_pc_id AND status='connected'
      ORDER BY connected_at DESC LIMIT 1;
      RETURN jsonb_build_object('ok',true,'ignored',true,'reason','NO_PENDING_REQUEST',
        'session_id',s.id,'status',s.status);
    END IF;
    UPDATE androiddb_v0.coin_rental_sessions SET status='connected',
      connected_at=clock_timestamp(),last_billed_at=clock_timestamp(),updated_at=clock_timestamp()
    WHERE id=s.id RETURNING * INTO s;
    RETURN jsonb_build_object('ok',true,'session_id',s.id,'status','connected',
      'hourly_coin_units',s.hourly_coin_units,'started_at',s.connected_at);
  END IF;

  SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
  WHERE rental_pc_id=d.rental_pc_id AND agent_device_id=d.id
    AND status='connected'
  ORDER BY connected_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'status','no_active_session');
  END IF;

  charge:=private.androiddb_v0_coin_rental_charge(s.id,p_event_id,clock_timestamp());
  UPDATE androiddb_v0.coin_rental_sessions SET
    status=CASE WHEN status='connected' THEN 'ended' ELSE status END,
    ended_at=coalesce(ended_at,clock_timestamp()),
    end_reason=coalesce(end_reason,'stardesk_session_ended'),
    updated_at=clock_timestamp()
  WHERE id=s.id RETURNING * INTO s;
  RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',s.status,
    'end_reason',s.end_reason,'settlement',charge);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_stardesk_session_tick(
  p_agent_token text,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','extensions','pg_catalog'
AS $function$
DECLARE d androiddb_v0.agent_devices%ROWTYPE; s androiddb_v0.coin_rental_sessions%ROWTYPE;
  charge jsonb;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'ANDROIDDB_V0_COIN_EVENT_ID_REQUIRED'; END IF;
  SELECT * INTO d FROM androiddb_v0.agent_devices
    WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
      AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;
  SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
    WHERE rental_pc_id=d.rental_pc_id AND agent_device_id=d.id AND status='connected'
    ORDER BY connected_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'active',false,'status','no_active_session'); END IF;

  -- Fail closed on a lost Agent heartbeat: at most 45 seconds of unconfirmed time
  -- can be charged after the last successful meter tick.
  IF clock_timestamp()-s.last_billed_at>interval '45 seconds' THEN
    charge:=private.androiddb_v0_coin_rental_charge(
      s.id,p_event_id,s.last_billed_at+interval '45 seconds');
    UPDATE androiddb_v0.coin_rental_sessions SET status='ended',
      ended_at=coalesce(ended_at,last_billed_at),end_reason=coalesce(end_reason,'agent_heartbeat_timeout'),
      updated_at=clock_timestamp()
    WHERE id=s.id AND status='connected' RETURNING * INTO s;
    RETURN jsonb_build_object('ok',true,'active',false,'session_id',s.id,
      'status','ended','end_reason','agent_heartbeat_timeout',
      'charged_coin_units',charge->'charged_coin_units',
      'balance',charge->'balance','billed_until',charge->'billed_until');
  END IF;

  charge:=private.androiddb_v0_coin_rental_charge(s.id,p_event_id,clock_timestamp());
  RETURN jsonb_build_object('ok',true,'active',charge->>'status'='connected',
    'session_id',s.id,'status',charge->>'status',
    'coin_exhausted',coalesce((charge->>'coin_exhausted')::boolean,false),
    'charged_coin_units',charge->'charged_coin_units',
    'balance',charge->'balance','billed_until',charge->'billed_until');
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_session_status(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; s androiddb_v0.coin_rental_sessions%ROWTYPE;
  bal numeric(20,8); projected numeric(20,8);
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(c.rental_account_id)
    ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT balance INTO bal FROM androiddb_v0.coin_wallets
    WHERE rental_account_id=c.rental_account_id;
  SELECT * INTO s FROM androiddb_v0.coin_rental_sessions
    WHERE rental_account_id=c.rental_account_id AND status IN ('requested','connected')
    ORDER BY requested_at DESC LIMIT 1;
  projected:=coalesce(s.debited_coin_units,0);
  IF s.status='connected' AND s.last_billed_at IS NOT NULL THEN
    projected:=projected+round(s.hourly_coin_units::numeric*
      greatest(0,extract(epoch FROM (clock_timestamp()-s.last_billed_at)))/3600,8);
  END IF;
  RETURN jsonb_build_object('ok',true,'session',CASE WHEN s.id IS NULL THEN NULL ELSE
    jsonb_build_object('id',s.id,'rental_pc_id',s.rental_pc_id,'status',s.status,
      'requested_at',s.requested_at,'connected_at',s.connected_at,'hourly_coin_units',s.hourly_coin_units,
      'hourly_coins',s.hourly_coin_units::numeric/100,'debited_coin_units',s.debited_coin_units,
      'estimated_debited_coin_units',projected,'estimated_debited_coins',projected/100,
      'end_reason',s.end_reason) END,
    'wallet_balance',bal,
    'estimated_wallet_balance',greatest(0,bal-(projected-coalesce(s.debited_coin_units,0))),
    'wallet_balance_coins',bal/100,
    'estimated_wallet_balance_coins',greatest(0,bal-(projected-coalesce(s.debited_coin_units,0)))/100,
    'coin_unit_scale',100,'server_time',clock_timestamp());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE c androiddb_v0.client_sessions%ROWTYPE; r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE; bal numeric(20,8); hosts jsonb; active_row androiddb_v0.coin_rental_sessions%ROWTYPE;
  unit_scale integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id;
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id)
    ON CONFLICT(rental_account_id) DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);
  UPDATE androiddb_v0.coin_rental_sessions SET status='failed',
    ended_at=request_expires_at,end_reason='request_timeout',updated_at=clock_timestamp()
  WHERE rental_account_id=r.id AND status='requested'
    AND request_expires_at<=clock_timestamp();

  SELECT * INTO active_row FROM androiddb_v0.coin_rental_sessions
    WHERE rental_account_id=r.id AND status IN ('requested','connected')
    ORDER BY requested_at DESC LIMIT 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'device_id',pc.id,'client_id',d.id,'device_name',pc.display_name,
    'online',coalesce(d.status='online' AND d.last_heartbeat_at>clock_timestamp()-interval '60 seconds',false),
    'host_agent_online',coalesce(d.status='online' AND d.last_heartbeat_at>clock_timestamp()-interval '60 seconds',false),
    'host_agent_ready',coalesce(d.status='online' AND d.last_heartbeat_at>clock_timestamp()-interval '60 seconds',false)
      AND coalesce(sp.status='captured' AND sp.invite_url_ciphertext IS NOT NULL,false),
    'available',r.status='active' AND bal>0 AND active_row.id IS NULL AND pc.enabled
      AND d.revoked_at IS NULL AND d.last_heartbeat_at>clock_timestamp()-interval '60 seconds'
      AND sp.status='captured' AND sp.invite_url_ciphertext IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM androiddb_v0.coin_rental_sessions rs
        WHERE rs.rental_pc_id=pc.id AND rs.status IN ('requested','connected')),
    'remote_play_enabled',pc.enabled,'gpu_class',pc.gpu_class,
    'hourly_rupiah',pc.hourly_rupiah,
    'hourly_coin_units',pc.hourly_coin_units,
    'hourly_coins',pc.hourly_coin_units::numeric/100,
    'rate_configured',pc.hourly_coin_units>0,
    'stardesk_device_id',sp.stardesk_device_id,
    'stardesk_linked',coalesce(sp.status='captured' AND sp.invite_url_ciphertext IS NOT NULL,false),
    'active_session',EXISTS(SELECT 1 FROM androiddb_v0.coin_rental_sessions rs
      WHERE rs.rental_pc_id=pc.id AND rs.status='connected')
  ) ORDER BY pc.display_name),'[]'::jsonb) INTO hosts
  FROM androiddb_v0.rental_pcs pc
  LEFT JOIN androiddb_v0.agent_devices d ON d.rental_pc_id=pc.id AND d.org_id=pc.org_id
  LEFT JOIN androiddb_v0.stardesk_pairings sp ON sp.rental_pc_id=pc.id AND sp.org_id=pc.org_id
  WHERE pc.org_id=r.org_id;

  RETURN jsonb_build_object(
    'ok',true,'rental_account',jsonb_build_object('id',r.id,'code',r.code,
      'client_label',r.client_label,'status',r.status),
    'wallet',jsonb_build_object('balance',bal),
    'can_start',r.status='active' AND bal>0 AND active_row.id IS NULL,
    'active_session',CASE WHEN active_row.id IS NULL THEN NULL ELSE
      jsonb_build_object('id',active_row.id,'rental_pc_id',active_row.rental_pc_id,
        'status',active_row.status,'connected_at',active_row.connected_at,
        'hourly_coins',active_row.hourly_coin_units::numeric/100,
        'debited_coins',active_row.debited_coin_units/100) END,
    'hosts',hosts,'coin_unit_scale',unit_scale,'server_time',clock_timestamp()
  );
END;
$function$;

REVOKE ALL ON FUNCTION private.androiddb_v0_coin_rental_charge(uuid,uuid,timestamptz) FROM PUBLIC,stardesk_v0_runtime;
REVOKE ALL ON FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(text,text,text,text,text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_request_session(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_agent_stardesk_session_event(text,text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_agent_stardesk_session_tick(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_session_status(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_dashboard(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(text,text,text,text,text,text,text,text,text) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_request_session(text,uuid,text) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_stardesk_session_event(text,text,uuid) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_stardesk_session_tick(text,uuid) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_session_status(text) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_dashboard(text) TO stardesk_v0_runtime;

COMMIT;
