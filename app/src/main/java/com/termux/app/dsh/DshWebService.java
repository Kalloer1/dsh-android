package com.termux.app.dsh;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

import androidx.annotation.Nullable;

import com.termux.R;
import com.termux.shared.logger.Logger;
import com.termux.shared.notification.NotificationUtils;
import com.termux.shared.shell.command.ExecutionCommand;
import com.termux.shared.shell.command.ExecutionCommand.Runner;
import com.termux.shared.shell.command.runner.app.AppShell;
import com.termux.shared.termux.TermuxConstants;
import com.termux.shared.termux.shell.TermuxShellManager;
import com.termux.shared.termux.shell.command.environment.TermuxShellEnvironment;

import java.net.InetSocketAddress;
import java.net.Socket;

/**
 * 前台 Service：保证 {@code dsh web}（监听 127.0.0.1:3080）进程存活。
 *
 * 执行机制：复用 Termux 自身的后台命令通道 {@link AppShell}（与 TermuxService 的
 * createTermuxTask 相同的路径），通过 {@code bash -lc "exec dsh web"} 在 termux 环境
 * （完整 PATH、HOME 等）中执行。本 Service 自己实现 {@link AppShell.AppShellClient}，
 * 进程退出回调触发指数退避重启（上限 60s），另有 30s 看门狗探测端口存活。
 *
 * TODO(MIUI): 小米系 ROM 的后台查杀/自启动白名单（AutostartManager）需要单独的机型适配，
 * 本期不做任何 MIUI 特定 hack，仅靠前台服务 + 电池优化豁免兜底。
 */
public final class DshWebService extends Service implements AppShell.AppShellClient {

    private static final String LOG_TAG = "DshWebService";

    /** 启动/保活 {@code dsh web}。 */
    public static final String ACTION_START_WEB = "com.termux.app.dsh.action.START_WEB";
    /** 强制杀掉现有进程并立即重新拉起（工具条电源按钮）。 */
    public static final String ACTION_RESTART_WEB = "com.termux.app.dsh.action.RESTART_WEB";
    /** 停止保活并退出 Service。 */
    public static final String ACTION_STOP_WEB = "com.termux.app.dsh.action.STOP_WEB";

    /** dsh web 默认监听端口（与 {@link DshWebActivity} 加载的 URL 一致）。 */
    public static final int DSH_WEB_PORT = 3080;

    /**
     * dsh web 启动契约（DSHA 先例 + 官方源码核实）：token 每次启动随机新签发，
     * 只出现在 stdout 的 `dsh web: http://127.0.0.1:PORT/?token=<43字符>` 行；
     * AppShellClient 无 stdout 回调，故重定向到 HOME 下日志文件轮询解析。
     * 环境变量：danger-full-access 关闭 Linux 沙箱（bwrap/landlock 在 Android 必死），
     * BROWSER=true 让 xdg-open 变 no-op（Termux 无 xdg-open），DSH_CONFIRM 免交互确认。
     */
    static final String DSH_LOG_RELATIVE = ".dsh-web.log";
    private static final String DSH_START_COMMAND =
        "exec env DSH_PERMISSION_MODE=danger-full-access DSH_TELEMETRY_DISABLED=1"
        + " DSH_CONFIRM=1 BROWSER=true"
        + " dsh web --no-open --host 127.0.0.1 --port " + DSH_WEB_PORT
        + " >\"$HOME/" + DSH_LOG_RELATIVE + "\" 2>&1";

    private static final String DSH_WEB_NOTIFICATION_CHANNEL_ID = "dsh_web_notification_channel";
    private static final CharSequence DSH_WEB_NOTIFICATION_CHANNEL_NAME = "dsh web";
    private static final int DSH_WEB_NOTIFICATION_ID = 4080;

    /** 首次重启退避 1s，指数增长，封顶 60s。 */
    private static final long RESTART_DELAY_MIN_MS = 1000L;
    private static final long RESTART_DELAY_MAX_MS = 60000L;
    /** 进程存活超过该时长视为已恢复正常，退避重置。 */
    private static final long STABLE_RUN_MS = 120000L;
    /** 看门狗周期与端口探测宽限期。 */
    private static final long WATCHDOG_INTERVAL_MS = 30000L;
    private static final long PORT_CHECK_GRACE_MS = 45000L;

    private final Handler mHandler = new Handler(Looper.getMainLooper());

    private AppShell mDshWebShell;
    private long mShellStartedAtMs;
    private long mRestartDelayMs = RESTART_DELAY_MIN_MS;
    private boolean mShouldRun = true;

    private Runnable mPendingStartRunnable;

    private final Runnable mWatchdogRunnable = new Runnable() {
        @Override
        public void run() {
            onWatchdogTick();
            mHandler.postDelayed(this, WATCHDOG_INTERVAL_MS);
        }
    };

