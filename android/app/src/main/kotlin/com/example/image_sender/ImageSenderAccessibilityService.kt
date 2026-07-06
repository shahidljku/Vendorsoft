package com.example.image_sender

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Accessibility Service that auto-presses the Send button in WhatsApp.
 * 
 * This service is only active when autoSendEnabled is true.
 * It monitors WhatsApp's UI for the Send button and clicks it automatically.
 */
class ImageSenderAccessibilityService : AccessibilityService() {

    companion object {
        /** Controls whether auto-send is active. Set from Flutter via method channel. */
        @Volatile
        var autoSendEnabled: Boolean = false

        /** Tracks whether we just auto-pressed Send (to avoid double-pressing). */
        @Volatile
        var sendPressed: Boolean = false

        /** Static instance for MainActivity to reference */
        @Volatile
        var instance: ImageSenderAccessibilityService? = null
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!autoSendEnabled || event == null) return

        // Only act on WhatsApp window changes
        val packageName = event.packageName?.toString() ?: return
        if (packageName != "com.whatsapp" && packageName != "com.whatsapp.w4b") return

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {

            if (sendPressed) return // Already pressed, waiting for result

            val rootNode = rootInActiveWindow ?: return
            val sendButton = findSendButton(rootNode)

            if (sendButton != null) {
                sendButton.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                sendPressed = true
                autoSendEnabled = false // Disable after pressing to avoid loops

                // Wait briefly then return to Image Sender
                android.os.Handler(mainLooper).postDelayed({
                    val broadcastIntent = Intent("com.example.image_sender.MESSAGE_SENT")
                    broadcastIntent.setPackage(packageName)
                    sendBroadcast(broadcastIntent)
                    returnToImageSender()
                    sendPressed = false
                }, 1500) // 1.5 second delay to let the message send
            }

            rootNode.recycle()
        }
    }

    /**
     * Searches the accessibility tree for WhatsApp's Send button.
     * WhatsApp's Send button has content description "Send" in English.
     * We also check for common localized variants.
     */
    private fun findSendButton(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        // Check by content description
        val description = node.contentDescription?.toString()?.lowercase() ?: ""
        if (description == "send" || description == "भेजें" || description == "enviar") {
            if (node.isClickable) {
                return node
            }
        }

        // Check by resource ID (WhatsApp uses specific IDs)
        val viewId = node.viewIdResourceName ?: ""
        if (viewId.contains("send") && node.isClickable) {
            return node
        }

        // Recurse through children
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = findSendButton(child)
            if (result != null) {
                return result
            }
            child.recycle()
        }

        return null
    }

    private fun returnToImageSender() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            }
            startActivity(intent)
        } catch (e: Exception) {
            // Silently fail — user can manually return
        }
    }

    override fun onInterrupt() {
        autoSendEnabled = false
        sendPressed = false
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }
}
