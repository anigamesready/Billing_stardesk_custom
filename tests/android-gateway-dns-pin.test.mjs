import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const apps = [
  {
    name: 'Admin Android DB v0',
    main: 'admin-androiddb-v0/app/src/main/java/com/anigamesready/adminandroiddbv0/MainActivity.java',
    helper: 'admin-androiddb-v0/app/src/main/java/com/anigamesready/adminandroiddbv0/GatewayPinnedSocketFactory.java',
    gradle: 'admin-androiddb-v0/app/build.gradle',
    base: 'API_BASE',
    version: ['versionCode 9', 'versionName "0.2.7-userid-only-remote-login"'],
  },
  {
    name: 'Remote Android',
    main: 'android-client/app/src/main/java/com/anigamesready/stardeskclient/MainActivity.java',
    helper: 'android-client/app/src/main/java/com/anigamesready/stardeskclient/GatewayPinnedSocketFactory.java',
    gradle: 'android-client/app/build.gradle',
    base: 'ONLINE_API_BASE',
    version: ['versionCode 12', 'versionName "0.6.6-userid-only-login"'],
  },
];

for (const app of apps) {
  const main = readFileSync(app.main, 'utf8');
  const helper = readFileSync(app.helper, 'utf8');
  const gradle = readFileSync(app.gradle, 'utf8');

  test(app.name + ': pins the fixed Android DB Gateway to Cloudflare IPv4', () => {
    assert.ok(main.includes('private static final String ' + app.base), app.name + ' missing fixed API base');
    assert.ok(main.includes('openConnection(Proxy.NO_PROXY)'), app.name + ' must connect direct, not through an untrusted proxy');
    assert.ok(main.includes('setSSLSocketFactory(new GatewayPinnedSocketFactory())'), app.name + ' must use the pinned socket factory');
    assert.ok(main.includes('GatewayPinnedSocketFactory.isGatewayHost(hostname)'), app.name + ' must restrict the verified hostname');
    assert.ok(main.includes('getDefaultHostnameVerifier().verify'), app.name + ' must retain platform hostname verification');
    for (const token of [
      '104.18.13.15',
      '104.18.12.15',
      'SNIHostName(GATEWAY_HOST)',
      'delegate.createSocket(raw, GATEWAY_HOST, port, autoClose)',
      'isPinnedIpv4Address(raw.getInetAddress())',
      'candidate.connect(new InetSocketAddress(addressFor(value), HTTPS_PORT)',
    ]) assert.ok(helper.includes(token), app.name + ' missing TLS pin control: ' + token);
    assert.ok(!helper.includes('InetAddress.getByName'), app.name + ' must not resolve the broken Gateway hostname');
    for (const forbidden of ['X509TrustManager', 'checkServerTrusted', 'ALLOW_ALL', 'trustAll']) {
      assert.ok(!helper.includes(forbidden), app.name + ' contains forbidden trust bypass: ' + forbidden);
    }
    assert.ok(!main.includes('setHostnameVerifier((hostname, session) -> true)'), app.name + ' must not disable hostname verification');
  });

  test(app.name + ': preserves Gateway HTTPS hostname and uses a new APK version', () => {
    assert.ok(main.includes('ani-games-db-android-stage-gateway.anigamesready.workers.dev'));
    for (const item of app.version) assert.ok(gradle.includes(item), app.name + ' missing ' + item);
    assert.ok(main.includes('setHostnameVerifier((hostname, session) ->'));
    if (app.name === 'Admin Android DB v0') {
      const html = readFileSync('admin-androiddb-v0/app/src/main/assets/index.html', 'utf8');
      assert.ok(main.includes('connection.getHeaderField("Retry-After")'),
        'Admin native bridge must preserve the server login cooldown');
      assert.ok(html.includes('error.retryAfterSeconds=Number(data.retry_after_seconds)||0;') &&
        html.includes('error.code==="LOGIN_RATE_LIMITED"') &&
        html.includes('Percobaan login terlalu banyak'),
        'Admin login must show a localized and bounded cooldown message');
      assert.ok(html.includes('class="version">v0.2.7</div>'), 'Admin UI version label must match the APK');
    }
    if (app.name === 'Remote Android') {
      const html = readFileSync('android-client/app/src/main/assets/index.html', 'utf8');
      const gatewayBase = 'https://ani-games-db-android-stage-gateway.anigamesready.workers.dev/stardesk';
      assert.ok(main.includes('connection.getHeaderField("Retry-After")'),
        'Remote native bridge must preserve login cooldown timing');
      assert.ok(html.includes('error.retryAfterSeconds=Number(result?.retry_after_seconds)||0;') &&
        html.includes('err?.code==="LOGIN_RATE_LIMITED"') &&
        html.includes('LOGIN DIBATASI SEMENTARA'),
        'Remote login must show a localized and bounded cooldown message');
      assert.ok(html.includes('Host Agent PC berasal dari heartbeat Windows, terpisah dari Relay Agent Redmi'),
        'Remote UI must distinguish Windows Host Agent from Redmi Relay Agent');
      const worker = readFileSync('edge/cloudflare/ani-games-db-android-stage-ws-relay.mjs', 'utf8');
      assert.ok(main.includes('private static final String ONLINE_API_BASE = "' + gatewayBase + '";'),
        'Remote native bridge must use the isolated StarDesk route');
      assert.ok(html.includes('const ONLINE_API_BASE="' + gatewayBase + '";'),
        'Remote WebView must use the exact same isolated StarDesk route');
      assert.ok(main.includes('ONLINE_API_BASE.equals(value.trim())'),
        'native bridge must reject any API base that differs from its pinned route');
      assert.ok(worker.includes('const project = url.pathname.startsWith("/stardesk/");') &&
        worker.includes('const hubName = project ? STAR_DESK_HUB_NAME : HUB_NAME;'),
        'Gateway Worker must route /stardesk to the isolated StarDesk relay hub');
    }
  });
}


test('Admin Android DB v0: uses distinct Gateway health and API timeouts', () => {
  const main = readFileSync('admin-androiddb-v0/app/src/main/java/com/anigamesready/adminandroiddbv0/MainActivity.java', 'utf8');
  assert.ok(main.includes('connection.setReadTimeout("__gateway_health".equals(route) ? 15000 : 40000);'));
  assert.ok(main.includes('getAppVersion() { return "0.2.7-userid-only-remote-login"; }'));
});

test('Remote UI has only User ID login and does not show Admin activation flow', () => {
  const html = readFileSync('android-client/app/src/main/assets/index.html', 'utf8');
  const admin = readFileSync('admin-androiddb-v0/app/src/main/assets/index.html', 'utf8');
  assert.ok(html.includes('Masuk cukup dengan User ID rental yang terdaftar.'));
  for (const forbidden of ['activationCode','p_activation_code','Kode Aktivasi','Kode dari Admin','issueActivation']) {
    assert.ok(!html.includes(forbidden), 'Remote login activation regression: ' + forbidden);
  }
  assert.ok(html.includes('p_rental_code:rentalCode,p_client_install_id:clientId'));
  for (const forbidden of ['issueActivation','androiddb_v0_admin_issue_activation','activation_issued','Kode Remote']) {
    assert.ok(!admin.includes(forbidden), 'Admin activation workflow reintroduced: ' + forbidden);
  }
});
