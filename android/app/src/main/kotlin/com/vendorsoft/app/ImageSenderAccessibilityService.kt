package com.vendorsoft.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.Random

/**
 * Accessibility Service that auto-presses the Send button in WhatsApp.
 * 
 * This service is only active when autoSendEnabled is true.
 * It monitors WhatsApp's UI for the Send button and clicks it automatically.
 *
 * Detection strategies (in order):
 * 1. View ID lookup: com.whatsapp:id/send, com.whatsapp.w4b:id/send, etc.
 * 2. Content description & text DFS: "send" (English), "भेजें" (Hindi), "enviar" (Spanish/Portuguese),
 *    "إرسال" (Arabic), "بھیجیں" (Urdu), "পাঠান" (Bengali), "મોકલો" (Gujarati), etc.
 * 3. Partial resource ID search (contains "send", "fab_send", "media_send").
 * 4. Screen position FAB detection: Targets the circular green button in the bottom-right quadrant
 *    even when Jetpack Compose assigns no text/ID to it.
 *
 * Click strategy (humanized):
 * 1. Primary: dispatchGesture — generates real MotionEvents (ACTION_DOWN/UP) with randomized
 *    coordinates, tap duration, and timing to mimic human touch.
 * 2. Fallback: ACTION_CLICK — semantic click on node or clickable parent.
 */
class ImageSenderAccessibilityService : AccessibilityService() {

    companion object {
        /** Controls whether auto-send is active. Set from Flutter via method channel. */
        @Volatile
        var autoSendEnabled: Boolean = false

        /** Static instance for MainActivity to reference */
        @Volatile
        var instance: ImageSenderAccessibilityService? = null
        
        private const val TAG = "ImageSenderService"

        /**
         * Humanized timing constants.
         * All delays are randomized within ranges to avoid machine-detectable patterns.
         */
        // Time between "button found" and "button tapped" (simulates visual scan + finger move)
        private const val STABILIZATION_MIN_MS = 400L
        private const val STABILIZATION_MAX_MS = 900L
        // Tap hold duration (how long finger presses the button)
        private const val TAP_DURATION_MIN_MS = 80L
        private const val TAP_DURATION_MAX_MS = 150L
        // Time to wait after send before returning to VendorSoft
        private const val RETURN_MIN_MS = 2000L
        private const val RETURN_MAX_MS = 3500L

        private val random = Random()

        /** Localized "send" keywords (lowercase) */
        private val SEND_KEYWORDS = listOf(
            "send",      // English
            "भेजें",      // Hindi
            "enviar",    // Spanish / Portuguese
            "إرسال",     // Arabic
            "بھیجیں",    // Urdu
            "পাঠান",     // Bengali
            "పంపు",      // Telugu
            "அனுப்பு",    // Tamil
            "ಕಳುಹಿಸಿ",   // Kannada
            "મોકલો",     // Gujarati
            "पाठवा",     // Marathi
        )

        /** View IDs to search for the send button */
        private val SEND_VIEW_IDS = listOf(
            "com.whatsapp:id/send",
            "com.whatsapp.w4b:id/send",
            "com.whatsapp:id/send_btn",
            "com.whatsapp.w4b:id/send_btn",
            "com.whatsapp:id/media_send_btn",
            "com.whatsapp.w4b:id/media_send_btn",
            "com.whatsapp:id/fab_send",
            "com.whatsapp.w4b:id/fab_send",
            "com.whatsapp:id/send_container",
            "com.whatsapp.w4b:id/send_container",
        )

        /** Called when Flutter explicitly disables the service (e.g. user cancelled) */
        fun abortExternal() {
            autoSendEnabled = false
            instance?.let {
                it.currentState = State.IDLE
                it.returnHandler.removeCallbacks(it.returnRunnable)
                it.retryHandler.removeCallbacksAndMessages(null)
                Log.d(TAG, "Operation aborted externally. Timers cancelled and state reset.")
            }
        }
    }

    /**
     * STATE DIAGRAM:
     * IDLE: Looking for the Send button in WhatsApp.
     * STABILIZING: Found the button. Waiting a human-like delay to let animations settle.
     * WAITING_FOR_EXIT: Button clicked. Waiting for MediaComposer window to close.
     */
    enum class State {
        IDLE,
        STABILIZING,
        WAITING_FOR_EXIT
    }

    @Volatile private var currentState = State.IDLE
    private var previewActivityClassName: String = ""

