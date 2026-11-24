package com.anigamesready.stardeskclient;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    private WebView webView;
    private String clientId;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getWindow().setStatusBarColor(Color.rgb(9, 9, 31));
        getWindow().setNavigationBarColor(Color.rgb(9, 9, 31));
        getWindow().getDecorView().setSystemUiVisibility(0);

        String androidId = Settings.Secure.getString(getContentResolver(), Settings.Secure.ANDROID_ID);
        clientId = "android-" + (androidId == null ? "unknown-device" : androidId.toLowerCase());

        webView = new WebView(this);
        webView.setBackgroundColor(Color.rgb(9, 9, 31));
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setLoadsImagesAutomatically(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);

        webView.addJavascriptInterface(new AndroidBridge(), "AniAndroid");
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return openExternal(request.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return openExternal(Uri.parse(url));
            }
        });

        setContentView(webView);
        try {
            InputStream input = getAssets().open("index.html");
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int length;
            while ((length = input.read(buffer)) != -1) output.write(buffer, 0, length);
            input.close();
            String html = output.toString(StandardCharsets.UTF_8.name());
            // A synthetic HTTPS base origin allows secure HTTPS API requests without file:// access.
            webView.loadDataWithBaseURL(
                "https://appassets.androidplatform.net/",
                html,
                "text/html",
                "UTF-8",
                null
            );
        } catch (Exception error) {
            webView.loadData(
                "<html><body style='background:#09091f;color:white;font-family:sans-serif;padding:24px'>"
                    + "<h2>Ani Games Ready Remote</h2><p>Gagal membuka antarmuka aplikasi.</p></body></html>",
                "text/html",
                "UTF-8"
            );
        }
    }

    private boolean openExternal(Uri uri) {
        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase();
        if ("stardesk".equals(scheme)) {
            try {
                Intent intent = new Intent(Intent.ACTION_VIEW, uri);
                intent.setPackage("com.stardesk");
                startActivity(intent);
            } catch (Exception ignored) {
                runOnUiThread(() -> webView.evaluateJavascript(
                    "window.showNativeMessage && window.showNativeMessage('StarDesk belum terpasang di perangkat ini.');",
                    null
                ));
            }
            return true;
        }
        if ("anigamesremote".equals(scheme)) return true;
        if ("https".equals(scheme) || "http".equals(scheme)) return false;
        return true;
    }

    public final class AndroidBridge {
        @JavascriptInterface
        public String getClientId() {
            return clientId;
        }

        @JavascriptInterface
        public String getDeviceName() {
            String manufacturer = android.os.Build.MANUFACTURER == null ? "" : android.os.Build.MANUFACTURER;
            String model = android.os.Build.MODEL == null ? "Android" : android.os.Build.MODEL;
            return (manufacturer + " " + model).trim();
        }

        @JavascriptInterface
        public String getAppVersion() {
            return "0.1.0";
        }

        @JavascriptInterface
        public void openStarDesk(String deepLink) {
            try {
                Uri uri = Uri.parse(deepLink);
                if (!"stardesk".equalsIgnoreCase(uri.getScheme())) return;
                Intent intent = new Intent(Intent.ACTION_VIEW, uri);
                intent.setPackage("com.stardesk");
                startActivity(intent);
            } catch (Exception ignored) {
                runOnUiThread(() -> webView.evaluateJavascript(
                    "window.showNativeMessage && window.showNativeMessage('StarDesk tidak dapat dibuka.');",
                    null
                ));
            }
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (webView != null) webView.postDelayed(() ->
            webView.evaluateJavascript("window.onAniAppResume && window.onAniAppResume();", null), 350);
    }

    @Override
    protected void onDestroy() {
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
