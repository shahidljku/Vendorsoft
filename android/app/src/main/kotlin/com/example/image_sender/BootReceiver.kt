package com.example.image_sender

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON") {
            
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            var endTime = prefs.getLong("flutter.cooldownEndTime", 0L)
            if (endTime == 0L) {
                endTime = prefs.getLong("cooldownEndTime", 0L)
            }

            if (endTime > 0L) {
                val now = System.currentTimeMillis()
                if (endTime > now) {
                    // Cooldown is still active! Reschedule the alarm for remaining seconds
                    val remainingSeconds = ((endTime - now) / 1000L).toInt()
                    if (remainingSeconds > 0) {
                        scheduleCooldownAlarm(context, remainingSeconds)
                    }
                } else {
                    // Cooldown expired while the phone was switched off! Show notification right away upon reboot
                    showExpiredNotification(context)
                    // Clear saved cooldown time
                    prefs.edit().remove("flutter.cooldownEndTime").remove("cooldownEndTime").apply()
                }
            }
        }
    }

    private fun scheduleCooldownAlarm(context: Context, seconds: Int) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                "cooldown_channel",
                "Batch Cooldown",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for when WhatsApp sending cooldown expires"
            }
            notificationManager.createNotificationChannel(channel)
        }

        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val alarmIntent = Intent(context, CooldownAlarmReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            2001,
            alarmIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val triggerTime = System.currentTimeMillis() + (seconds * 1000L)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
            }
        } catch (e: SecurityException) {
            alarmManager.set(AlarmManager.RTC_WAKEUP, triggerTime, pendingIntent)
        }
    }

    private fun showExpiredNotification(context: Context) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                "cooldown_channel",
                "Batch Cooldown",
                NotificationManager.IMPORTANCE_HIGH
            )
            notificationManager.createNotificationChannel(channel)
        }

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, "cooldown_channel")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Cooldown Expired! 🚀")
            .setContentText("You can now send your next batch of bills or receipts.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        notificationManager.notify(2001, notification)
    }
}
