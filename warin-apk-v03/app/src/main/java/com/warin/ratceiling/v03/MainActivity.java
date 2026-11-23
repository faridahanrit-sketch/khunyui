package com.warin.ratceiling.v03;
import android.app.Activity;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

public class MainActivity extends Activity {
 private WebView webView;
 @Override protected void onCreate(Bundle savedInstanceState) {
  super.onCreate(savedInstanceState);
  requestWindowFeature(Window.FEATURE_NO_TITLE);
  getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN, WindowManager.LayoutParams.FLAG_FULLSCREEN);
  webView = new WebView(this); setContentView(webView);
  WebSettings s = webView.getSettings();
  s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true); s.setDatabaseEnabled(true);
  s.setAllowFileAccess(true); s.setAllowContentAccess(true); s.setLoadWithOverviewMode(true);
  s.setUseWideViewPort(true); s.setMediaPlaybackRequiresUserGesture(false);
  webView.setWebViewClient(new WebViewClient());
  webView.loadUrl("file:///android_asset/index.html");
 }
 @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
  if (keyCode == KeyEvent.KEYCODE_BACK && webView != null && webView.canGoBack()) { webView.goBack(); return true; }
  return super.onKeyDown(keyCode,event);
 }
 @Override protected void onResume(){super.onResume();if(webView!=null)webView.onResume();}
 @Override protected void onPause(){if(webView!=null)webView.onPause();super.onPause();}
}
