package com.anigamesready.stardeskclient;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Base64;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

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
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import javax.net.ssl.HttpsURLConnection;

public class MainActivity extends Activity {
    private static final String ONLINE_API_BASE = "https://ani-games-db-android-stage-gateway.anigamesready.workers.dev/stardesk";
    private static final String PREFS = "stardesk_remote_settings";
    private static final String SECURE_PREFS = "stardesk_remote_secure";
    private static final String KEY_ALIAS = "ani_stardesk_remote_tokens_v1";
    private WebView webView;
    private String clientId;
    private final ExecutorService apiExecutor = Executors.newSingleThreadExecutor();

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
        s.setAllowFileAccess(true);
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
        return true;
    }

    private void showMessage(String m){runOnUiThread(()->Toast.makeText(MainActivity.this,m,Toast.LENGTH_LONG).show());}
    private SharedPreferences prefs(){return getSharedPreferences(PREFS,MODE_PRIVATE);}
    private SharedPreferences securePrefs(){return getSharedPreferences(SECURE_PREFS,MODE_PRIVATE);}

    private SecretKey getOrCreateKey() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if(store.containsAlias(KEY_ALIAS)) return (SecretKey)store.getKey(KEY_ALIAS,null);
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build());
        return generator.generateKey();
    }

    private void saveSecretValue(String name,String value) throws Exception {
        if(name==null||!name.matches("[a-zA-Z0-9_.-]{1,80}")) throw new IllegalArgumentException("Invalid secret key");
        if(value==null||value.length()>4096) throw new IllegalArgumentException("Invalid secret value");
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE,getOrCreateKey());
        byte[] iv=cipher.getIV();
        byte[] encrypted=cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
        byte[] payload=new byte[iv.length+encrypted.length];
        System.arraycopy(iv,0,payload,0,iv.length);
        System.arraycopy(encrypted,0,payload,iv.length,encrypted.length);
        securePrefs().edit().putString(name,Base64.encodeToString(payload,Base64.NO_WRAP)).apply();
    }

    private String readSecretValue(String name) {
        try{
            String encoded=securePrefs().getString(name,null);
            if(encoded==null||encoded.isEmpty()) return "";
            byte[] payload=Base64.decode(encoded,Base64.NO_WRAP);
            if(payload.length<=12) throw new IllegalArgumentException("Encrypted value truncated");
            byte[] iv=new byte[12];
            byte[] encrypted=new byte[payload.length-12];
            System.arraycopy(payload,0,iv,0,12);
            System.arraycopy(payload,12,encrypted,0,encrypted.length);
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,getOrCreateKey(),new GCMParameterSpec(128,iv));
            return new String(cipher.doFinal(encrypted),StandardCharsets.UTF_8);
        }catch(Exception e){
            securePrefs().edit().remove(name).apply();
            return "";
        }
    }

    private void clearSecretValue(String name){
        if(name!=null&&name.matches("[a-zA-Z0-9_.-]{1,80}")) securePrefs().edit().remove(name).apply();
    }

    private JSONObject parseJson(String value) throws JSONException {
        Object parsed=new JSONTokener(value==null||value.trim().isEmpty()?"{}":value).nextValue();
        if(parsed instanceof JSONObject) return (JSONObject)parsed;
        if(parsed instanceof JSONArray) return new JSONObject().put("data",parsed);
        return new JSONObject().put("data",parsed);
    }

    private void deliverApiResult(String requestId,JSONObject result){
        if(webView==null) return;
        final String js="window.__onNativeApiResult&&window.__onNativeApiResult("
                +JSONObject.quote(requestId)+","+result.toString()+");";
        runOnUiThread(()->{if(webView!=null) webView.evaluateJavascript(js,null);});
    }

    private JSONObject errorJson(String code,String message){
        JSONObject result=new JSONObject();
        try{result.put("ok",false);result.put("error",code);result.put("message",message==null?code:message);}
        catch(JSONException ignored){}
        return result;
    }

    private void executeApiRequest(String base,String rpc,String body,String accessToken,String requestId){
        apiExecutor.execute(()->{
            HttpsURLConnection connection=null;
            try{
                if(base==null||!ONLINE_API_BASE.equals(base.trim())) throw new IllegalArgumentException("ANDROID_DB_ONLINE_GATEWAY_LOCKED");
                Uri baseUri=Uri.parse(base.trim());
                if(!"https".equalsIgnoreCase(baseUri.getScheme())||baseUri.getHost()==null
                        ||baseUri.getUserInfo()!=null||baseUri.getQuery()!=null||baseUri.getFragment()!=null)
                    throw new IllegalArgumentException("ANDROID_DB_API_REQUIRES_HTTPS");
                if(rpc==null||!rpc.matches("[a-z0-9_]{1,80}")) throw new IllegalArgumentException("RPC_NAME_INVALID");
                if(body==null||body.length()>32768) throw new IllegalArgumentException("API_BODY_TOO_LARGE");
                String root=base.trim().replaceAll("/+$","");
                URL url=new URL(root+"/rest/v1/rpc/"+rpc);
                connection=(HttpsURLConnection)url.openConnection(Proxy.NO_PROXY);
                connection.setSSLSocketFactory(new GatewayPinnedSocketFactory());
                connection.setHostnameVerifier((hostname, session) ->
                        GatewayPinnedSocketFactory.isGatewayHost(hostname)
                                && HttpsURLConnection.getDefaultHostnameVerifier().verify(
                                        GatewayPinnedSocketFactory.GATEWAY_HOST, session));
                connection.setRequestMethod("POST");
                connection.setConnectTimeout(10000);
                connection.setReadTimeout(15000);
                connection.setInstanceFollowRedirects(false);
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type","application/json; charset=utf-8");
                connection.setRequestProperty("Accept","application/json");
                if(accessToken!=null&&!accessToken.trim().isEmpty()){
                    if(accessToken.length()>512) throw new IllegalArgumentException("ACCESS_TOKEN_INVALID");
                    connection.setRequestProperty("Authorization","Bearer "+accessToken.trim());
                }
                byte[] bytes=body.getBytes(StandardCharsets.UTF_8);
                connection.setFixedLengthStreamingMode(bytes.length);
                try(OutputStream out=connection.getOutputStream()){out.write(bytes);}
                int status=connection.getResponseCode();
                InputStream stream=status>=200&&status<400?connection.getInputStream():connection.getErrorStream();
                String response=readBounded(stream,1024*1024);
                JSONObject parsed;
                try{parsed=parseJson(response);}catch(Exception ignored){parsed=errorJson("API_RESPONSE_INVALID",response);}
                parsed.put("http_status",status);
                String retryAfterHeader=connection.getHeaderField("Retry-After");
                if(retryAfterHeader!=null){
                    try{
                        int retryAfterSeconds=Integer.parseInt(retryAfterHeader.trim());
                        if(retryAfterSeconds>0) parsed.put("retry_after_seconds",Math.min(900,retryAfterSeconds));
                    }catch(NumberFormatException ignored){}
                }
                if(status<200||status>=300) parsed.put("ok",false);
                deliverApiResult(requestId,parsed);
            }catch(Exception e){
                deliverApiResult(requestId,errorJson(e.getMessage()==null?"ANDROID_DB_API_ERROR":e.getMessage(),
                        e.getMessage()==null?"Koneksi Android DB gagal":e.getMessage()));
            }finally{if(connection!=null)connection.disconnect();}
        });
    }

    private String readBounded(InputStream stream,int maxBytes) throws Exception{
        if(stream==null) return "{}";
        try(InputStream in=stream;ByteArrayOutputStream out=new ByteArrayOutputStream()){
            byte[] buffer=new byte[8192];int total=0,n;
            while((n=in.read(buffer))!=-1){
                total+=n;if(total>maxBytes) throw new IllegalStateException("API_RESPONSE_TOO_LARGE");
                out.write(buffer,0,n);
            }
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }

    public final class AndroidBridge {
        @JavascriptInterface public String getClientId(){return clientId;}
        @JavascriptInterface public String getDeviceName(){
            String a=android.os.Build.MANUFACTURER==null?"":android.os.Build.MANUFACTURER;
            String b=android.os.Build.MODEL==null?"Android":android.os.Build.MODEL;
            return (a+" "+b).trim();
        }
        @JavascriptInterface public String getAppVersion(){return "0.6.7-agent-sync";}
        @JavascriptInterface public String getApiBase(){return ONLINE_API_BASE;}
        @JavascriptInterface public boolean setApiBase(String value){
            // The client has one approved public API route. Ignore stale/manual loopback preferences.
            if(value==null||!ONLINE_API_BASE.equals(value.trim())) return false;
            prefs().edit().putString("api_base",ONLINE_API_BASE).apply();
            return true;
        }
        @JavascriptInterface public String getSecureValue(String name){return readSecretValue(name);}
        @JavascriptInterface public boolean saveSecureValue(String name,String value){
            try{saveSecretValue(name,value);return true;}catch(Exception e){return false;}
        }
        @JavascriptInterface public void clearSecureValue(String name){clearSecretValue(name);}
        @JavascriptInterface public void apiRequest(String base,String rpc,String body,String accessToken,String requestId){
            if(requestId==null||requestId.length()>100) return;
            executeApiRequest(base,rpc,body,accessToken,requestId);
        }
        @JavascriptInterface public void openWhatsApp(String message){
            Uri uri=Uri.parse("https://wa.me/6282298316902?text="+Uri.encode(message==null?"":message));
            runOnUiThread(()->{try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}catch(Exception e){showMessage("WhatsApp atau browser tidak tersedia.");}});
        }
        @JavascriptInterface public void copyText(String value){
            runOnUiThread(()->{try{
                ClipboardManager c=(ClipboardManager)getSystemService(Context.CLIPBOARD_SERVICE);
                c.setPrimaryClip(ClipData.newPlainText("Ani Games Ready",value==null?"":value));
                Toast.makeText(MainActivity.this,"Teks disalin",Toast.LENGTH_SHORT).show();
            }catch(Exception e){showMessage("Gagal menyalin teks.");}});
        }
    }

    @Override protected void onDestroy(){
        apiExecutor.shutdownNow();
        if(webView!=null){webView.stopLoading();webView.loadUrl("about:blank");webView.removeAllViews();webView.destroy();webView=null;}
        super.onDestroy();
    }
}
