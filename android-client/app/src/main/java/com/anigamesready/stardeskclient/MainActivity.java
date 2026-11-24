package com.anigamesready.stardeskclient;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
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
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    private WebView webView;
    private String clientId;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(Color.rgb(9,9,31));
        getWindow().setNavigationBarColor(Color.rgb(9,9,31));
        String androidId=Settings.Secure.getString(getContentResolver(),Settings.Secure.ANDROID_ID);
        clientId="android-"+(androidId==null?"unknown-device":androidId.toLowerCase());

        webView=new WebView(this);
        webView.setBackgroundColor(Color.rgb(9,9,31));
        WebSettings s=webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setLoadsImagesAutomatically(true);
        s.setAllowFileAccess(true); // Only the bundled, local app assets are loaded.
        s.setAllowContentAccess(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setSupportMultipleWindows(false);
        webView.addJavascriptInterface(new AndroidBridge(),"AniAndroid");
        webView.setWebViewClient(new WebViewClient(){
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r){return openExternal(r.getUrl());}
            @Override public boolean shouldOverrideUrlLoading(WebView v,String u){return openExternal(Uri.parse(u));}
        });
        setContentView(webView);
        webView.loadUrl("file:///android_asset/index.html");
    }

    private boolean openExternal(Uri uri){
        String scheme=uri.getScheme()==null?"":uri.getScheme().toLowerCase();
        if("stardesk".equals(scheme)){
            try{Intent i=new Intent(Intent.ACTION_VIEW,uri);i.setPackage("com.stardesk");startActivity(i);}
            catch(Exception e){showMessage("StarDesk belum terpasang.");}
            return true;
        }
        if("https".equals(scheme)&&"wa.me".equalsIgnoreCase(uri.getHost())){
            try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}
            catch(Exception e){showMessage("WhatsApp atau browser tidak tersedia.");}
            return true;
        }
        return true; // Block all network navigation inside the preview WebView.
    }

    private void showMessage(String m){runOnUiThread(()->Toast.makeText(MainActivity.this,m,Toast.LENGTH_LONG).show());}

    public final class AndroidBridge {
        @JavascriptInterface public String getClientId(){return clientId;}
        @JavascriptInterface public String getDeviceName(){
            String a=android.os.Build.MANUFACTURER==null?"":android.os.Build.MANUFACTURER;
            String b=android.os.Build.MODEL==null?"Android":android.os.Build.MODEL;
            return (a+" "+b).trim();
        }
        @JavascriptInterface public String getAppVersion(){return "0.2.0-preview";}
        @JavascriptInterface public void openWhatsApp(String message){
            Uri uri=Uri.parse("https://wa.me/6282298316902?text="+Uri.encode(message==null?"":message));
            runOnUiThread(()->{try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}catch(Exception e){showMessage("WhatsApp atau browser tidak tersedia.");}});
        }
        @JavascriptInterface public void copyText(String value){
            runOnUiThread(()->{try{
                ClipboardManager c=(ClipboardManager)getSystemService(Context.CLIPBOARD_SERVICE);
                c.setPrimaryClip(ClipData.newPlainText("Ani Games Ready",value==null?"":value));
                Toast.makeText(MainActivity.this,"Nominal disalin",Toast.LENGTH_SHORT).show();
            }catch(Exception e){showMessage("Gagal menyalin nominal.");}});
        }
    }

    @Override protected void onDestroy(){
        if(webView!=null){webView.stopLoading();webView.loadUrl("about:blank");webView.removeAllViews();webView.destroy();webView=null;}
        super.onDestroy();
    }
}