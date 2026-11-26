package com.anigamesready.adminandroiddbv0;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Color;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.Toast;
import android.text.InputType;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.net.Proxy;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.net.ssl.HttpsURLConnection;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

public final class MainActivity extends Activity {
    private static final String API_BASE =
        "https://ani-games-db-android-stage-gateway.anigamesready.workers.dev/stardesk";
    private static final String KEY_ALIAS = "ani_admin_androiddb_v0_keystore_v1";
    private static final String SECURE_PREFS = "ani_admin_androiddb_v0_secure";
    private static final int MAX_RESPONSE_BYTES = 1024 * 1024;
    private WebView webView;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setStatusBarColor(Color.rgb(7,16,31));
        getWindow().setNavigationBarColor(Color.rgb(7,16,31));
        webView = new WebView(this);
        webView.setBackgroundColor(Color.rgb(7,16,31));
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(false);
        settings.setAllowFileAccess(true);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        webView.addJavascriptInterface(new AdminBridge(), "AniAdminV0");
        webView.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return true;
            }
        });
        // Admin UI relies on confirm()/prompt() for destructive and financial actions.
        // Handle JavaScript dialogs natively so these actions remain usable inside WebView.
        webView.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
                new AlertDialog.Builder(MainActivity.this)
                    .setTitle("Ani Games Admin")
                    .setMessage(message == null ? "" : message)
                    .setPositiveButton("OK", (dialog, which) -> result.confirm())
                    .setOnCancelListener(dialog -> result.cancel())
                    .show();
                return true;
            }

            @Override public boolean onJsConfirm(WebView view, String url, String message, JsResult result) {
                new AlertDialog.Builder(MainActivity.this)
                    .setTitle("Konfirmasi Admin")
                    .setMessage(message == null ? "" : message)
                    .setPositiveButton("Lanjutkan", (dialog, which) -> result.confirm())
                    .setNegativeButton("Batal", (dialog, which) -> result.cancel())
                    .setOnCancelListener(dialog -> result.cancel())
                    .show();
                return true;
            }

            @Override public boolean onJsPrompt(WebView view, String url, String message,
                                                String defaultValue, JsPromptResult result) {
                EditText input = new EditText(MainActivity.this);
                input.setSingleLine(true);
                input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
                if (defaultValue != null) input.setText(defaultValue);
                new AlertDialog.Builder(MainActivity.this)
                    .setTitle("Input Admin")
                    .setMessage(message == null ? "" : message)
                    .setView(input)
                    .setPositiveButton("Simpan", (dialog, which) -> result.confirm(input.getText().toString()))
                    .setNegativeButton("Batal", (dialog, which) -> result.cancel())
                    .setOnCancelListener(dialog -> result.cancel())
                    .show();
                return true;
            }
        });
        setContentView(webView);
        webView.loadUrl("file:///android_asset/index.html");
    }

    private SecretKey getOrCreateKey() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(KEY_ALIAS)) return (SecretKey) store.getKey(KEY_ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build());
        return generator.generateKey();
    }

    private android.content.SharedPreferences securePrefs() {
        return getSharedPreferences(SECURE_PREFS, MODE_PRIVATE);
    }

    private void saveSecret(String name, String value) throws Exception {
        if (name == null || !name.matches("[a-zA-Z0-9_.-]{1,80}"))
            throw new IllegalArgumentException("SECURE_KEY_INVALID");
        if (value == null || value.length() > 4096)
            throw new IllegalArgumentException("SECURE_VALUE_INVALID");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey());
        byte[] iv = cipher.getIV();
        byte[] encrypted = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
        byte[] all = new byte[iv.length + encrypted.length];
        System.arraycopy(iv, 0, all, 0, iv.length);
        System.arraycopy(encrypted, 0, all, iv.length, encrypted.length);
        securePrefs().edit().putString(name, Base64.encodeToString(all, Base64.NO_WRAP)).apply();
    }

    private String readSecret(String name) {
        try {
            if (name == null || !name.matches("[a-zA-Z0-9_.-]{1,80}")) return "";
            String value = securePrefs().getString(name, "");
            if (value.isEmpty()) return "";
            byte[] all = Base64.decode(value, Base64.NO_WRAP);
            if (all.length <= 12) throw new IllegalArgumentException("SECURE_VALUE_CORRUPT");
            byte[] iv = new byte[12];
            byte[] encrypted = new byte[all.length - 12];
            System.arraycopy(all, 0, iv, 0, 12);
            System.arraycopy(all, 12, encrypted, 0, encrypted.length);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), new GCMParameterSpec(128, iv));
            return new String(cipher.doFinal(encrypted), StandardCharsets.UTF_8);
        } catch (Exception ex) {
            if (name != null) securePrefs().edit().remove(name).apply();
            return "";
        }
    }

    private JSONObject parseResponse(String text) throws JSONException {
        Object value = new JSONTokener(text == null || text.trim().isEmpty() ? "{}" : text).nextValue();
        if (value instanceof JSONObject) return (JSONObject) value;
        if (value instanceof JSONArray) return new JSONObject().put("data", value);
        return new JSONObject().put("data", value);
    }

    private JSONObject error(String code, String message) {
        JSONObject result = new JSONObject();
        try {
            result.put("ok", false);
            result.put("error", code);
            result.put("message", message == null ? code : message);
        } catch (JSONException ignored) {}
        return result;
    }

    private String readBounded(InputStream input) throws Exception {
        if (input == null) return "{}";
        try (InputStream in = input; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int total = 0, count;
            while ((count = in.read(buffer)) != -1) {
                total += count;
                if (total > MAX_RESPONSE_BYTES) throw new IllegalStateException("API_RESPONSE_TOO_LARGE");
                out.write(buffer, 0, count);
            }
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    private void deliver(String requestId, JSONObject response) {
        if (webView == null) return;
        final String script = "window.__adminV0Result&&window.__adminV0Result("
            + JSONObject.quote(requestId) + "," + response.toString() + ");";
        runOnUiThread(() -> {
            if (webView != null) webView.evaluateJavascript(script, null);
        });
    }

    private void executeRequest(String route, String body, String token, String requestId) {
        executor.execute(() -> {
            HttpsURLConnection connection = null;
            try {
                if (route == null || route.length() > 100) throw new IllegalArgumentException("API_ROUTE_INVALID");
                final String path;
                if ("__admin_login".equals(route)) {
                    path = "/auth/v1/token?grant_type=password";
                } else if ("__admin_refresh".equals(route)) {
                    path = "/auth/v1/token?grant_type=refresh_token";
                } else if ("__admin_logout".equals(route)) {
                    path = "/auth/v1/logout";
                } else if ("__iot_status".equals(route)) {
                    path = "/iot/status";
                } else if ("__iot_power".equals(route)) {
                    path = "/iot/power";
                } else if ("__gateway_health".equals(route)) {
                    path = "/_ani_gateway/health";
                } else {
                    if (!route.matches("[a-z0-9_]{1,80}")) throw new IllegalArgumentException("RPC_NAME_INVALID");
                    path = "/rest/v1/rpc/" + route;
                }
                if (body == null || body.length() > 32768) throw new IllegalArgumentException("API_BODY_TOO_LARGE");
                final String method = ("__iot_status".equals(route) || "__gateway_health".equals(route)) ? "GET" : "POST";
                connection = (HttpsURLConnection) new URL(API_BASE + path).openConnection(Proxy.NO_PROXY);
                connection.setSSLSocketFactory(new GatewayPinnedSocketFactory());
                connection.setHostnameVerifier((hostname, session) ->
                    GatewayPinnedSocketFactory.isGatewayHost(hostname)
                        && HttpsURLConnection.getDefaultHostnameVerifier().verify(
                            GatewayPinnedSocketFactory.GATEWAY_HOST, session));
                connection.setRequestMethod(method);
                connection.setConnectTimeout(10000);
                connection.setReadTimeout("__gateway_health".equals(route) ? 15000 : 40000);
                connection.setInstanceFollowRedirects(false);
                connection.setDoOutput(!"GET".equals(method));
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                connection.setRequestProperty("Accept", "application/json");
                if (token != null && !token.trim().isEmpty()) {
                    if (token.length() > 512) throw new IllegalArgumentException("ACCESS_TOKEN_INVALID");
                    connection.setRequestProperty("Authorization", "Bearer " + token.trim());
                }
                if (!"GET".equals(method)) {
                    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
                    connection.setFixedLengthStreamingMode(bytes.length);
                    try (OutputStream output = connection.getOutputStream()) { output.write(bytes); }
                }
                int status = connection.getResponseCode();
                InputStream stream = status >= 200 && status < 400
                    ? connection.getInputStream() : connection.getErrorStream();
                JSONObject result = parseResponse(readBounded(stream));
                result.put("http_status", status);
                String retryAfterHeader = connection.getHeaderField("Retry-After");
                if (retryAfterHeader != null) {
                    try {
                        int retryAfterSeconds = Integer.parseInt(retryAfterHeader.trim());
                        if (retryAfterSeconds > 0) result.put("retry_after_seconds", Math.min(900, retryAfterSeconds));
                    } catch (NumberFormatException ignored) { }
                }
                if (status < 200 || status >= 300) result.put("ok", false);
                deliver(requestId, result);
            } catch (Exception ex) {
                String message = ex instanceof java.net.SocketTimeoutException
                    ? "GATEWAY_TIMEOUT: Gateway/Relay tidak memberi jawaban dalam batas waktu."
                    : (ex.getMessage() == null ? "ANDROID_DB_API_ERROR" : ex.getMessage());
                deliver(requestId, error(message, message));
            } finally {
                if (connection != null) connection.disconnect();
            }
        });
    }

    public final class AdminBridge {
        @JavascriptInterface public String getAppVersion() { return "0.2.5-coin-first-pc-control"; }
        @JavascriptInterface public String getApiBase() { return API_BASE; }
        @JavascriptInterface public String getSecureValue(String key) { return readSecret(key); }
        @JavascriptInterface public boolean saveSecureValue(String key, String value) {
            try { saveSecret(key, value); return true; } catch (Exception ex) { return false; }
        }
        @JavascriptInterface public void clearSecureValue(String key) {
            if (key != null && key.matches("[a-zA-Z0-9_.-]{1,80}"))
                securePrefs().edit().remove(key).apply();
        }
        @JavascriptInterface public void apiRequest(String route, String body, String token, String requestId) {
            if (requestId == null || requestId.length() > 100) return;
            executeRequest(route, body, token, requestId);
        }
        @JavascriptInterface public void copyText(String value) {
            runOnUiThread(() -> {
                try {
                    ClipboardManager manager = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    manager.setPrimaryClip(ClipData.newPlainText("Admin Android DB v0", value == null ? "" : value));
                    Toast.makeText(MainActivity.this, "Berhasil disalin", Toast.LENGTH_SHORT).show();
                } catch (Exception ex) {
                    Toast.makeText(MainActivity.this, "Gagal menyalin teks", Toast.LENGTH_SHORT).show();
                }
            });
        }
    }

    @Override protected void onDestroy() {
        executor.shutdownNow();
        if (webView != null) {
            webView.stopLoading();
            webView.loadUrl("about:blank");
            webView.removeAllViews();
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
