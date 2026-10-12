package com.termux.app.dsh;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import com.termux.shared.logger.Logger;

/**
 * {@link DshWebService} 前台通知的点击接收器：把用户带回 dsh web 主页面。
 * 由 PendingIntent.getBroadcast 显式指定组件，无需 intent-filter、不导出。
 */
public class DshNotificationReceiver extends BroadcastReceiver {

    private static final String LOG_TAG = "DshNotificationReceiver";

    public static final String ACTION_OPEN_WEB_ACTIVITY = "com.termux.app.dsh.action.OPEN_WEB_ACTIVITY";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !ACTION_OPEN_WEB_ACTIVITY.equals(intent.getAction())) return;

        Logger.logDebug(LOG_TAG, "Notification tapped, opening DshWebActivity");

        Intent openIntent = new Intent(context, DshWebActivity.class);
        openIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP
            | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        context.startActivity(openIntent);
    }

}