    @Override
    public void onCreate() {
        Logger.logDebug(LOG_TAG, "onCreate");
        super.onCreate();

        NotificationUtils.setupNotificationChannel(this, DSH_WEB_NOTIFICATION_CHANNEL_ID,
            DSH_WEB_NOTIFICATION_CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW);
        startForeground(DSH_WEB_NOTIFICATION_ID, buildNotification(getString(R.string.dsh_notification_text_running)));

        mHandler.postDelayed(mWatchdogRunnable, WATCHDOG_INTERVAL_MS);
    }

    @Override
    public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
        Logger.logDebug(LOG_TAG, "onStartCommand: " + (intent != null ? intent.getAction() : "null"));

        String action = intent != null ? intent.getAction() : null;
        if (ACTION_STOP_WEB.equals(action)) {
            mShouldRun = false;
            cancelPendingStart();
            killCurrentShell();
            stopForeground(true);
            stopSelf();
            return START_NOT_STICKY;
        }

        if (ACTION_RESTART_WEB.equals(action)) {
            // 用户手动重启：立刻重拉，不受退避计数影响
            mShouldRun = true;
            mRestartDelayMs = RESTART_DELAY_MIN_MS;
            cancelPendingStart();
            synchronized (this) {
                killCurrentShell(); // kill 会走 onAppShellExited -> scheduleRestart
                if (mDshWebShell == null)
                    startDshWeb(); // 本来就没有活进程（如启动失败退避中），直接拉起
            }
            return START_STICKY;
        }

