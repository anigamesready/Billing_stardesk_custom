-- StarDesk Custom 030: Windows Agent StarDesk identity capture + Remote PC inventory.
-- Verification code is encrypted by the local API before it enters this database.
-- Plaintext verification codes are never stored in PostgreSQL or returned to Remote.
BEGIN;

CREATE TABLE IF NOT EXISTS androiddb_v0.stardesk_pairings (
  rental_pc_id uuid PRIMARY KEY REFERENCES androiddb_v0.rental_pcs(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  stardesk_device_id text NOT NULL UNIQUE
    CHECK (length(btrim(stardesk_device_id)) BETWEEN 1 AND 180),
  verification_ciphertext text NOT NULL CHECK (length(verification_ciphertext) BETWEEN 1 AND 1024),
  verification_nonce text NOT NULL CHECK (length(verification_nonce)=16),
  verification_tag text NOT NULL CHECK (length(verification_tag)=24),
  status text NOT NULL DEFAULT 'captured' CHECK (status IN ('captured','revoked')),
  captured_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_stardesk_pairings_org_idx
  ON androiddb_v0.stardesk_pairings(org_id,status,captured_at DESC);

ALTER TABLE androiddb_v0.stardesk_pairings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE androiddb_v0.stardesk_pairings FROM PUBLIC,stardesk_v0_runtime;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(
  p_agent_token text,
  p_stardesk_device_id text,
  p_verification_ciphertext text,
  p_verification_nonce text,
  p_verification_tag text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $function$
DECLARE
  d androiddb_v0.agent_devices%ROWTYPE;
  pc androiddb_v0.rental_pcs%ROWTYPE;
  device_id text:=btrim(coalesce(p_stardesk_device_id,''));
BEGIN
  IF length(device_id) NOT BETWEEN 1 AND 180
     OR length(coalesce(p_verification_ciphertext,'')) NOT BETWEEN 1 AND 1024
     OR length(coalesce(p_verification_nonce,''))<>16
     OR length(coalesce(p_verification_tag,''))<>24 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_STARDESK_CAPTURE_INVALID';
  END IF;

  SELECT * INTO d
  FROM androiddb_v0.agent_devices
  WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
    AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;

  SELECT * INTO pc
  FROM androiddb_v0.rental_pcs
  WHERE id=d.rental_pc_id AND org_id=d.org_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PC_NOT_FOUND'; END IF;

  INSERT INTO androiddb_v0.stardesk_pairings(
    rental_pc_id,org_id,stardesk_device_id,verification_ciphertext,
    verification_nonce,verification_tag,status,captured_at,updated_at
  ) VALUES (
    pc.id,pc.org_id,device_id,p_verification_ciphertext,
    p_verification_nonce,p_verification_tag,'captured',now(),now()
  )
  ON CONFLICT(rental_pc_id) DO UPDATE SET
    org_id=EXCLUDED.org_id,
    stardesk_device_id=EXCLUDED.stardesk_device_id,
    verification_ciphertext=EXCLUDED.verification_ciphertext,
    verification_nonce=EXCLUDED.verification_nonce,
    verification_tag=EXCLUDED.verification_tag,
    status='captured',captured_at=now(),updated_at=now();

  RETURN jsonb_build_object(
    'ok',true,'agent_device_id',d.id,'rental_pc_id',pc.id,
    'stardesk_device_id',device_id,'status','captured','captured_at',now()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_list(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; rows jsonb;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT coalesce(jsonb_agg(q.item ORDER BY q.display_name),'[]'::jsonb) INTO rows
  FROM (
    SELECT pc.display_name,
      jsonb_build_object('agent_device_id',d.id,'rental_pc_id',pc.id,'display_name',pc.display_name,
        'computer_name',d.computer_name,'windows_version',d.windows_version,'gpu_name',d.gpu_name,
        'agent_version',d.agent_version,'gpu_class',pc.gpu_class,'hourly_rupiah',pc.hourly_rupiah,
        'hourly_coin_units',pc.hourly_coin_units,'hourly_coins',pc.hourly_coin_units::numeric/100,
        'status',CASE WHEN d.revoked_at IS NOT NULL OR d.status='revoked' THEN 'revoked'
          WHEN d.last_heartbeat_at>now()-interval '60 seconds' THEN 'online' ELSE 'offline' END,
        'last_heartbeat_at',d.last_heartbeat_at,'paired_at',d.paired_at,
        'enabled',pc.enabled,
        'stardesk_device_id',sp.stardesk_device_id,
        'stardesk_pairing_status',coalesce(sp.status,'not_captured'),
        'stardesk_captured_at',sp.captured_at,
        'active_commands',(SELECT count(*) FROM androiddb_v0.agent_commands c
          WHERE c.agent_device_id=d.id AND c.status IN ('queued','delivered','started') AND c.expires_at>now())
      ) AS item
    FROM androiddb_v0.agent_devices d
    JOIN androiddb_v0.rental_pcs pc ON pc.id=d.rental_pc_id
    LEFT JOIN androiddb_v0.stardesk_pairings sp ON sp.rental_pc_id=pc.id AND sp.org_id=d.org_id
    WHERE d.org_id=a.org_id
  ) q;
  RETURN jsonb_build_object('ok',true,'agents',rows,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_dashboard(
  p_session_token text,p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  lim integer:=greatest(1,least(200,coalesce(p_limit,100)));
  rentals jsonb; hosts jsonb; orders jsonb; summary jsonb; unit_scale integer;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;
  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.code),'[]'::jsonb) INTO rentals
  FROM (
    SELECT r.code,
      jsonb_build_object('id',r.id,'code',r.code,'client_label',r.client_label,'status',r.status,
        'created_at',r.created_at,
        'coin_balance',coalesce((SELECT sum(l.remaining_coins) FROM androiddb_v0.coin_wallets w
          JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
          WHERE w.rental_account_id=r.id AND l.expires_at>now()),0),
        'client_logged_in',EXISTS(SELECT 1 FROM androiddb_v0.client_sessions cs
          WHERE cs.rental_account_id=r.id AND cs.revoked_at IS NULL AND cs.expires_at>now())) AS item
    FROM androiddb_v0.rental_accounts r WHERE r.org_id=a.org_id
    ORDER BY r.code LIMIT lim
  ) q;
  SELECT COALESCE(jsonb_agg(q.item ORDER BY q.device_name,q.client_id),'[]'::jsonb) INTO hosts
  FROM (
    SELECT pc.display_name AS device_name,d.computer_name AS client_id,
      jsonb_build_object('device_id',d.id,'device_name',pc.display_name,'client_id',d.computer_name,
        'device_online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
        'host_permission_enabled',pc.enabled,
        'host_agent_online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
        'host_agent_ready',false,'agent_version',d.agent_version,'host_last_seen_at',d.last_heartbeat_at,
        'gpu_class',pc.gpu_class,'hourly_rupiah',pc.hourly_rupiah,
        'hourly_coins',pc.hourly_coin_units::numeric/100,'rate_enabled',pc.enabled,
        'stardesk_device_id',sp.stardesk_device_id,
        'stardesk_link_enabled',coalesce(sp.status='captured',false),'active_session',false
      ) AS item
    FROM androiddb_v0.agent_devices d
    JOIN androiddb_v0.rental_pcs pc ON pc.id=d.rental_pc_id
    LEFT JOIN androiddb_v0.stardesk_pairings sp ON sp.rental_pc_id=pc.id AND sp.org_id=d.org_id
    WHERE d.org_id=a.org_id AND d.revoked_at IS NULL
  ) q;
  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC),'[]'::jsonb) INTO orders
  FROM (
    SELECT id,rental_account_id,amount_rupiah,coin_amount,expiry_days,status,created_at,expires_at
    FROM androiddb_v0.coin_topup_orders
    WHERE rental_account_id IN (SELECT id FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id)
    ORDER BY created_at DESC LIMIT lim
  ) o;
  SELECT jsonb_build_object(
    'rental_accounts',(SELECT count(*) FROM androiddb_v0.rental_accounts WHERE org_id=a.org_id AND status='active'),
    'pending_orders',(SELECT count(*) FROM androiddb_v0.coin_topup_orders o JOIN androiddb_v0.rental_accounts r ON r.id=o.rental_account_id WHERE r.org_id=a.org_id AND o.status='pending'),
    'wallet_accounts',(SELECT count(*) FROM androiddb_v0.coin_wallets w JOIN androiddb_v0.rental_accounts r ON r.id=w.rental_account_id WHERE r.org_id=a.org_id)
  ) INTO summary;
  RETURN jsonb_build_object('ok',true,'rental_accounts',rentals,'host_devices',hosts,'orders',orders,
    'summary',summary,'coin_unit_scale',unit_scale,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  c androiddb_v0.client_sessions%ROWTYPE;
  r androiddb_v0.rental_accounts%ROWTYPE;
  w androiddb_v0.coin_wallets%ROWTYPE;
  bal numeric(18,8);
  hosts jsonb;
  active boolean:=false;
  unit_scale integer;
BEGIN
  c:=private.androiddb_v0_get_client(p_session_token);
  SELECT * INTO r FROM androiddb_v0.rental_accounts WHERE id=c.rental_account_id;
  SELECT coin_scale INTO unit_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE;

  INSERT INTO androiddb_v0.coin_wallets(rental_account_id) VALUES(r.id) ON CONFLICT DO NOTHING;
  SELECT * INTO w FROM androiddb_v0.coin_wallets WHERE rental_account_id=r.id FOR UPDATE;
  bal:=private.androiddb_v0_expire_wallet(w.id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'device_id',pc.id,
    'client_id',d.id,
    'device_name',pc.display_name,
    'online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
    'billing_online',false,
    'host_agent_online',coalesce(d.status='online' AND d.last_heartbeat_at>now()-interval '60 seconds',false),
    'host_agent_ready',false,
    'available',false,
    'remote_play_enabled',pc.enabled,
    'gpu_class',pc.gpu_class,
    'hourly_rupiah',pc.hourly_rupiah,
    'hourly_coins',pc.hourly_coin_units::numeric/100,
    'rate_configured',pc.enabled,
    'stardesk_device_id',sp.stardesk_device_id,
    'stardesk_linked',coalesce(sp.status='captured',false),
    'stardesk_pairing_status',coalesce(sp.status,'not_captured')
  ) ORDER BY pc.display_name),'[]'::jsonb) INTO hosts
  FROM androiddb_v0.rental_pcs pc
  LEFT JOIN androiddb_v0.agent_devices d ON d.rental_pc_id=pc.id AND d.revoked_at IS NULL
  LEFT JOIN androiddb_v0.stardesk_pairings sp ON sp.rental_pc_id=pc.id AND sp.org_id=pc.org_id
  WHERE pc.org_id=r.org_id;

  RETURN jsonb_build_object(
    'ok',true,'rental_account',jsonb_build_object('id',r.id,'code',r.code,
      'client_label',r.client_label,'status',r.status),
    'wallet',jsonb_build_object('balance',bal),'can_start',false,
    'active_session',NULL,'hosts',hosts,'coin_unit_scale',unit_scale,'server_time',now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_list(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_remote_dashboard(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_sync_stardesk_pairing(text,text,text,text,text) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_list(text) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_dashboard(text,integer) TO stardesk_v0_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_dashboard(text) TO stardesk_v0_runtime;

COMMIT;
