package mintylinux.meshcore.wardrive

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent

class WardriveWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        private const val PREFS_NAME = "HomeWidgetPreferences"

        fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val prefs: SharedPreferences =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

            val samples = prefs.getString("samples", "0") ?: "0"
            val status = prefs.getString("status", "Idle") ?: "Idle"
            val connection = prefs.getString("connection", "---") ?: "---"
            val successRate = prefs.getString("success_rate", "--") ?: "--"
            val distance = prefs.getString("distance", "--") ?: "--"

            val views = RemoteViews(context.packageName, R.layout.wardrive_widget_layout)
            views.setTextViewText(R.id.widget_samples, samples)
            views.setTextViewText(R.id.widget_status, status)
            views.setTextViewText(R.id.widget_connection, connection)
            views.setTextViewText(R.id.widget_success_rate, successRate)
            views.setTextViewText(R.id.widget_distance, distance)

            // Set status color: green when tracking, gray when idle
            val statusColor = if (status == "Tracking") 0xFF00E676.toInt() else 0xFF888888.toInt()
            views.setTextColor(R.id.widget_status, statusColor)

            // Set connection color: green when connected, gray when not
            val connColor = if (connection == "---" || connection == "Off") 0xFF888888.toInt() else 0xFF00E676.toInt()
            views.setTextColor(R.id.widget_connection, connColor)

            // Tap widget to open app
            val intent = Intent(context, MainActivity::class.java)
            val pendingIntent = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_status, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