        // ACTION_START_WEB（或系统重建）：没有活着的进程就立刻启动
        mShouldRun = true;
        cancelPendingStart();
        if (mDshWebShell == null)
            startDshWeb();
        return START_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        // 仅 startService 使用，不绑定
        return null;
    }

    @Override
    public void onDestroy() {
        Logger.logDebug(LOG_TAG, "onDestroy");
        mShouldRun = false;
        mHandler.removeCallbacks(mWatchdogRunnable);
        cancelPendingStart();
        killCurrentShell();
        super.onDestroy();
    }

    // ---------------------------------------------------------------------------------------------
    // 进程保活
    // ---------------------------------------------------------------------------------------------

    /** 在 termux 登录 shell 环境中后台执行 {@code exec dsh web}。必须在主线程调用。 */
    private synchronized void startDshWeb() {
        if (mDshWebShell != null) {
            Logger.logVerbose(LOG_TAG, "dsh web shell already running, skip start");
            return;
        }

        String bashPath = TermuxConstants.TERMUX_BIN_PREFIX_DIR_PATH + "/bash";
        ExecutionCommand executionCommand = new ExecutionCommand(TermuxShellManager.getNextShellId(),
            bashPath, new String[]{"-lc", DSH_START_COMMAND}, null, null,
            Runner.APP_SHELL.getName(), false);
        executionCommand.shellName = "dsh web";
        executionCommand.commandLabel = "DshWebService dsh web";
        executionCommand.commandDescription = "Keep dsh web (127.0.0.1:" + DSH_WEB_PORT + ") alive";

        Logger.logDebug(LOG_TAG, "Starting dsh web via AppShell");
        mDshWebShell = AppShell.execute(this, executionCommand, this,
            new TermuxShellEnvironment(), null, false);
        mShellStartedAtMs = System.currentTimeMillis();

        if (mDshWebShell == null) {
            Logger.logError(LOG_TAG, "Failed to execute dsh web command, will retry with backoff");
            scheduleRestart();
        }
        updateNotification();
    }

    /** {@link AppShell.AppShellClient}：dsh web 进程退出后指数退避重启。 */
    @Override
    public void onAppShellExited(final AppShell appShell) {
        mHandler.post(() -> {
            synchronized (DshWebService.this) {
                if (appShell != mDshWebShell) return; // 过期回调，忽略

                mDshWebShell = null;
                Logger.logDebug(LOG_TAG, "dsh web shell exited");
                if (mShouldRun) {
                    long ranForMs = System.currentTimeMillis() - mShellStartedAtMs;
                    if (ranForMs >= STABLE_RUN_MS)
                        mRestartDelayMs = RESTART_DELAY_MIN_MS; // 跑稳过了，重置退避
                    scheduleRestart();
                }
                updateNotification();
            }
        });
    }

    /** 按当前退避时间延迟重启，并把退避翻倍（封顶 60s）。必须在主线程且持有锁时调用。 */
    private void scheduleRestart() {
        cancelPendingStart();
        final long delay = mRestartDelayMs;
        mRestartDelayMs = Math.min(mRestartDelayMs * 2, RESTART_DELAY_MAX_MS);
        Logger.logDebug(LOG_TAG, "Scheduling dsh web restart in " + delay + "ms");
        mPendingStartRunnable = new Runnable() {
            @Override
            public void run() {
                mPendingStartRunnable = null;
                synchronized (DshWebService.this) {
                    if (mShouldRun && mDshWebShell == null)
                        startDshWeb();
                }
            }
        };
        mHandler.postDelayed(mPendingStartRunnable, delay);
    }

    private void cancelPendingStart() {
        if (mPendingStartRunnable != null) {
            mHandler.removeCallbacks(mPendingStartRunnable);
            mPendingStartRunnable = null;
        }
    }

    private synchronized void killCurrentShell() {
        if (mDshWebShell != null) {
            mDshWebShell.killIfExecuting(this, true);
            // 退出回调会触发 scheduleRestart（RESTART 场景）或被 mShouldRun=false 拦住（STOP 场景）
        }
    }

    /** 看门狗：进程不在则补拉；进程在但端口长时间不通则杀掉重拉。 */
    private void onWatchdogTick() {
        final AppShell shell;
        final boolean pastGrace;
        synchronized (this) {
            if (!mShouldRun) return;
            if (mDshWebShell == null && mPendingStartRunnable == null) {
                // 进程不在且没有排队的重启：立刻补一次
                startDshWeb();
                return;
            }
            shell = mDshWebShell;
            pastGrace = shell != null && (System.currentTimeMillis() - mShellStartedAtMs) > PORT_CHECK_GRACE_MS;
        }
        if (shell == null || !pastGrace) return;

        // 端口探测放后台线程，避免阻塞主线程
        new Thread(() -> {
            boolean portUp = false;
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress("127.0.0.1", DSH_WEB_PORT), 2000);
                portUp = true;
            } catch (Exception e) {
                // 连不上即视为未就绪
            }
            final boolean alive = portUp;
            mHandler.post(() -> {
                if (alive) return;
                synchronized (DshWebService.this) {
                    if (mShouldRun && shell == mDshWebShell) {
                        Logger.logError(LOG_TAG, "dsh web process alive but port " + DSH_WEB_PORT
                            + " not listening, killing for restart");
                        shell.killIfExecuting(DshWebService.this, true);
                    }
                }
            });
        }).start();
    }

    // ---------------------------------------------------------------------------------------------
    // token 提取
    // ---------------------------------------------------------------------------------------------

    /**
     * 从 dsh web 的启动日志里取本轮带 token 的 URL（token 每次启动重新签发，
     * 无 token 访问首页一律 401）。日志被 bash 以 {@code >} 截断重写，读到旧轮
     * token 的窗口很小；Activity 拿到 token URL 后 WebView 由 cookie 接管会话。
     * @return 形如 http://127.0.0.1:3080/?token=xxx 的 URL；未就绪返回 null。
     */
    @Nullable
    public static String getAuthTokenUrl() {
        java.io.File log = new java.io.File(TermuxConstants.TERMUX_HOME_DIR_PATH, DSH_LOG_RELATIVE);
        if (!log.isFile()) return null;
        try (java.io.BufferedReader reader = new java.io.BufferedReader(new java.io.FileReader(log))) {
            String line;
            String found = null;
            while ((line = reader.readLine()) != null) {
                int idx = line.indexOf("http://127.0.0.1:" + DSH_WEB_PORT + "/?token=");
                if (idx >= 0) {
                    int end = line.indexOf(' ', idx);
                    found = end < 0 ? line.substring(idx) : line.substring(idx, end);
                }
            }
            return found;
        } catch (Exception e) {
            return null;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // 通知
    // ---------------------------------------------------------------------------------------------

    private void updateNotification() {
        NotificationManager notificationManager = NotificationUtils.getNotificationManager(this);
        if (notificationManager != null)
            notificationManager.notify(DSH_WEB_NOTIFICATION_ID, buildNotification(
                mDshWebShell != null ? getString(R.string.dsh_notification_text_running)
                    : getString(R.string.dsh_notification_text_restarting)));
    }

    private Notification buildNotification(String text) {
        // 点击通知回到 WebView 主页
        Intent openIntent = new Intent(this, DshNotificationReceiver.class)
            .setAction(DshNotificationReceiver.ACTION_OPEN_WEB_ACTIVITY);
        int pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            pendingFlags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent contentIntent = PendingIntent.getBroadcast(this, 0, openIntent, pendingFlags);

        Notification.Builder builder = NotificationUtils.geNotificationBuilder(this,
            DSH_WEB_NOTIFICATION_CHANNEL_ID, Notification.PRIORITY_LOW,
            DSH_WEB_NOTIFICATION_CHANNEL_NAME, text, null,
            contentIntent, null, NotificationUtils.NOTIFICATION_MODE_SILENT);
        if (builder == null) return null;

        builder.setShowWhen(false);
        builder.setSmallIcon(R.drawable.ic_service_notification);
        builder.setColor(0xFF607D8B);
        builder.setOngoing(true);

        // 通知上带"停止"按钮，避免前台服务无法关闭
        Intent stopIntent = new Intent(this, DshWebService.class).setAction(ACTION_STOP_WEB);
        builder.addAction(android.R.drawable.ic_delete, getString(R.string.dsh_notification_action_stop),
            PendingIntent.getService(this, 1, stopIntent, pendingFlags));

        return builder.build();
    }

}
