-- StarDesk Custom 027: independent Windows Agent + rental PC control domain.
-- This migration is additive and belongs only to the isolated stardesk_custom_v0 database.
BEGIN;

CREATE TABLE IF NOT EXISTS androiddb_v0.rental_pcs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 120),
  gpu_class text NOT NULL CHECK (gpu_class IN ('GTX 1050','GTX 1660','RTX 3060','RTX 5060')),
  hourly_rupiah integer NOT NULL CHECK (hourly_rupiah IN (6000,7000,8000)),
  hourly_coin_units integer NOT NULL CHECK (hourly_coin_units IN (4500,5250,6000)),
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_rental_pcs_org_idx
  ON androiddb_v0.rental_pcs(org_id,display_name);

CREATE TABLE IF NOT EXISTS androiddb_v0.agent_enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_device_id uuid NOT NULL UNIQUE,
  agent_token_hash text NOT NULL CHECK (agent_token_hash ~ '^[0-9a-f]{64}$'),
  pair_code_hash text NOT NULL UNIQUE CHECK (pair_code_hash ~ '^[0-9a-f]{64}$'),
  computer_name text NOT NULL DEFAULT '',
  windows_version text NOT NULL DEFAULT '',
  gpu_name text NOT NULL DEFAULT '',
  agent_version text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paired','expired','revoked')),
  expires_at timestamptz NOT NULL DEFAULT (now()+interval '15 minutes'),
  approved_by uuid,
  approved_at timestamptz,
  rental_pc_id uuid REFERENCES androiddb_v0.rental_pcs(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_request_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS androiddb_v0_agent_enrollment_pending_idx
  ON androiddb_v0.agent_enrollments(status,expires_at);

CREATE TABLE IF NOT EXISTS androiddb_v0.agent_devices (
  id uuid PRIMARY KEY,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_pc_id uuid NOT NULL UNIQUE REFERENCES androiddb_v0.rental_pcs(id) ON DELETE CASCADE,
  agent_token_hash text NOT NULL UNIQUE CHECK (agent_token_hash ~ '^[0-9a-f]{64}$'),
  computer_name text NOT NULL DEFAULT '',
  windows_version text NOT NULL DEFAULT '',
  gpu_name text NOT NULL DEFAULT '',
  agent_version text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'offline' CHECK (status IN ('online','offline','revoked')),
  last_heartbeat_at timestamptz,
  paired_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS androiddb_v0_agent_devices_org_idx
  ON androiddb_v0.agent_devices(org_id,status,last_heartbeat_at DESC);

CREATE TABLE IF NOT EXISTS androiddb_v0.agent_commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  agent_device_id uuid NOT NULL REFERENCES androiddb_v0.agent_devices(id) ON DELETE CASCADE,
  command text NOT NULL CHECK (command IN ('message','logoff','restart','shutdown')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','delivered','started','completed','failed','expired')),
  result text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now()+interval '3 minutes'),
  delivered_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz
);
CREATE INDEX IF NOT EXISTS androiddb_v0_agent_commands_queue_idx
  ON androiddb_v0.agent_commands(agent_device_id,status,created_at)
  WHERE status IN ('queued','delivered','started');

ALTER TABLE androiddb_v0.rental_pcs ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.agent_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.agent_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE androiddb_v0.agent_commands ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE androiddb_v0.rental_pcs,androiddb_v0.agent_enrollments,
  androiddb_v0.agent_devices,androiddb_v0.agent_commands FROM PUBLIC,ani_api_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA androiddb_v0 FROM PUBLIC,ani_api_runtime;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_enroll_request(
  p_agent_device_id uuid,p_agent_token_hash text,p_pair_code_hash text,
  p_computer_name text,p_windows_version text,p_gpu_name text,p_agent_version text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $function$
DECLARE existing androiddb_v0.agent_devices%ROWTYPE; e androiddb_v0.agent_enrollments%ROWTYPE;
BEGIN
  IF p_agent_device_id IS NULL
     OR coalesce(p_agent_token_hash,'') !~ '^[0-9a-f]{64}$'
     OR coalesce(p_pair_code_hash,'') !~ '^[0-9a-f]{64}$'
     OR length(coalesce(p_computer_name,''))>120
     OR length(coalesce(p_windows_version,''))>160
     OR length(coalesce(p_gpu_name,''))>160
     OR length(coalesce(p_agent_version,''))>80 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_ENROLL_INVALID';
  END IF;

  SELECT * INTO existing FROM androiddb_v0.agent_devices WHERE id=p_agent_device_id;
  IF FOUND THEN
    IF existing.agent_token_hash<>p_agent_token_hash OR existing.revoked_at IS NOT NULL THEN
      RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_IDENTITY_REJECTED';
    END IF;
    RETURN jsonb_build_object('ok',true,'paired',true,'agent_device_id',p_agent_device_id);
  END IF;

  INSERT INTO androiddb_v0.agent_enrollments(
    agent_device_id,agent_token_hash,pair_code_hash,computer_name,windows_version,gpu_name,agent_version,status,expires_at,last_request_at
  ) VALUES (
    p_agent_device_id,p_agent_token_hash,p_pair_code_hash,left(coalesce(p_computer_name,''),120),
    left(coalesce(p_windows_version,''),160),left(coalesce(p_gpu_name,''),160),
    left(coalesce(p_agent_version,''),80),'pending',now()+interval '15 minutes',now()
  )
  ON CONFLICT(agent_device_id) DO UPDATE SET
    agent_token_hash=EXCLUDED.agent_token_hash,pair_code_hash=EXCLUDED.pair_code_hash,
    computer_name=EXCLUDED.computer_name,windows_version=EXCLUDED.windows_version,
    gpu_name=EXCLUDED.gpu_name,agent_version=EXCLUDED.agent_version,
    status='pending',expires_at=now()+interval '15 minutes',last_request_at=now()
  WHERE androiddb_v0.agent_enrollments.status IN ('pending','expired');

  SELECT * INTO e FROM androiddb_v0.agent_enrollments WHERE agent_device_id=p_agent_device_id;
  IF NOT FOUND OR e.agent_token_hash<>p_agent_token_hash THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_ENROLL_CONFLICT';
  END IF;
  RETURN jsonb_build_object('ok',true,'paired',e.status='paired','status',e.status,
    'agent_device_id',p_agent_device_id,'expires_at',e.expires_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_pair(
  p_session_token text,p_pair_code text,p_display_name text,p_gpu_class text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','extensions','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; e androiddb_v0.agent_enrollments%ROWTYPE;
  pc androiddb_v0.rental_pcs%ROWTYPE; gpu text:=btrim(coalesce(p_gpu_class,''));
  rupiah integer; coin_units integer; label text:=btrim(coalesce(p_display_name,''));
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF length(btrim(coalesce(p_pair_code,'')))<>8 OR p_pair_code !~ '^[0-9]{8}$'
     OR length(label) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PAIR_INPUT_INVALID';
  END IF;
  CASE gpu
    WHEN 'GTX 1050' THEN rupiah:=6000; coin_units:=4500;
    WHEN 'GTX 1660' THEN rupiah:=6000; coin_units:=4500;
    WHEN 'RTX 3060' THEN rupiah:=7000; coin_units:=5250;
    WHEN 'RTX 5060' THEN rupiah:=8000; coin_units:=6000;
    ELSE RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_GPU_INVALID';
  END CASE;

  SELECT * INTO e FROM androiddb_v0.agent_enrollments
  WHERE pair_code_hash=encode(extensions.digest(p_pair_code,'sha256'),'hex')
    AND status='pending' AND expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_PAIR_CODE_INVALID_OR_EXPIRED'; END IF;
  IF EXISTS(SELECT 1 FROM androiddb_v0.agent_devices WHERE id=e.agent_device_id) THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_ALREADY_PAIRED';
  END IF;

  INSERT INTO androiddb_v0.rental_pcs(org_id,display_name,gpu_class,hourly_rupiah,hourly_coin_units)
  VALUES(a.org_id,label,gpu,rupiah,coin_units) RETURNING * INTO pc;
  INSERT INTO androiddb_v0.agent_devices(
    id,org_id,rental_pc_id,agent_token_hash,computer_name,windows_version,gpu_name,agent_version,status,last_heartbeat_at
  ) VALUES (
    e.agent_device_id,a.org_id,pc.id,e.agent_token_hash,e.computer_name,e.windows_version,e.gpu_name,e.agent_version,'offline',NULL
  );
  UPDATE androiddb_v0.agent_enrollments SET status='paired',approved_by=a.auth_user_id,
    approved_at=now(),rental_pc_id=pc.id WHERE id=e.id;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_paired',e.agent_device_id::text,
    jsonb_build_object('rental_pc_id',pc.id,'display_name',label,'gpu_class',gpu));
  RETURN jsonb_build_object('ok',true,'paired',true,'agent_device_id',e.agent_device_id,
    'rental_pc_id',pc.id,'display_name',label,'gpu_class',gpu,'hourly_rupiah',rupiah,
    'hourly_coins',coin_units::numeric/100);
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
        'hourly_coin_units',pc.hourly_coin_units,
        'hourly_coins',pc.hourly_coin_units::numeric/100,
        'status',CASE WHEN d.revoked_at IS NOT NULL OR d.status='revoked' THEN 'revoked'
          WHEN d.last_heartbeat_at>now()-interval '60 seconds' THEN 'online' ELSE 'offline' END,
        'last_heartbeat_at',d.last_heartbeat_at,'paired_at',d.paired_at,
        'enabled',pc.enabled,
        'active_commands',(SELECT count(*) FROM androiddb_v0.agent_commands c
          WHERE c.agent_device_id=d.id AND c.status IN ('queued','delivered','started') AND c.expires_at>now())
      ) AS item
    FROM androiddb_v0.agent_devices d
    JOIN androiddb_v0.rental_pcs pc ON pc.id=d.rental_pc_id
    WHERE d.org_id=a.org_id
  ) q;
  RETURN jsonb_build_object('ok',true,'agents',rows,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_update_pc(
  p_session_token text,p_agent_device_id uuid,p_display_name text,p_gpu_class text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; d androiddb_v0.agent_devices%ROWTYPE;
  gpu text:=btrim(coalesce(p_gpu_class,'')); label text:=btrim(coalesce(p_display_name,''));
  rupiah integer; coin_units integer;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF length(label) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_NAME_INVALID'; END IF;
  CASE gpu
    WHEN 'GTX 1050' THEN rupiah:=6000; coin_units:=4500;
    WHEN 'GTX 1660' THEN rupiah:=6000; coin_units:=4500;
    WHEN 'RTX 3060' THEN rupiah:=7000; coin_units:=5250;
    WHEN 'RTX 5060' THEN rupiah:=8000; coin_units:=6000;
    ELSE RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_GPU_INVALID';
  END CASE;
  SELECT * INTO d FROM androiddb_v0.agent_devices WHERE id=p_agent_device_id AND org_id=a.org_id AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_NOT_FOUND'; END IF;
  UPDATE androiddb_v0.rental_pcs SET display_name=label,gpu_class=gpu,
    hourly_rupiah=rupiah,hourly_coin_units=coin_units,updated_at=now()
  WHERE id=d.rental_pc_id;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_pc_updated',p_agent_device_id::text,
    jsonb_build_object('display_name',label,'gpu_class',gpu,'hourly_rupiah',rupiah,'hourly_coin_units',coin_units));
  RETURN jsonb_build_object('ok',true,'agent_device_id',p_agent_device_id,'display_name',label,
    'gpu_class',gpu,'hourly_rupiah',rupiah,'hourly_coins',coin_units::numeric/100);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_enqueue_command(
  p_session_token text,p_agent_device_id uuid,p_command text,p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; d androiddb_v0.agent_devices%ROWTYPE;
  cmd text:=lower(btrim(coalesce(p_command,''))); body jsonb:=coalesce(p_payload,'{}'::jsonb);
  command_id uuid; msg text;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  IF cmd NOT IN ('message','logoff','restart','shutdown') THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_COMMAND_INVALID'; END IF;
  SELECT * INTO d FROM androiddb_v0.agent_devices
  WHERE id=p_agent_device_id AND org_id=a.org_id AND revoked_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_NOT_FOUND'; END IF;
  IF d.last_heartbeat_at IS NULL OR d.last_heartbeat_at<=now()-interval '60 seconds' THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_OFFLINE';
  END IF;
  IF cmd='message' THEN
    msg:=btrim(coalesce(body->>'message',''));
    IF length(msg) NOT BETWEEN 1 AND 240 THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_MESSAGE_INVALID'; END IF;
    body:=jsonb_build_object('message',msg);
  ELSE
    body:='{}'::jsonb;
  END IF;
  INSERT INTO androiddb_v0.agent_commands(org_id,agent_device_id,command,payload,created_by,expires_at)
  VALUES(a.org_id,p_agent_device_id,cmd,body,a.auth_user_id,now()+interval '3 minutes')
  RETURNING id INTO command_id;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_command_queued',command_id::text,
    jsonb_build_object('agent_device_id',p_agent_device_id,'command',cmd));
  RETURN jsonb_build_object('ok',true,'command_id',command_id,'status','queued','command',cmd);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_command_status(
  p_session_token text,p_command_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE; c androiddb_v0.agent_commands%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  SELECT * INTO c FROM androiddb_v0.agent_commands
  WHERE id=p_command_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_COMMAND_NOT_FOUND'; END IF;
  IF c.status IN ('queued','delivered','started') AND c.expires_at<=now() THEN
    UPDATE androiddb_v0.agent_commands SET status='expired',completed_at=now()
      WHERE id=c.id RETURNING * INTO c;
  END IF;
  RETURN jsonb_build_object('ok',true,'command_id',c.id,'agent_device_id',c.agent_device_id,
    'command',c.command,'status',c.status,'result',c.result,'created_at',c.created_at,
    'delivered_at',c.delivered_at,'started_at',c.started_at,'completed_at',c.completed_at,'expires_at',c.expires_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_revoke(
  p_session_token text,p_agent_device_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','androiddb_v0','private','pg_catalog'
AS $function$
DECLARE a public.admin_accounts%ROWTYPE;
BEGIN
  a:=private.androiddb_v0_require_admin(p_session_token);
  UPDATE androiddb_v0.agent_devices SET revoked_at=now(),status='revoked',updated_at=now()
    WHERE id=p_agent_device_id AND org_id=a.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_NOT_FOUND'; END IF;
  UPDATE androiddb_v0.agent_commands SET status='expired',completed_at=now()
    WHERE agent_device_id=p_agent_device_id AND status IN ('queued','delivered','started');
  UPDATE androiddb_v0.agent_enrollments SET status='revoked'
    WHERE agent_device_id=p_agent_device_id;
  INSERT INTO androiddb_v0.audit_events(org_id,actor_family,actor_id,event_name,target_id)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'agent_revoked',p_agent_device_id::text);
  RETURN jsonb_build_object('ok',true,'agent_device_id',p_agent_device_id,'status','revoked');
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_heartbeat(
  p_agent_token text,p_agent_version text,p_computer_name text,p_windows_version text,p_gpu_name text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $function$
DECLARE d androiddb_v0.agent_devices%ROWTYPE; cmds jsonb;
BEGIN
  SELECT * INTO d FROM androiddb_v0.agent_devices
  WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
    AND revoked_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;
  UPDATE androiddb_v0.agent_devices SET status='online',last_heartbeat_at=now(),updated_at=now(),
    agent_version=left(coalesce(nullif(p_agent_version,''),agent_version),80),
    computer_name=left(coalesce(nullif(p_computer_name,''),computer_name),120),
    windows_version=left(coalesce(nullif(p_windows_version,''),windows_version),160),
    gpu_name=left(coalesce(nullif(p_gpu_name,''),gpu_name),160)
    WHERE id=d.id;
  UPDATE androiddb_v0.agent_commands SET status='expired',completed_at=now()
    WHERE agent_device_id=d.id AND status IN ('queued','delivered','started') AND expires_at<=now();
  WITH picked AS (
    SELECT id FROM androiddb_v0.agent_commands
    WHERE agent_device_id=d.id AND status='queued' AND expires_at>now()
    ORDER BY created_at,id LIMIT 10 FOR UPDATE SKIP LOCKED
  ), changed AS (
    UPDATE androiddb_v0.agent_commands c SET status='delivered',delivered_at=now()
    FROM picked p WHERE c.id=p.id RETURNING c.id,c.command,c.payload,c.expires_at
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'command',command,'payload',payload,'expires_at',expires_at)),'[]'::jsonb)
  INTO cmds FROM changed;
  RETURN jsonb_build_object('ok',true,'paired',true,'status','online','agent_device_id',d.id,
    'commands',cmds,'server_time',now());
END;
$function$;

CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_ack(
  p_agent_token text,p_command_id uuid,p_status text,p_result text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'androiddb_v0','pg_catalog'
AS $function$
DECLARE d androiddb_v0.agent_devices%ROWTYPE; c androiddb_v0.agent_commands%ROWTYPE;
  next_status text:=lower(btrim(coalesce(p_status,'')));
BEGIN
  SELECT * INTO d FROM androiddb_v0.agent_devices
  WHERE agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')
    AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_REVOKED_OR_UNPAIRED'; END IF;
  IF next_status NOT IN ('started','completed','failed') OR length(coalesce(p_result,''))>1000 THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_ACK_INVALID';
  END IF;
  SELECT * INTO c FROM androiddb_v0.agent_commands
  WHERE id=p_command_id AND agent_device_id=d.id FOR UPDATE;
  IF NOT FOUND OR c.status NOT IN ('delivered','started') OR c.expires_at<=now() THEN
    RAISE EXCEPTION 'ANDROIDDB_V0_AGENT_COMMAND_NOT_ACKABLE';
  END IF;
  UPDATE androiddb_v0.agent_commands SET status=next_status,result=left(coalesce(p_result,''),1000),
    started_at=CASE WHEN next_status='started' THEN coalesce(started_at,now()) ELSE started_at END,
    completed_at=CASE WHEN next_status IN ('completed','failed') THEN now() ELSE completed_at END
    WHERE id=c.id;
  RETURN jsonb_build_object('ok',true,'command_id',c.id,'status',next_status);
END;
$function$;

REVOKE ALL ON FUNCTION api.androiddb_v0_agent_enroll_request(uuid,text,text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_pair(text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_list(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_update_pc(text,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_enqueue_command(text,uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_command_status(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_admin_agent_revoke(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_agent_heartbeat(text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.androiddb_v0_agent_ack(text,uuid,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_enroll_request(uuid,text,text,text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_pair(text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_list(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_update_pc(text,uuid,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_enqueue_command(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_command_status(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_admin_agent_revoke(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_heartbeat(text,text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.androiddb_v0_agent_ack(text,uuid,text,text) TO ani_api_runtime;

COMMIT;
