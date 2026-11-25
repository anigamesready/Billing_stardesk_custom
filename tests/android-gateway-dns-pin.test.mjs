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
    version: ['versionCode 3', 'versionName "0.2.1-gateway-dns-pin"'],
  },
  {
    name: 'Remote Android',
    main: 'android-client/app/src/main/java/com/anigamesready/stardeskclient/MainActivity.java',
    helper: 'android-client/app/src/main/java/com/anigamesready/stardeskclient/GatewayPinnedSocketFactory.java',
    gradle: 'android-client/app/build.gradle',
    base: 'ONLINE_API_BASE',
    version: ['versionCode 7', 'versionName "0.6.1-androiddb-v0-coin-gateway-pin"'],
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
  });
}
