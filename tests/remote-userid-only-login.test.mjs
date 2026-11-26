import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const remote = readFileSync('android-client/app/src/main/assets/index.html', 'utf8');
const admin = readFileSync('admin-androiddb-v0/app/src/main/assets/index.html', 'utf8');
const server = readFileSync('backend/android-db/server/server.mjs', 'utf8');
const migration = readFileSync('backend/android-db/migrations/027_androiddb_v0_remote_userid_only_login.sql', 'utf8');
const coinTest = readFileSync('backend/android-db/tests/020_androiddb_v0_coin_x100_smoke.sql', 'utf8');

test('Remote login screen accepts User ID only and never asks for Admin activation', () => {
  const start = remote.indexOf('<section id="login"');
  const end = remote.indexOf('<section id="dashboard"', start);
  assert.ok(start >= 0 && end > start, 'Remote login section must exist');
  const loginScreen = remote.slice(start, end);
  assert.ok(loginScreen.includes('id="uid"'), 'rental User ID field is required');
  assert.ok(!loginScreen.includes('type="password"'), 'renter login must not add a password field');
  for (const forbidden of ['activationCode', 'p_activation_code', 'Kode Aktivasi', 'Kode dari Admin',
    'diaktivasi oleh Admin', 'issueActivation']) {
    assert.ok(!remote.includes(forbidden), 'Admin activation flow reappeared in Remote UI: ' + forbidden);
  }
  assert.ok(remote.includes('Masuk cukup dengan User ID rental yang terdaftar.'));
  assert.ok(remote.includes('nativeRpc("androiddb_v0_remote_login",{p_rental_code:rentalCode,p_client_install_id:clientId},"")'));
});

test('Admin no longer issues a Remote activation code', () => {
  for (const forbidden of ['issueActivation', 'androiddb_v0_admin_issue_activation',
    'activation_issued', 'Kode Remote', 'KODE AKTIVASI REMOTE']) {
    assert.ok(!admin.includes(forbidden), 'Admin activation control remains: ' + forbidden);
  }
  assert.ok(admin.includes('Remote login: '+ '(r.client_logged_in?'));
});

test('Android DB API accepts User ID plus app-generated install ID and rate-limits attempts', () => {
  const start = server.indexOf('if (name === "androiddb_v0_remote_login")');
  const end = server.indexOf('if (name === "androiddb_v0_host_enroll")', start);
  assert.ok(start >= 0 && end > start, 'dedicated Android DB Remote login route must exist');
  const route = server.slice(start, end);
  assert.ok(route.includes('callRateLimit(key,5)'), 'retain brute-force protection');
  assert.ok(route.includes('api.androiddb_v0_remote_login($1::text,$2::text)'),
    'backend must call the two-argument User ID-only RPC');
  assert.ok(route.includes('p_client_install_id'));
  assert.ok(!route.includes('p_activation_code'));
  assert.ok(!server.includes('androiddb_v0_admin_issue_activation:'), 'Admin activation RPC must not be allowlisted');
});

test('Database migration removes activation table/functions and exposes only two-argument User ID login', () => {
  for (const token of [
    'DROP FUNCTION IF EXISTS api.androiddb_v0_admin_issue_activation(text,uuid)',
    'DROP FUNCTION IF EXISTS api.androiddb_v0_remote_login(text,text,text)',
    'DROP TABLE IF EXISTS androiddb_v0.client_credentials',
    'CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_login(',
    'p_rental_code text,p_client_install_id text',
    'GRANT EXECUTE ON FUNCTION api.androiddb_v0_remote_login(text,text) TO ani_api_runtime',
    "r.status<>'active'",
    'client_login_userid_only',
  ]) assert.ok(migration.includes(token), 'missing User ID-only database contract: ' + token);
  for (const forbidden of ['p_activation_code', 'activation_code',
    'CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_issue_activation',
    'UPDATE androiddb_v0.client_credentials', 'INSERT INTO androiddb_v0.client_credentials']) {
    assert.ok(!migration.includes(forbidden), 'old activation implementation remains in migration: ' + forbidden);
  }
});

test('PostgreSQL regression proves activation removal and single active session per rental', () => {
  for (const token of [
    "api.androiddb_v0_remote_login('V0-X100-TEST','v0-x100-ci-android')",
    "api.androiddb_v0_remote_login('V0-X100-TEST','v0-x100-ci-android-second')",
    'ANDROIDDB_V0_USERID_ONLY_LOGIN_CONTRACT_FAILED',
    'ANDROIDDB_V0_PREVIOUS_CLIENT_SESSION_NOT_REVOKED',
    "to_regclass('androiddb_v0.client_credentials') IS NOT NULL",
  ]) assert.ok(coinTest.includes(token), 'missing User ID-only SQL regression: ' + token);
  assert.ok(!coinTest.includes('api.androiddb_v0_admin_issue_activation('));
  assert.ok(!coinTest.includes('p_activation_code'));
});
