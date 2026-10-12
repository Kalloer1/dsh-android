package com.termux.app.dsh;

import android.Manifest;
import android.annotation.SuppressLint;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;

import com.termux.R;
import com.termux.app.TermuxActivity;
import com.termux.shared.android.PermissionUtils;
import com.termux.shared.logger.Logger;
import com.termux.shared.termux.TermuxConstants;

import java.io.File;
import java.lang.reflect.Method;

/**
 * App 主入口：全屏 WebView 直接展示 dsh web（http://127.0.0.1:3080）。
 *
 * 职责：
 * 1. 首启引导：bootstrap 未解压时通过反射调用包内私有的
 *    {@code com.termux.app.TermuxInstaller.setupBootstrapIfNeeded()}（本类不在该包内，
 *    且不允许改动 TermuxInstaller，见"最不确定调用点"汇报），完成后启动
 *    {@link DshWebService} 保活 dsh web；
 * 2. 非 127.0.0.1 的跳转（GitHub OAuth 等）交给系统浏览器；
 * 3. 加载失败显示内置重试页（进程由 Service 自动重拉，这里只兜 UI）；
 * 4. 返回键先 goBack 再退桌面；顶部工具条/菜单提供终端入口与重启服务入口；
 * 5. 首启一次性引导电池优化豁免（用户被问过一次后不再打扰）。
 *
 * TODO(MIUI): 不写任何 MIUI 特定 hack。若后续验证 MIUI 杀掉前台服务，
 * 需单独评估自启动白名单 Intent（miui.intent.action.OPPERATION_STARTUP_MANAGE）方案。
 */
public class DshWebActivity extends AppCompatActivity {

    private static final String LOG_TAG = "DshWebActivity";

    /** dsh web 地址：必须带本轮启动 token（见 {@link DshWebService#getAuthTokenUrl()}）。 */
    private static final int TOKEN_POLL_MAX = 40;
    private int mTokenPollCount;

    private static final String PREFS_NAME = "dsh_web_prefs";
    private static final String PREF_KEY_BATTERY_PROMPTED = "battery_optimization_prompted";

    private static final int REQUEST_CODE_POST_NOTIFICATIONS = 4080;

    private WebView mWebView;
    private View mErrorLayout;
    private TextView mErrorText;
    private final Handler mHandler = new Handler(Looper.getMainLooper());

