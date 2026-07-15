package com.vendorsoft.app

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.TextUtils
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent

class MainActivity : FlutterActivity() {

    private val FILE_CHANNEL = "com.example.image_sender/file_access"
    private val WHATSAPP_CHANNEL = "com.example.image_sender/whatsapp"
    private val ACCESSIBILITY_CHANNEL = "com.example.image_sender/accessibility"

    private var pendingResult: MethodChannel.Result? = null
    private val PICK_FILE_REQUEST_CODE = 1001
    private val EXPORT_LOG_REQUEST_CODE = 1002
    private var logContentToExport: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                "cooldown_channel",
                "Batch Cooldown",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for when WhatsApp sending cooldown expires"
            }
            notificationManager.createNotificationChannel(channel)
        }

        // ── Accessibility Message Sent Receiver ──
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == "com.vendorsoft.app.MESSAGE_SENT") {
                    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ACCESSIBILITY_CHANNEL)
                        .invokeMethod("messageSent", null)
                }
            }
        }
        val filter = IntentFilter("com.vendorsoft.app.MESSAGE_SENT")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }

        // ── File Access Channel (SAF) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickExcelWithWriteAccess" -> {
                        pendingResult = result
                        pickExcelFile()
                    }
                    "saveToUri" -> {
                        val uriString = call.argument<String>("uri")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (uriString != null && bytes != null) {
                            saveToUri(uriString, bytes, result)
                        } else {
                            result.error("INVALID_ARGS", "URI and bytes are required", null)
                        }
                    }
                    "readFromUri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString != null) {
                            readFromUri(uriString, result)
                        } else {
                            result.error("INVALID_ARGS", "URI is required", null)
                        }
                    }
                    "exportLogFile" -> {
                        val content = call.argument<String>("content")
                        if (content != null) {
                            pendingResult = result
                            logContentToExport = content
                            createLogFile()
                        } else {
                            result.error("INVALID_ARGS", "Content is required", null)
                        }
                    }
                    "openDialer" -> {
                        val phone = call.argument<String>("phone") ?: ""
                        try {
                            val intent = Intent(Intent.ACTION_DIAL, android.net.Uri.parse("tel:$phone"))
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DIAL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── WhatsApp Channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendImage" -> {
                        val mobile = call.argument<String>("mobile")
                        val imagePath = call.argument<String>("imagePath")
                        val useBusinessApp = call.argument<Boolean>("useBusinessApp") ?: false
                        if (mobile != null && imagePath != null) {
                            sendImageToWhatsApp(mobile, imagePath, useBusinessApp, result)
                        } else {
                            result.error("INVALID_ARGS", "mobile and imagePath are required", null)
                        }
                    }
                    "sendMessage" -> {
                        val mobile = call.argument<String>("mobile")
                        val message = call.argument<String>("message")
                        val useBusinessApp = call.argument<Boolean>("useBusinessApp") ?: false
                        if (mobile != null && message != null) {
                            sendMessageToWhatsApp(mobile, message, useBusinessApp, result)
                        } else {
                            result.error("INVALID_ARGS", "mobile and message are required", null)
                        }
                    }
                    "isInstalled" -> {
                        val regular = isPackageInstalled("com.whatsapp")
                        val business = isPackageInstalled("com.whatsapp.w4b")
                        val resultMap = HashMap<String, Boolean>()
                        resultMap["whatsapp"] = regular
                        resultMap["whatsappBusiness"] = business
                        result.success(resultMap)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Accessibility Channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ACCESSIBILITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isEnabled" -> {
                        result.success(isAccessibilityServiceEnabled())
                    }
                    "openSettings" -> {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    }
                    "openAppInfo" -> {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", packageName, null)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    "setAutoSendMode" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        ImageSenderAccessibilityService.autoSendEnabled = enabled
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Security Channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.image_sender/security")
            .setMethodCallHandler { call, result ->
                if (call.method == "setScreenshotProtection") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // ── Cooldown Notification Channel ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.image_sender/cooldown")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scheduleNotification" -> {
                        val seconds = call.argument<Int>("seconds") ?: 3600
                        scheduleCooldownAlarm(seconds)
                        result.success(true)
                    }
                    "cancelNotification" -> {
                        cancelCooldownAlarm()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ══════════════════════════════════════════
    // ── File Access (SAF) Methods ──
    // ══════════════════════════════════════════

    private fun pickExcelFile() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_FILE_REQUEST_CODE)
    }

    private fun createLogFile() {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "text/plain"
            putExtra(Intent.EXTRA_TITLE, "ImageSender_Logs.txt")
        }
        startActivityForResult(intent, EXPORT_LOG_REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == PICK_FILE_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!

                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (e: SecurityException) {
                    // Temporary grant still works for this session
                }

                try {
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    if (bytes != null) {
                        val resultMap = HashMap<String, Any>()
                        resultMap["uri"] = uri.toString()
                        resultMap["bytes"] = bytes
                        resultMap["fileName"] = getFileName(uri)
                        pendingResult?.success(resultMap)
                    } else {
                        pendingResult?.error("READ_ERROR", "Could not read file", null)
                    }
                } catch (e: Exception) {
                    pendingResult?.error("READ_ERROR", e.message, null)
                }
            } else {
                pendingResult?.success(null)
            }
            pendingResult = null
        } else if (requestCode == EXPORT_LOG_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                try {
                    contentResolver.openOutputStream(uri, "wt")?.use { outputStream ->
                        logContentToExport?.let { content ->
                            outputStream.write(content.toByteArray())
                        }
                        outputStream.flush()
                    }
                    pendingResult?.success(uri.toString())
                } catch (e: Exception) {
                    pendingResult?.error("SAVE_ERROR", e.message, null)
                }
            } else {
                pendingResult?.success(null)
            }
            logContentToExport = null
            pendingResult = null
        }
    }

    private fun getFileName(uri: Uri): String {
        var name = "unknown.xlsx"
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(
                    android.provider.OpenableColumns.DISPLAY_NAME
                )
                if (nameIndex >= 0) {
                    name = cursor.getString(nameIndex)
                }
            }
        }
        return name
    }

    private fun saveToUri(uriString: String, bytes: ByteArray, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            contentResolver.openOutputStream(uri, "wt")?.use { outputStream ->
                outputStream.write(bytes)
                outputStream.flush()
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("SAVE_ERROR", e.message, null)
        }
    }

    private fun readFromUri(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes != null) {
                result.success(bytes)
            } else {
                result.error("READ_ERROR", "Could not read file", null)
            }
        } catch (e: Exception) {
            result.error("READ_ERROR", e.message, null)
        }
    }

    // ══════════════════════════════════════════
    // ── WhatsApp Methods ──
    // ══════════════════════════════════════════

    private fun sendImageToWhatsApp(
        mobile: String,
        imagePath: String,
        useBusinessApp: Boolean,
        result: MethodChannel.Result
    ) {
        try {
            val packageName = if (useBusinessApp) "com.whatsapp.w4b" else "com.whatsapp"

            if (!isPackageInstalled(packageName)) {
                result.error(
                    "NOT_INSTALLED",
                    if (useBusinessApp) "WhatsApp Business is not installed"
                    else "WhatsApp is not installed",
                    null
                )
                return
            }

            val imageFile = File(imagePath)
            if (!imageFile.exists()) {
                result.error("FILE_NOT_FOUND", "Image file not found: $imagePath", null)
                return
            }

            // Create content URI via FileProvider
            val imageUri: Uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                imageFile
            )

            // Clean the phone number — remove spaces, dashes, plus signs, and any trailing decimals like .0
            var cleanNumber = mobile.replace(Regex("[^0-9]"), "")
            
            // Strip leading zeros if present (e.g., 09876543210 -> 9876543210)
            while (cleanNumber.startsWith("0") && cleanNumber.length > 10) {
                cleanNumber = cleanNumber.substring(1)
            }
            
            // If the number is exactly 10 digits, assume India (+91)
            // WhatsApp JID requires the country code to work
            if (cleanNumber.length == 10) {
                cleanNumber = "91$cleanNumber"
            }

            val intent = Intent(Intent.ACTION_SEND).apply {
                setPackage(packageName)
                type = "image/*"
                putExtra(Intent.EXTRA_STREAM, imageUri)
                // The "jid" extra opens the specific contact's chat
                putExtra("jid", "$cleanNumber@s.whatsapp.net")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }

            startActivity(intent)
            result.success(true)

        } catch (e: Exception) {
            result.error("WHATSAPP_ERROR", e.message, null)
        }
    }

    private fun sendMessageToWhatsApp(
        mobile: String,
        message: String,
        useBusinessApp: Boolean,
        result: MethodChannel.Result
    ) {
        try {
            val packageName = if (useBusinessApp) "com.whatsapp.w4b" else "com.whatsapp"

            if (!isPackageInstalled(packageName)) {
                result.error(
                    "NOT_INSTALLED",
                    if (useBusinessApp) "WhatsApp Business is not installed"
                    else "WhatsApp is not installed",
                    null
                )
                return
            }

            var cleanNumber = mobile.replace(Regex("[^0-9]"), "")
            while (cleanNumber.startsWith("0") && cleanNumber.length > 10) {
                cleanNumber = cleanNumber.substring(1)
            }
            if (cleanNumber.length == 10) {
                cleanNumber = "91$cleanNumber"
            }

            val intent = Intent(Intent.ACTION_SEND).apply {
                setPackage(packageName)
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, message)
                putExtra("jid", "$cleanNumber@s.whatsapp.net")
            }

            startActivity(intent)
            result.success(true)

        } catch (e: Exception) {
            result.error("WHATSAPP_ERROR", e.message, null)
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    // ══════════════════════════════════════════
    // ── Accessibility Methods ──
    // ══════════════════════════════════════════

    private fun isAccessibilityServiceEnabled(): Boolean {
        val expectedComponentName = ComponentName(this, ImageSenderAccessibilityService::class.java)
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        val colonSplitter = TextUtils.SimpleStringSplitter(':')
        colonSplitter.setString(enabledServices)
        while (colonSplitter.hasNext()) {
            val componentNameString = colonSplitter.next()
            val enabledComponent = ComponentName.unflattenFromString(componentNameString)
            if (enabledComponent != null && enabledComponent == expectedComponentName) {
                return true
            }
        }
        return false
    }

    // ══════════════════════════════════════════
    // ── Cooldown Alarm Methods ──
    // ══════════════════════════════════════════

    private fun scheduleCooldownAlarm(seconds: Int) {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "cooldown_channel",
                "Batch Cooldown",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for when WhatsApp sending cooldown expires"
            }
            notificationManager.createNotificationChannel(channel)
        }

        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, CooldownAlarmReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            2001,
            intent,
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

    private fun cancelCooldownAlarm() {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, CooldownAlarmReceiver::class.java)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            2001,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        alarmManager.cancel(pendingIntent)
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(2001)
    }

    override fun onDestroy() {
        ImageSenderAccessibilityService.instance?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                it.disableSelf()
            }
        }
        super.onDestroy()
    }
}
