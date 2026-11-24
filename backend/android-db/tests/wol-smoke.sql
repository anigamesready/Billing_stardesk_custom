-- Functional smoke test for migration 020. Run with ON_ERROR_STOP.
DO $$
DECLARE
  enrollment jsonb;
  registration jsonb;
  relay_token text;
  relay_id uuid;
  queued jsonb;
  command_id uuid;
  poll_result jsonb;
  ack jsonb;
  probe jsonb;
  probe_id uuid;
  probe_nonce uuid;
  probe_ack jsonb;
  probe_status jsonb;
  admin_status jsonb;
BEGIN
  enrollment := api.wol_relay_create_enrollment('test-admin-token');
  IF coalesce((enrollment->>'ok')::boolean,false) IS NOT TRUE OR length(enrollment->>'code') <> 12 THEN
    RAISE EXCEPTION 'ENROLLMENT_CREATE_FAILED';
  END IF;

  registration := api.wol_relay_register(
    enrollment->>'code','Relay Test','installation-12345678','1.0.0','Android Test'
  );
  relay_token := registration->>'relay_token';
  relay_id := (registration->>'relay_id')::uuid;
  IF relay_token IS NULL OR length(relay_token) <> 64 OR relay_id IS NULL THEN
    RAISE EXCEPTION 'RELAY_REGISTER_FAILED';
  END IF;

  admin_status := api.wol_relay_status('test-admin-token');
  IF admin_status->'relays'->0->>'status' <> 'online' THEN
    RAISE EXCEPTION 'RELAY_STATUS_FAILED';
  END IF;

  queued := api.wol_relay_enqueue(
    'test-admin-token','30000000-0000-4000-8000-000000000003'
  );
  command_id := (queued->>'command_id')::uuid;
  IF command_id IS NULL THEN RAISE EXCEPTION 'WOL_ENQUEUE_FAILED'; END IF;

  poll_result := api.wol_relay_poll(relay_token);
  IF poll_result->'command'->>'id' <> command_id::text THEN
    RAISE EXCEPTION 'WOL_COMMAND_NOT_DELIVERED';
  END IF;

  ack := api.wol_relay_ack(relay_token,command_id,'packet_sent','{"packet":"sent"}'::jsonb);
  IF ack->>'status' <> 'packet_sent' THEN RAISE EXCEPTION 'WOL_ACK_FAILED'; END IF;

  probe := api.wol_relay_probe_request('test-admin-token');
  probe_id := (probe->>'probe_id')::uuid;
  IF probe_id IS NULL THEN RAISE EXCEPTION 'WOL_PROBE_REQUEST_FAILED'; END IF;
  poll_result := api.wol_relay_poll(relay_token);
  probe_nonce := (poll_result->'probe'->>'nonce')::uuid;
  IF (poll_result->'probe'->>'id')::uuid <> probe_id OR probe_nonce IS NULL THEN
    RAISE EXCEPTION 'WOL_PROBE_NOT_DELIVERED';
  END IF;

  probe_ack := api.wol_relay_probe_ack(relay_token,probe_id,probe_nonce,
    '{"batteryPercent":82,"charging":true,"appVersion":"1.0.0","model":"Android Test"}'::jsonb);
  IF probe_ack->>'status' <> 'online' THEN RAISE EXCEPTION 'WOL_PROBE_ACK_FAILED'; END IF;

  probe_status := api.wol_relay_probe_status('test-admin-token',probe_id);
  IF probe_status->>'status' <> 'online' OR (probe_status->>'battery_percent')::integer <> 82 THEN
    RAISE EXCEPTION 'WOL_PROBE_STATUS_FAILED';
  END IF;

  IF (SELECT count(*) FROM public.devices WHERE id='30000000-0000-4000-8000-000000000003') <> 1 THEN
    RAISE EXCEPTION 'EXISTING_DEVICE_ROW_CHANGED';
  END IF;
  IF (SELECT count(*) FROM public.audit_logs WHERE action='android_wol_queued') <> 1 THEN
    RAISE EXCEPTION 'WOL_AUDIT_LOG_MISSING';
  END IF;
END $$;