    private val returnHandler = Handler(Looper.getMainLooper())
    private val retryHandler = Handler(Looper.getMainLooper())

    private val returnRunnable = Runnable {
        Log.d(TAG, "Safety timeout triggered. Executing return.")
        executeReturn()
    }

    private fun executeReturn() {
        if (currentState != State.WAITING_FOR_EXIT) return
        currentState = State.IDLE
        returnHandler.removeCallbacks(returnRunnable)
        retryHandler.removeCallbacksAndMessages(null)
        
        Log.d(TAG, "Broadcasting MESSAGE_SENT and returning to VendorPro.")
        val broadcastIntent = Intent("com.vendorsoft.app.MESSAGE_SENT")
        broadcastIntent.setPackage(applicationContext.packageName)
        sendBroadcast(broadcastIntent)
        returnToImageSender()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!autoSendEnabled || event == null) return

        val packageName = event.packageName?.toString() ?: return
        if (packageName != "com.whatsapp" && packageName != "com.whatsapp.w4b") return

        val eventType = event.eventType

        // 1. Monitor Window State Changes
        if (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val className = event.className?.toString() ?: ""
            Log.d(TAG, "Window state changed: $className")
            
            if (currentState == State.WAITING_FOR_EXIT) {
                if (className.startsWith("com.whatsapp") && !className.contains("widget") && !className.contains("Dialog")) {
                    if (className != previewActivityClassName) {
                        Log.d(TAG, "Exited preview ($previewActivityClassName) into ($className). Executing return.")
                        executeReturn()
                    }
                }
            } else {
                if (className.startsWith("com.whatsapp") && !className.contains("widget") && !className.contains("Dialog")) {
                    previewActivityClassName = className
                }
            }
        }

        // 2. Search for the Send button when IDLE
        if (currentState == State.IDLE) {
            if (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || 
                eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {

                val rootNode = getActiveRootNode() ?: return
                val sendButton = findSendButton(rootNode)

                if (sendButton != null) {
                    currentState = State.STABILIZING
                    
                    // Release nodes before delay
                    sendButton.recycle()
                    rootNode.recycle()

                    val delay = STABILIZATION_MIN_MS + (random.nextFloat() * (STABILIZATION_MAX_MS - STABILIZATION_MIN_MS)).toLong()
                    Log.d(TAG, "Send button identified. Waiting ${delay}ms before humanized tap.")

                    Handler(mainLooper).postDelayed({
                        executeClick(retryCount = 0)
                    }, delay)
                } else {
                    rootNode.recycle()
                }
            }
        }
    }

    /**
     * Gets the active root node from rootInActiveWindow or the active application window.
     */
    private fun getActiveRootNode(): AccessibilityNodeInfo? {
        rootInActiveWindow?.let { return it }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val windowList = windows
                for (w in windowList) {
                    if (w.type == AccessibilityWindowInfo.TYPE_APPLICATION && w.isActive) {
                        w.root?.let { return it }
                    }
                }
                for (w in windowList) {
                    if (w.type == AccessibilityWindowInfo.TYPE_APPLICATION) {
                        w.root?.let { return it }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error querying windows: ${e.message}")
            }
        }
        return null
    }

