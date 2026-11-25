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

  test(app.name + ': pins only the fixed Android DB Gateway over Cloudflare IPv4', () => {
    assert.match(main, new RegExp(app.base + '\\s*='));
    assert.match(main, /openConnection\\(Proxy\\.NO_PROXY\\)/);
    assert.match(main, /setSSLSocketFactory\\(new GatewayPinnedSocketFactory\\(\\)\\)/);
    assert.match(main, /GatewayPinnedSocketFactory\\.isGatewayHost\\(hostname\\)/);
    assert.match(main, /getDefaultHostnameVerifier\\(\\)\\.verify/);
    assert.match(helper, /104\\.18\\.13\\.15/);
    assert.match(helper, /104\\.18\\.12\\.15/);
    assert.match(helper, /SNIHostName\\(GATEWAY_HOST\\)/);
    assert.match(helper, /delegate\\.createSocket\\(raw, GATEWAY_HOST, port, autoClose\\)/);
    assert.match(helper, /isPinnedIpv4Address\\(raw\\.getInetAddress\\(\\)\\)/);
    assert.match(helper, /candidate\\.connect\\(new InetSocketAddress\\(addressFor\\(value\\), HTTPS_PORT\\)/);
    assert.doesNotMatch(helper, /InetAddress\\.getByName/);
    assert.doesNotMatch(helper, /X509TrustManager|checkServerTrusted|ALLOW_ALL|trustAll/i);
    assert.doesNotMatch(main, /setHostnameVerifier\\([^;]*->\\s*true/);
  });

  test(app.name + ': keeps HTTPS hostname and uses a fresh package version', () => {
    assert.match(main, /ani-games-db-android-stage-gateway\\.anigamesready\\.workers\\.dev/);
    for (const item of app.version) assert.ok(gradle.includes(item), app.name + ' missing ' + item);
    assert.match(main, /setHostnameVerifier\\(\\(hostname, session\\) ->/);
  });
}