    private boolean mServiceStartRequested;
    private boolean mBootstrapRunning;
    /** 本次加载主框架是否出错，用于 onPageFinished 时决定要不要展示重试页。 */
    private boolean mMainFrameFailed;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_dsh_web);

        mWebView = findViewById(R.id.dsh_web_view);
        mErrorLayout = findViewById(R.id.dsh_web_error_layout);
        mErrorText = findViewById(R.id.dsh_web_error_text);

        setupWebView();

        findViewById(R.id.dsh_toolbar_terminal_button).setOnClickListener(v -> openTermuxActivity());
        findViewById(R.id.dsh_toolbar_restart_button).setOnClickListener(v -> restartDshWebService());
        findViewById(R.id.dsh_web_retry_button).setOnClickListener(v -> {
            hideErrorView();
            startFlow();
        });

        requestPostNotificationsPermissionIfNeeded();
        maybePromptBatteryOptimizationExemption();

        startFlow();
    }

    @Override
    protected void onResume() {
        super.onResume();
        mWebView.onResume();
    }

    @Override
    protected void onPause() {
        mWebView.onPause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        if (mWebView != null)
            mWebView.destroy();
        super.onDestroy();
    }

    // ---------------------------------------------------------------------------------------------
    // WebView
    // ---------------------------------------------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private void setupWebView() {
        mWebView.getSettings().setJavaScriptEnabled(true);
        // dsh web 前端可能使用 localStorage
        mWebView.getSettings().setDomStorageEnabled(true);
        mWebView.getSettings().setJavaScriptCanOpenWindowsAutomatically(true);
        // TODO: OAuth 若走 window.open 弹窗需要 WebChromeClient.onCreateWindow 支持，本期未实现
        mWebView.setWebViewClient(mWebViewClient);
        // 不在此处 loadUrl：首启可能还需先解压 bootstrap，统一由 startFlow() 触发加载
    }

    private final WebViewClient mWebViewClient = new WebViewClient() {

        @Override
        public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
            mMainFrameFailed = false;
        }

        @Override
        @Deprecated
        public boolean shouldOverrideUrlLoading(WebView view, String url) {
            return handleNavigation(url);
        }

        @Override
        public boolean shouldOverrideUrlLoading(@NonNull WebView view, @NonNull WebResourceRequest request) {
            return handleNavigation(request.getUrl().toString());
        }

        @Override
        @Deprecated
        public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                mMainFrameFailed = true;
                showErrorView(getString(R.string.dsh_error_text_connect));
            }
        }

        @Override
        public void onReceivedError(@NonNull WebView view, @NonNull WebResourceRequest request,
                                    @NonNull WebResourceError error) {
            // 只处理主框架错误，页面里的子资源失败不打断使用
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && request.isForMainFrame()) {
                mMainFrameFailed = true;
                showErrorView(getString(R.string.dsh_error_text_connect));
            }
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            // 只有本次加载主框架没出错才收起重试页（否则错误页刚渲染完就被隐藏）
            if (!mMainFrameFailed)
                hideErrorView();
        }
    };

    /** 本地地址留在 WebView 内，其余（GitHub OAuth 等）交给系统浏览器。 */
    private boolean handleNavigation(String url) {
        if (url == null) return true;

        String host;
        try {
            host = Uri.parse(url).getHost();
        } catch (Exception e) {
            return true;
        }
        if (isLocalHost(host)) return false;

        openInExternalBrowser(url);
        return true;
    }

    private static boolean isLocalHost(String host) {
        if (host == null) return false;
        String h = host.toLowerCase();
        return h.equals("localhost") || h.equals("::1") || h.startsWith("127.");
    }

    private void openInExternalBrowser(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (ActivityNotFoundException e) {
            Logger.logError(LOG_TAG, "No external browser found for: " + url);
            Toast.makeText(this, R.string.dsh_error_no_browser, Toast.LENGTH_LONG).show();
        }
    }

    private void loadDshUrl() {
        hideErrorView();
        String url = DshWebService.getAuthTokenUrl();
        if (url != null) {
            mTokenPollCount = 0;
            mWebView.loadUrl(url);
            return;
        }
        if (mTokenPollCount++ < TOKEN_POLL_MAX) {
            // dsh web 还没打印 token 行（首启解 bootstrap/冷启动慢），每秒重查一次
            mHandler.postDelayed(this::loadDshUrl, 1000);
            return;
        }
        mTokenPollCount = 0;
        showErrorView(getString(R.string.dsh_error_text_connect));
    }

    private void showErrorView(String reason) {
        mErrorText.setText(reason);
        mErrorLayout.setVisibility(View.VISIBLE);
    }

    private void hideErrorView() {
        mErrorLayout.setVisibility(View.GONE);
    }

    // ---------------------------------------------------------------------------------------------
    // 首启引导 + 起服务
    // ---------------------------------------------------------------------------------------------

    /** bootstrap 就绪则直接起服务加载页面；否则先执行一次性引导。 */
    private void startFlow() {
        if (isBootstrapReady()) {
            ensureDshWebServiceStarted();
            loadDshUrl();
        } else {
            runBootstrapOnce();
        }
    }

    private static boolean isBootstrapReady() {
        return new File(TermuxConstants.TERMUX_BIN_PREFIX_DIR_PATH, "bash").exists();
    }

    /**
     * TermuxInstaller 是 com.termux.app 包内 package-private 类，dsh 子包无法直接调用；
     * 在不允许修改 TermuxInstaller/TermuxActivity 的前提下，用反射挂一次性引导。
     * 失败（混淆改名/签名变化）则退回内置重试页，用户可经工具条进终端手动引导。
     */
    private void runBootstrapOnce() {
        if (mBootstrapRunning) return;
        mBootstrapRunning = true;

        showErrorView(getString(R.string.dsh_error_text_bootstrap));
        try {
            Class<?> installerClass = Class.forName("com.termux.app.TermuxInstaller");
            Method method = installerClass.getDeclaredMethod("setupBootstrapIfNeeded",
                android.app.Activity.class, Runnable.class);
            method.setAccessible(true);
            method.invoke(null, this, (Runnable) () -> mHandler.post(() -> {
                mBootstrapRunning = false;
                ensureDshWebServiceStarted();
                loadDshUrl();
            }));
        } catch (Throwable t) { // NoSuchMethodException/InvocationTargetException/... 一律兜住
            mBootstrapRunning = false;
            Logger.logErrorAndShowToast(this, LOG_TAG, "bootstrap reflection failed: " + t.getMessage());
            showErrorView(getString(R.string.dsh_error_text_bootstrap_failed));
        }
    }

    private void ensureDshWebServiceStarted() {
        if (mServiceStartRequested) return;
        mServiceStartRequested = true;

        Intent intent = new Intent(this, DshWebService.class).setAction(DshWebService.ACTION_START_WEB);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            startForegroundService(intent);
        else
            startService(intent);
    }

    // ---------------------------------------------------------------------------------------------
    // 入口跳转 / 服务控制
    // ---------------------------------------------------------------------------------------------

    /** 二级入口：打开 Termux 终端。 */
    private void openTermuxActivity() {
        startActivity(new Intent(this, TermuxActivity.class));
    }

    /** 工具条电源按钮：杀掉 dsh web 进程并立刻重拉。 */
    private void restartDshWebService() {
        ensureDshWebServiceStarted();
        startService(new Intent(this, DshWebService.class).setAction(DshWebService.ACTION_RESTART_WEB));
        Toast.makeText(this, R.string.dsh_toast_restarting_service, Toast.LENGTH_SHORT).show();
        mHandler.postDelayed(this::loadDshUrl, 1500); // 给进程一点重启时间
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        menu.add(Menu.NONE, MENU_ITEM_TERMINAL, Menu.NONE, R.string.dsh_menu_terminal);
        menu.add(Menu.NONE, MENU_ITEM_RESTART, Menu.NONE, R.string.dsh_menu_restart_service);
        return true;
    }

    private static final int MENU_ITEM_TERMINAL = 1;
    private static final int MENU_ITEM_RESTART = 2;

    @Override
    public boolean onOptionsItemSelected(@NonNull MenuItem item) {
        if (item.getItemId() == MENU_ITEM_TERMINAL) {
            openTermuxActivity();
            return true;
        }
        if (item.getItemId() == MENU_ITEM_RESTART) {
            restartDshWebService();
            return true;
        }
        return super.onOptionsItemSelected(item);
    }

    /** 返回键：网页能后退就先后退，否则退到桌面（finish 回 launcher）。 */
    @Override
    public void onBackPressed() {
        if (mWebView.canGoBack())
            mWebView.goBack();
        else
            finish();
    }

    // ---------------------------------------------------------------------------------------------
    // 权限相关
    // ---------------------------------------------------------------------------------------------

    /**
     * targetSdk 28 下通知默认允许；提前按 33+ 规矩申请，避免以后升 targetSdk 时通知静默失败。
     */
    private void requestPostNotificationsPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < 33 /* TIRAMISU */) return;
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},
                REQUEST_CODE_POST_NOTIFICATIONS);
        }
    }

    /**
     * 电池优化豁免：只在首启问一次，用户拒绝过就不再弹（无法直接感知拒绝结果，
     * 弹过即置位，符合"点了拒绝就不再弹"的要求）。
     */
    private void maybePromptBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        if (PermissionUtils.checkIfBatteryOptimizationsDisabled(this)) return;

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (prefs.getBoolean(PREF_KEY_BATTERY_PROMPTED, false)) return;

        prefs.edit().putBoolean(PREF_KEY_BATTERY_PROMPTED, true).apply();

        new AlertDialog.Builder(this)
            .setTitle(R.string.dsh_battery_dialog_title)
            .setMessage(R.string.dsh_battery_dialog_message)
            .setCancelable(false)
            .setPositiveButton(R.string.dsh_battery_dialog_go, (dialog, which) -> {
                // 系统弹窗可能被厂商 ROM 拦截，失败仅记日志；返回值为 shared.errors.Error
                com.termux.shared.errors.Error error = PermissionUtils.requestDisableBatteryOptimizations(this);
                if (error != null)
                    Logger.logError(LOG_TAG, "battery exemption request failed: " + error.getMessage());
            })
            .setNegativeButton(android.R.string.cancel, null)
            .show();
        // TODO(MIUI): 小米还需自启动白名单才能长期驻留，本期不做机型特判。
    }

}