    /**
     * Re-finds the send button and executes the click/gesture.
     * Retries up to 4 times (200ms apart) if window was momentarily settling.
     */
    private fun executeClick(retryCount: Int = 0) {
        if (!autoSendEnabled) {
            currentState = State.IDLE
            return
        }
        
        val rootNode = getActiveRootNode()
        if (rootNode == null) {
            if (retryCount < 4) {
                Log.d(TAG, "executeClick: rootNode null, retrying (${retryCount + 1}/4)...")
                retryHandler.postDelayed({ executeClick(retryCount + 1) }, 200)
                return
            }
            Log.d(TAG, "executeClick: rootNode is null after retries, resetting to IDLE.")
            currentState = State.IDLE
            return
        }
        
        val sendButton = findSendButton(rootNode)
        if (sendButton == null) {
            rootNode.recycle()
            if (retryCount < 4) {
                Log.d(TAG, "executeClick: Send button not found, retrying (${retryCount + 1}/4)...")
                retryHandler.postDelayed({ executeClick(retryCount + 1) }, 200)
                return
            }
            Log.d(TAG, "executeClick: Send button not found after retries. Resetting to IDLE.")
            currentState = State.IDLE
            return
        }

        Log.d(TAG, "executeClick: Found send button. clickable=${sendButton.isClickable}, visible=${sendButton.isVisibleToUser}, class=${sendButton.className}")

        val rect = Rect()
        sendButton.getBoundsInScreen(rect)

        // Strategy 1: Humanized gesture dispatch (generates real MotionEvents)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !rect.isEmpty && rect.width() > 0 && rect.height() > 0) {
            // Coordinate jitter: tap within inner 60% of the button to avoid edges
            val marginX = (rect.width() * 0.20f).coerceAtLeast(2f)
            val marginY = (rect.height() * 0.20f).coerceAtLeast(2f)
            val tapX = rect.left + marginX + random.nextFloat() * ((rect.width() - 2 * marginX).coerceAtLeast(1f))
            val tapY = rect.top + marginY + random.nextFloat() * ((rect.height() - 2 * marginY).coerceAtLeast(1f))

            // Random tap hold duration (80–150ms)
            val tapDuration = TAP_DURATION_MIN_MS + (random.nextFloat() * (TAP_DURATION_MAX_MS - TAP_DURATION_MIN_MS)).toLong()

            Log.d(TAG, "Dispatching humanized gesture at (${tapX.toInt()}, ${tapY.toInt()}) for ${tapDuration}ms [bounds=$rect].")
            val path = Path()
            path.moveTo(tapX, tapY)
            val gesture = GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, tapDuration))
                .build()
            
            val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    Log.d(TAG, "Gesture completed successfully.")
                    transitionToWaitingForExit()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    Log.d(TAG, "Gesture cancelled. Falling back to ACTION_CLICK.")
                    performActionClickFallback()
                }
            }, null)

            sendButton.recycle()
            rootNode.recycle()
            
            if (!dispatched) {
                Log.d(TAG, "dispatchGesture returned false. Falling back to ACTION_CLICK.")
                performActionClickFallback()
            }
            return
        }

        // Strategy 2: ACTION_CLICK fallback
        if (sendButton.isClickable) {
            Log.d(TAG, "Using ACTION_CLICK fallback.")
            sendButton.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            sendButton.recycle()
            rootNode.recycle()
            transitionToWaitingForExit()
            return
        }

        // Strategy 3: Try clickable parent
        val clickableParent = findClickableParent(sendButton)
        if (clickableParent != null) {
            Log.d(TAG, "Using ACTION_CLICK on clickable parent.")
            clickableParent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            clickableParent.recycle()
            sendButton.recycle()
            rootNode.recycle()
            transitionToWaitingForExit()
            return
        }

        Log.d(TAG, "executeClick: Could not click send button by any method. Resetting to IDLE.")
        sendButton.recycle()
        rootNode.recycle()
        currentState = State.IDLE
    }

    /**
     * Fallback: finds the button or its parent and executes ACTION_CLICK.
     */
    private fun performActionClickFallback() {
        val root = getActiveRootNode() ?: run {
            currentState = State.IDLE
            return
        }
        val button = findSendButton(root)
        if (button != null) {
            if (button.isClickable) {
                button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                button.recycle()
                root.recycle()
                transitionToWaitingForExit()
                return
            }
            val parent = findClickableParent(button)
            if (parent != null) {
                parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                parent.recycle()
                button.recycle()
                root.recycle()
                transitionToWaitingForExit()
                return
            }
            button.recycle()
        }
        root.recycle()
        currentState = State.IDLE
    }
    
    private fun transitionToWaitingForExit() {
        autoSendEnabled = false // Prevent duplicate sends
        currentState = State.WAITING_FOR_EXIT

        val returnDelay = RETURN_MIN_MS + (random.nextFloat() * (RETURN_MAX_MS - RETURN_MIN_MS)).toLong()
        Log.d(TAG, "Send triggered. Waiting ${returnDelay}ms safety timeout before returning.")
        returnHandler.postDelayed(returnRunnable, returnDelay)
    }

    /**
     * Multi-strategy search for WhatsApp's Send button.
     */
    private fun findSendButton(rootNode: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        // Strategy 1: Known View IDs
        for (viewId in SEND_VIEW_IDS) {
            val nodes = rootNode.findAccessibilityNodeInfosByViewId(viewId)
            if (nodes != null && nodes.isNotEmpty()) {
                for (node in nodes) {
                    if (node.isVisibleToUser) {
                        Log.d(TAG, "Found send button via ViewId: $viewId")
                        nodes.filter { it != node }.forEach { it.recycle() }
                        return node
                    }
                    node.recycle()
                }
            }
        }
        
        // Strategy 2: DFS content description / text search (supports localized substring matches)
        val dfsResult = dfsFindSendButton(rootNode)
        if (dfsResult != null) {
            Log.d(TAG, "Found send button via content/text DFS.")
            return dfsResult
        }

        // Strategy 3: Screen position FAB detection (the green paper airplane button in the bottom-right)
        Log.d(TAG, "ViewId and text DFS found nothing. Trying bottom-right FAB detection.")
        return findBottomRightFab(rootNode)
    }

    /**
     * DFS traversal matching by content description, text, or resource ID.
     */
    private fun dfsFindSendButton(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val description = node.contentDescription?.toString()?.lowercase()?.trim() ?: ""
        val text = node.text?.toString()?.lowercase()?.trim() ?: ""
        val viewId = node.viewIdResourceName?.lowercase() ?: ""

        val matchesDesc = description.isNotEmpty() && SEND_KEYWORDS.any { description.contains(it) }
        val matchesText = text.isNotEmpty() && SEND_KEYWORDS.any { text.contains(it) }
        val matchesViewId = viewId.isNotEmpty() && (viewId.contains("send") || viewId.contains("fab_send"))

        if ((matchesDesc || matchesText || matchesViewId) && node.isVisibleToUser) {
            // Check if this node or an ancestor is clickable
            if (node.isClickable) {
                return node
            }
            val parent = findClickableParent(node)
            if (parent != null) {
                return parent
            }
            // Even if non-clickable, return this node so coordinate gesture can tap its bounds
            return node
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = dfsFindSendButton(child)
            if (result != null) {
                if (result != child) {
                    child.recycle()
                }
                return result
            }
            child.recycle()
        }

        return null
    }

    /**
     * Detects the circular green Send FAB located in the bottom-right quadrant of the screen.
     */
    private fun findBottomRightFab(rootNode: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val dm = resources.displayMetrics
        val screenWidth = dm.widthPixels
        val screenHeight = dm.heightPixels

        // In media composer, the send button is always in the right 35% and bottom 25% of the screen
        val rightThreshold = screenWidth * 0.65f
        val bottomThreshold = screenHeight * 0.75f

        return dfsFindFab(rootNode, rightThreshold, bottomThreshold, screenWidth, screenHeight)
    }

    private fun dfsFindFab(
        node: AccessibilityNodeInfo,
        rightThreshold: Float,
        bottomThreshold: Float,
        screenWidth: Int,
        screenHeight: Int
    ): AccessibilityNodeInfo? {
        if (node.isVisibleToUser) {
            val rect = Rect()
            node.getBoundsInScreen(rect)

            val width = rect.width()
            val height = rect.height()

            // Is in bottom-right corner and has typical FAB dimensions (not full width container)
            val isBottomRight = rect.centerX() > rightThreshold && rect.centerY() > bottomThreshold
            val isFabDimension = width in 40..(screenWidth / 3) && height in 40..(screenHeight / 4)
            val isSquarish = width > 0 && height > 0 && 
                (kotlin.math.abs(width - height).toFloat() / kotlin.math.max(width, height)) < 0.45f

            if (isBottomRight && isFabDimension && isSquarish) {
                // If this node is clickable or is a leaf node, it's our target
                if (node.isClickable || node.childCount == 0) {
                    Log.d(TAG, "FAB detection: Found send FAB (class=${node.className}, bounds=$rect, clickable=${node.isClickable})")
                    return node
                }
            }
        }

        // Traverse children to find leaf FAB node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val result = dfsFindFab(child, rightThreshold, bottomThreshold, screenWidth, screenHeight)
            if (result != null) {
                if (result != child) {
                    child.recycle()
                }
                return result
            }
            child.recycle()
        }

        return null
    }

    /**
     * Walks up the accessibility tree to find the nearest clickable ancestor (max 5 levels).
     */
    private fun findClickableParent(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current = node.parent ?: return null
        var depth = 0
        
        while (depth < 5) {
            if (current.isClickable && current.isVisibleToUser) {
                return current
            }
            val parent = current.parent
            if (parent == null) {
                current.recycle()
                return null
            }
            current.recycle()
            current = parent
            depth++
        }
        
        current.recycle()
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
            Log.e(TAG, "Error returning to ImageSender: ${e.message}")
        }
    }

    override fun onInterrupt() {
        autoSendEnabled = false
        currentState = State.IDLE
        returnHandler.removeCallbacks(returnRunnable)
        retryHandler.removeCallbacksAndMessages(null)
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

