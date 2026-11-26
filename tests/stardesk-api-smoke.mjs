import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const base = "http://127.0.0.1:8789";
const env = {
  ...process.env,
  ANI_BIND: "127.0.0.1",
  PORT: "8789",
  ANI_API_PEPPER: "ci-smoke-pepper-which-is-longer-than-32-characters",
  ANI_ADMIN_BOOTSTRAP_TOKEN: "ci-smoke-bootstrap-token-which-is-long-enough-64",
  BLYNK_AUTH_TOKEN: "",
  BLYNK_POWER_PIN: "V0",
};
const child = spawn(process.execPath, ["server.mjs"], {
  cwd: "backend/android-db/server",
  env,
  stdio: ["ignore", "pipe", "pipe"],
});
let output = "";
child.stdout.on("data", chunk => { output += chunk.toString(); });
child.stderr.on("data", chunk => { output += chunk.toString(); });

async function waitForHealth() {
  for (let attempt = 0; attempt < 30; attempt++) {
    if (child.exitCode !== null) throw new Error("API process exited before health: " + output.slice(-3000));
    try {
      const response = await fetch(base + "/health", { signal: AbortSignal.timeout(1500) });
      if (response.ok) {
        const health = await response.json();
        assert.equal(health.api, "online");
        assert.equal(health.database, "online");
        return;
      }
    } catch {}
    await delay(500);
  }
  throw new Error("API health timeout: " + output.slice(-3000));
}

try {
  await waitForHealth();

  const bootstrap = await fetch(base + "/api/admin/bootstrap", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "stardesk-owner-smoke",
      password: "StarDesk-Smoke-Pass-2026!",
      org_name: "StarDesk CI Smoke",
    }),
  });
  const bootstrapBody = await bootstrap.json();
  assert.equal(bootstrap.status, 200, "Owner bootstrap failed: " + JSON.stringify(bootstrapBody));
  assert.equal(bootstrapBody.ok, true);

  const login = await fetch(base + "/auth/v1/token?grant_type=password", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "stardesk-owner-smoke",
      password: "StarDesk-Smoke-Pass-2026!",
    }),
  });
  const loginBody = await login.json();
  assert.equal(login.status, 200, "Admin password login failed: " + JSON.stringify(loginBody));
  assert.ok(loginBody.access_token, "Missing Admin access token");
  assert.equal(loginBody.user?.app_metadata?.role, "SUPER_ADMIN");

  const context = await fetch(base + "/rest/v1/rpc/admin_context", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer " + loginBody.access_token,
    },
    body: "{}",
  });
  const contextBody = await context.json();
  assert.equal(context.status, 200, "Admin context RPC failed: " + JSON.stringify(contextBody));
  assert.ok(contextBody && typeof contextBody === "object", "Admin context response is not an object");
  assert.ok(Array.isArray(contextBody.orgs) && contextBody.orgs.length > 0,
    "Admin Owner has no organization context");

  const logout = await fetch(base + "/auth/v1/logout", {
    method: "POST",
    headers: { authorization: "Bearer " + loginBody.access_token },
  });
  assert.equal(logout.status, 204, "Admin logout failed");

  process.stdout.write("[STAR-DESK-API-SMOKE] PASS: local Owner bootstrap, Admin password login, admin_context RPC, and logout\n");
} finally {
  child.kill("SIGTERM");
  await Promise.race([
    new Promise(resolve => child.once("exit", resolve)),
    delay(3000),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}
