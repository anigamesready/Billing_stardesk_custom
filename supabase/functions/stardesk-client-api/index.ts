import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: cors });

const supabaseUrl = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
const serviceKey =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SUPABASE_SECRET_KEY") ||
  (() => {
    try {
      const values = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
      return typeof values.default === "string" ? values.default : "";
    } catch {
      return "";
    }
  })();

const admin = supabaseUrl && serviceKey
  ? createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    })
  : null;

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

async function sha256(value: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

function randomToken(): string {
  return hex(crypto.getRandomValues(new Uint8Array(32)));
}

function secondsLeft(value: unknown): number {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? Math.max(0, Math.floor(parsed)) : 0;
}

function rentalState(rental: any, nowMs = Date.now()) {
  const remaining = secondsLeft(rental?.remaining_seconds);
  const expiry = rental?.expiry_at ? Date.parse(rental.expiry_at) : null;
  if (rental?.status === "disabled") return { state: "disabled", canPlay: false, remaining };
  if (rental?.status !== "active") return { state: "expired", canPlay: false, remaining };
  if (expiry !== null && Number.isFinite(expiry) && expiry <= nowMs) {
    return { state: "expired", canPlay: false, remaining };
  }
  if (remaining <= 0) return { state: "time_empty", canPlay: false, remaining };
  return { state: "active", canPlay: true, remaining };
}

async function consumeLimit(bucket: string, max: number) {
  if (!admin) throw new Error("SERVICE_UNAVAILABLE");
  const keyHash = await sha256(serviceKey + "|stardesk-client|" + bucket);
  const { data, error } = await admin.schema("api").rpc("device_pairing_rate_limit_consume", {
    p_key_hash: keyHash,
    p_max_attempts: max,
  });
  if (error || !data) throw new Error("RATE_LIMIT_SERVICE_UNAVAILABLE");
  if (data.allowed !== true) return Math.max(1, Math.min(900, Number(data.retry_after_seconds) || 60));
  return 0;
}

async function rentalByCode(code: string) {
  if (!admin) throw new Error("SERVICE_UNAVAILABLE");
  const { data, error } = await admin
    .from("rental_accounts")
    .select("id,org_id,code,status,remaining_seconds,expiry_at,client_label")
    .ilike("code", code)
    .limit(2);
  if (error) throw new Error("RENTAL_LOOKUP_UNAVAILABLE");
  if (!data || data.length === 0) throw new Error("RENTAL_NOT_FOUND");
  if (data.length > 1) throw new Error("RENTAL_CODE_AMBIGUOUS");
  return data[0];
}

async function ownerOrgId(orgId: string): Promise<string> {
  if (!admin) throw new Error("SERVICE_UNAVAILABLE");
  let current = orgId;
  for (let depth = 0; depth < 8; depth++) {
    const { data, error } = await admin
      .from("organizations")
      .select("id,kind,parent_org_id,status")
      .eq("id", current)
      .maybeSingle();
    if (error || !data) throw new Error("ORGANIZATION_LOOKUP_UNAVAILABLE");
    if (data.status !== "active") throw new Error("ORGANIZATION_SUSPENDED");
    if (data.kind === "owner" || !data.parent_org_id) return data.id;
    current = data.parent_org_id;
  }
  throw new Error("ORGANIZATION_HIERARCHY_INVALID");
}

async function findClientSession(token: string) {
  if (!admin || token.length !== 64 || !/^[0-9a-f]{64}$/i.test(token)) return null;
  const tokenHash = await sha256(token);
  const { data, error } = await admin
    .from("stardesk_client_sessions")
    .select("id,rental_account_id,org_id,client_id,device_name,expires_at,revoked_at")
    .eq("token_hash", tokenHash)
    .is("revoked_at", null)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (error || !data) return null;
  return { ...data, tokenHash };
}

async function login(body: any, req: Request) {
  const code = String(body.userId ?? "").trim().toUpperCase();
  const clientId = String(body.clientId ?? "").trim();
  const deviceName = String(body.deviceName ?? "Android client").trim().slice(0, 120) || "Android client";
  const appVersion = String(body.appVersion ?? "0.1.0").trim().slice(0, 64);
  if (!/^[A-Z0-9-]{4,80}$/.test(code) || clientId.length < 8 || clientId.length > 128) {
    return json(400, { ok: false, error: "INVALID_REQUEST" });
  }
  const ip = (req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip") || "").trim().slice(0, 128);
  const [codeWait, clientWait, ipWait] = await Promise.all([
    consumeLimit("code|" + code, 5),
    consumeLimit("client|" + clientId.toUpperCase(), 8),
    ip ? consumeLimit("ip|" + ip, 40) : Promise.resolve(0),
  ]);
  const wait = Math.max(codeWait, clientWait, ipWait);
  if (wait > 0) return new Response(JSON.stringify({ ok: false, error: "TOO_MANY_ATTEMPTS" }), {
    status: 429, headers: { ...cors, "Retry-After": String(wait) },
  });

  const rental = await rentalByCode(code);
  const gate = rentalState(rental);
  const token = randomToken();
  const tokenHash = await sha256(token);
  const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
  const { error: insertError } = await admin!.from("stardesk_client_sessions").insert({
    rental_account_id: rental.id,
    org_id: rental.org_id,
    client_id: clientId,
    device_name: deviceName,
    app_version: appVersion,
    token_hash: tokenHash,
    expires_at: expiresAt,
  });
  if (insertError) throw new Error("CLIENT_SESSION_CREATE_FAILED");

  return json(200, {
    ok: true,
    clientToken: token,
    userId: rental.code,
    rental: {
      status: rental.status,
      accessState: gate.state,
      canPlay: gate.canPlay,
      remainingSeconds: gate.remaining,
      expiryAt: rental.expiry_at,
    },
    serverTime: new Date().toISOString(),
  });
}

async function catalog(body: any) {
  const token = String(body.clientToken ?? "");
  const session = await findClientSession(token);
  if (!session) return json(401, { ok: false, error: "CLIENT_SESSION_INVALID" });

  const [{ data: rental, error: rentalError }, rootOrg] = await Promise.all([
    admin!.from("rental_accounts")
      .select("id,org_id,code,status,remaining_seconds,expiry_at,client_label")
      .eq("id", session.rental_account_id)
      .maybeSingle(),
    ownerOrgId(session.org_id),
  ]);
  if (rentalError || !rental) return json(401, { ok: false, error: "RENTAL_NOT_FOUND" });

  const gate = rentalState(rental);
  const now = Date.now();
  const onlineWindowMs = 45_000;
  const { data: rawDevices, error: deviceError } = await admin!
    .from("devices")
    .select("id,device_name,status,power_state,last_seen_at,last_heartbeat_at,metadata")
    .eq("org_id", rootOrg)
    .neq("status", "disabled")
    .order("device_name", { ascending: true });
  if (deviceError) throw new Error("PC_LIST_UNAVAILABLE");

  const devices = (rawDevices || []).filter((device: any) =>
    !device?.metadata?.pairingDuplicateArchivedAt
  );
  const ids = devices.map((device: any) => device.id);

  let busyIds = new Set<string>();
  if (ids.length > 0) {
    const { data: activeLocal, error: localError } = await admin!
      .from("rental_sessions")
      .select("device_id")
      .in("device_id", ids)
      .in("status", ["active", "paused"]);
    if (localError) throw new Error("PC_STATUS_UNAVAILABLE");
    for (const row of activeLocal || []) if (row.device_id) busyIds.add(row.device_id);

    try {
      const { data: remoteActive } = await admin!
        .schema("remote_play")
        .from("sessions")
        .select("host_device_id")
        .in("host_device_id", ids)
        .in("status", ["starting", "active", "stopping"]);
      for (const row of remoteActive || []) if (row.host_device_id) busyIds.add(row.host_device_id);
    } catch (_) {
      // Optional remote-play schema read: public rental session state remains authoritative for local use.
    }
  }

  const pcs = devices.map((device: any) => {
    const beat = device.last_heartbeat_at ? Date.parse(device.last_heartbeat_at) : 0;
    const online = device.status === "online" && beat > 0 && now - beat <= onlineWindowMs;
    const busy = busyIds.has(device.id);
    const status = !online ? "offline" : busy ? "active" : "ready";
    const metadata = device.metadata && typeof device.metadata === "object" ? device.metadata : {};
    const displayName = String(metadata.custom_device_name || device.device_name || "PC").slice(0, 80);
    // Mapping and Remote Assist host credentials are deliberately not exposed in the catalog API.
    return {
      id: device.id,
      name: displayName,
      status,
      powerState: String(device.power_state || "unknown"),
      lastSeenAt: device.last_seen_at,
      active: busy,
      engineReady: false,
      connectEnabled: false,
      connectMessage: "Host StarDesk belum dipasangkan",
    };
  });

  await admin!.from("stardesk_client_sessions")
    .update({ last_seen_at: new Date().toISOString() })
    .eq("id", session.id);

  return json(200, {
    ok: true,
    userId: rental.code,
    rental: {
      status: rental.status,
      accessState: gate.state,
      canPlay: gate.canPlay,
      remainingSeconds: gate.remaining,
      expiryAt: rental.expiry_at,
    },
    counts: {
      ready: pcs.filter((pc: any) => pc.status === "ready").length,
      active: pcs.filter((pc: any) => pc.status === "active").length,
      offline: pcs.filter((pc: any) => pc.status === "offline").length,
    },
    pcs,
    serverTime: new Date().toISOString(),
  });
}

async function logout(body: any) {
  const token = String(body.clientToken ?? "");
  const session = await findClientSession(token);
  if (!session) return json(200, { ok: true });
  const { error } = await admin!.from("stardesk_client_sessions")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", session.id);
  if (error) throw new Error("LOGOUT_FAILED");
  return json(200, { ok: true });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });
  if (!admin) return json(503, { ok: false, error: "SERVICE_UNAVAILABLE" });

  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, "").split("/").pop() || "";
  try {
    const raw = await req.text();
    if (raw.length > 16_384) return json(413, { ok: false, error: "REQUEST_TOO_LARGE" });
    let body: any;
    try { body = JSON.parse(raw); } catch { return json(400, { ok: false, error: "INVALID_JSON" }); }

    if (path === "login") return await login(body, req);
    if (path === "catalog") return await catalog(body);
    if (path === "logout") return await logout(body);
    return json(404, { ok: false, error: "NOT_FOUND" });
  } catch (error) {
    const message = error instanceof Error ? error.message : "REQUEST_FAILED";
    const known: Record<string, number> = {
      RENTAL_NOT_FOUND: 404,
      RENTAL_CODE_AMBIGUOUS: 409,
      ORGANIZATION_SUSPENDED: 403,
      TOO_MANY_ATTEMPTS: 429,
      RATE_LIMIT_SERVICE_UNAVAILABLE: 503,
    };
    return json(known[message] || 400, { ok: false, error: message });
  }
});
