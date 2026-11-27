-- StarDesk Custom 028: Owner-configurable per-PC prices for both Coin Host and Windows Agent.
-- Additive migration. Run only in the isolated stardesk_custom_v0 database.
BEGIN;

ALTER TABLE androiddb_v0.pc_coin_rates
  ALTER COLUMN hourly_coins TYPE numeric(16,8) USING hourly_coins::numeric(16,8);

ALTER TABLE androiddb_v0.pc_coin_rates
  DROP CONSTRAINT IF EXISTS pc_coin_rates_gpu_class_check;
ALTER TABLE androiddb_v0.pc_coin_rates
  ADD CONSTRAINT pc_coin_rates_gpu_class_check
  CHECK (length(btrim(gpu_class)) BETWEEN 1 AND 120);

ALTER TABLE androiddb_v0.rental_pcs
  DROP CONSTRAINT IF EXISTS rental_pcs_gpu_class_check;
ALTER TABLE androiddb_v0.rental_pcs
  DROP CONSTRAINT IF EXISTS rental_pcs_hourly_rupiah_check;
ALTER TABLE androiddb_v0.rental_pcs
  DROP CONSTRAINT IF EXISTS rental_pcs_hourly_coin_units_check;
ALTER TABLE androiddb_v0.rental_pcs
  ADD CONSTRAINT rental_pcs_gpu_class_check
    CHECK (length(btrim(gpu_class)) BETWEEN 1 AND 120),
  ADD CONSTRAINT rental_pcs_hourly_rupiah_check
    CHECK (hourly_rupiah BETWEEN 1 AND 100000000),
  ADD CONSTRAINT rental_pcs_hourly_coin_units_check
    CHECK (hourly_coin_units BETWEEN 1 AND 100000000);

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_set_device_custom_rate(
  p_session_token text,
  p_device_id uuid,
  p_gpu_class text,
  p_hourly_rupiah integer,
  p_hourly_coin_units integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  device_row public.devices%ROWTYPE;
  gpu text:=btrim(coalesce(p_gpu_class,''));
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF length(gpu) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_GPU_LABEL_INVALID';
  END IF;
  IF p_hourly_rupiah IS NULL OR p_hourly_rupiah NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_RUPIAH_INVALID';
  END IF;
  IF p_hourly_coin_units IS NULL OR p_hourly_coin_units NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_COIN_INVALID';
  END IF;

  SELECT * INTO device_row
  FROM public.devices
  WHERE id=p_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;

  INSERT INTO androiddb_v0.pc_coin_rates(
    device_id,org_id,gpu_class,hourly_rupiah,hourly_coins,enabled,updated_by,updated_at
  ) VALUES (
    p_device_id,a.org_id,gpu,p_hourly_rupiah,p_hourly_coin_units,true,a.auth_user_id,now()
  )
  ON CONFLICT(device_id) DO UPDATE SET
    org_id=EXCLUDED.org_id,gpu_class=EXCLUDED.gpu_class,
    hourly_rupiah=EXCLUDED.hourly_rupiah,hourly_coins=EXCLUDED.hourly_coins,
    enabled=true,updated_by=a.auth_user_id,updated_at=now();

  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'pc_coin_custom_rate_updated',p_device_id::text,
    jsonb_build_object('gpu_class',gpu,'hourly_rupiah',p_hourly_rupiah,
      'hourly_coin_units',p_hourly_coin_units));

  RETURN jsonb_build_object(
    'ok',true,'device_id',p_device_id,'gpu_class',gpu,
    'hourly_rupiah',p_hourly_rupiah,
    'hourly_coin_units',p_hourly_coin_units,
    'hourly_coins',p_hourly_coin_units::numeric/100
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_pair_manual(
  p_session_token text,
  p_pair_code text,
  p_display_name text,
  p_gpu_class text,
  p_hourly_rupiah integer,
  p_hourly_coin_units integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  e androiddb_v0.agent_enrollments%ROWTYPE;
  pc androiddb_v0.rental_pcs%ROWTYPE;
  gpu text:=btrim(coalesce(p_gpu_class,''));
  label text:=btrim(coalesce(p_display_name,''));
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF length(btrim(coalesce(p_pair_code,'')))<>8 OR p_pair_code !~ '^[0-9]{8}$'
     OR length(label) NOT BETWEEN 1 AND 120
     OR length(gpu) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PAIR_INPUT_INVALID';
  END IF;
  IF p_hourly_rupiah IS NULL OR p_hourly_rupiah NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_RUPIAH_INVALID';
  END IF;
  IF p_hourly_coin_units IS NULL OR p_hourly_coin_units NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_COIN_INVALID';
  END IF;

  SELECT * INTO e FROM androiddb_v0.agent_enrollments
  WHERE pair_code_hash=encode(extensions.digest(p_pair_code,'sha256'),'hex')
    AND status='pending' AND expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PAIR_CODE_INVALID_OR_EXPIRED'; END IF;
  IF EXISTS(SELECT 1 FROM androiddb_v0.agent_devices WHERE id=e.agent_device_id) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_ALREADY_PAIRED';
  END IF;

  INSERT INTO androiddb_v0.rental_pcs(
    org_id,display_name,gpu_class,hourly_rupiah,hourly_coin_units
  ) VALUES (
    a.org_id,label,gpu,p_hourly_rupiah,p_hourly_coin_units
  ) RETURNING * INTO pc;

  INSERT INTO androiddb_v0.agent_devices(
    id,org_id,rental_pc_id,agent_token_hash,computer_name,windows_version,
    gpu_name,agent_version,status,last_heartbeat_at
  ) VALUES (
    e.agent_device_id,a.org_id,pc.id,e.agent_token_hash,e.computer_name,
    e.windows_version,e.gpu_name,e.agent_version,'offline',NULL
  );

  UPDATE androiddb_v0.agent_enrollments
  SET status='paired',approved_by=a.auth_user_id,approved_at=now(),rental_pc_id=pc.id
  WHERE id=e.id;

  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_paired_manual_rate',e.agent_device_id::text,
    jsonb_build_object('rental_pc_id',pc.id,'display_name',label,'gpu_class',gpu,
      'hourly_rupiah',p_hourly_rupiah,'hourly_coin_units',p_hourly_coin_units));

  RETURN jsonb_build_object(
    'ok',true,'paired',true,'agent_device_id',e.agent_device_id,
    'rental_pc_id',pc.id,'display_name',label,'gpu_class',gpu,
    'hourly_rupiah',p_hourly_rupiah,
    'hourly_coin_units',p_hourly_coin_units,
    'hourly_coins',p_hourly_coin_units::numeric/100
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_update_pc_manual(
  p_session_token text,
  p_agent_device_id uuid,
  p_display_name text,
  p_gpu_class text,
  p_hourly_rupiah integer,
  p_hourly_coin_units integer
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d androiddb_v0.agent_devices%ROWTYPE;
  label text:=btrim(coalesce(p_display_name,''));
  gpu text:=btrim(coalesce(p_gpu_class,''));
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF length(label) NOT BETWEEN 1 AND 120 OR length(gpu) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PC_INPUT_INVALID';
  END IF;
  IF p_hourly_rupiah IS NULL OR p_hourly_rupiah NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_RUPIAH_INVALID';
  END IF;
  IF p_hourly_coin_units IS NULL OR p_hourly_coin_units NOT BETWEEN 1 AND 100000000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_HOURLY_COIN_INVALID';
  END IF;

  SELECT * INTO d
  FROM androiddb_v0.agent_devices
  WHERE id=p_agent_device_id AND org_id=a.org_id AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_NOT_FOUND'; END IF;

  UPDATE androiddb_v0.rental_pcs
  SET display_name=label,gpu_class=gpu,hourly_rupiah=p_hourly_rupiah,
      hourly_coin_units=p_hourly_coin_units,updated_at=now()
  WHERE id=d.rental_pc_id;

  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_pc_manual_rate_updated',p_agent_device_id::text,
    jsonb_build_object('display_name',label,'gpu_class',gpu,
      'hourly_rupiah',p_hourly_rupiah,'hourly_coin_units',p_hourly_coin_units));

  RETURN jsonb_build_object(
    'ok',true,'agent_device_id',p_agent_device_id,'display_name',label,
    'gpu_class',gpu,'hourly_rupiah',p_hourly_rupiah,
    'hourly_coin_units',p_hourly_coin_units,
    'hourly_coins',p_hourly_coin_units::numeric/100
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.androiddb_v0_admin_set_device_custom_rate(text,uuid,text,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_pair_manual(text,text,text,text,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_update_pc_manual(text,uuid,text,text,integer,integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_set_device_custom_rate(text,uuid,text,integer,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_pair_manual(text,text,text,text,integer,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_update_pc_manual(text,uuid,text,text,integer,integer) TO ani_api_runtime;

COMMIT;
