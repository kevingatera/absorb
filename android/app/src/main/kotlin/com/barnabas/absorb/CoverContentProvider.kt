package com.barnabas.absorb

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/**
 * ContentProvider that serves locally-cached cover images to Android Auto.
 *
 * Android Auto cannot load file:// URIs directly — it requires content:// URIs.
 * This provider maps:
 *   content://com.barnabas.absorb.covers/cover/<itemId>
 * to the cover.jpg file in the item's download directory.
 *
 * Place this file at:
 *   android/app/src/main/kotlin/com/barnabas/absorb/CoverContentProvider.kt
 *
 * Register in AndroidManifest.xml inside the <application> tag:
 *
 *   <provider
 *       android:name=".CoverContentProvider"
 *       android:authorities="com.barnabas.absorb.covers"
 *       android:exported="true"
 *       android:grantUriPermissions="true" />
 */
class CoverContentProvider : ContentProvider() {

    companion object {
        const val AUTHORITY = "com.barnabas.absorb.covers"

        fun buildCoverUri(itemId: String): Uri {
            return Uri.parse("content://$AUTHORITY/cover/$itemId")
        }
    }

    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val itemId = extractItemId(uri) ?: return null
        val context = context ?: return null
        val coverFile = findCoverFile(context, itemId) ?: return null
        return ParcelFileDescriptor.open(coverFile, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /**
     * Return MIME type for the URI. Android Auto's image loader checks this
     * to determine if it can handle the content:// URI as an image.
     */
    override fun getType(uri: Uri): String = "image/jpeg"

    /**
     * Return supported stream MIME types. Android Auto may call this to verify
     * the provider can serve image data before attempting to load it.
     */
    override fun getStreamTypes(uri: Uri, mimeTypeFilter: String): Array<String>? {
        // Match any image filter (e.g. "image/*", "*/*", "image/jpeg")
        if (mimeTypeFilter == "*/*" ||
            mimeTypeFilter == "image/*" ||
            mimeTypeFilter == "image/jpeg") {
            return arrayOf("image/jpeg")
        }
        return null
    }

    /**
     * Implement query to return file metadata. Some Android Auto implementations
     * query the provider for display name and size before loading the image.
     */
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        val itemId = extractItemId(uri) ?: return null
        val context = context ?: return null
        val coverFile = findCoverFile(context, itemId) ?: return null

        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols.map { it }.toTypedArray())
        val row = cols.map { col ->
            when (col) {
                OpenableColumns.DISPLAY_NAME -> "cover.jpg"
                OpenableColumns.SIZE -> coverFile.length()
                else -> null
            }
        }.toTypedArray()
        cursor.addRow(row)
        return cursor
    }

    // ── Helpers ──

    private fun extractItemId(uri: Uri): String? {
        val segments = uri.pathSegments
        // Expected: /cover/<itemId>
        if (segments.size != 2 || segments[0] != "cover") return null
        val itemId = segments[1]
        // Sanitize — only allow alphanumeric, hyphens, underscores
        if (!itemId.matches(Regex("^[a-zA-Z0-9_\\-]+$"))) return null
        return itemId
    }

    private fun findCoverFile(context: android.content.Context, itemId: String): File? {
        // Check custom download path first (stored in SharedPreferences)
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
        val customPath = prefs.getString("flutter.custom_download_path", null)

        if (customPath != null && customPath.isNotEmpty()) {
            val file = File("$customPath/$itemId/cover.jpg")
            if (file.exists() && file.canRead()) return file
        }

        // Default: app documents directory
        val docsDir = context.filesDir?.parentFile?.let { File(it, "app_flutter/downloads") }
        if (docsDir != null) {
            val file = File("$docsDir/$itemId/cover.jpg")
            if (file.exists() && file.canRead()) return file
        }

        // Also try getExternalFilesDir path
        val extDir = context.getExternalFilesDir(null)
        if (extDir != null) {
            val file = File("${extDir.parent}/app_flutter/downloads/$itemId/cover.jpg")
            if (file.exists() && file.canRead()) return file
        }

        return null
    }

    // Not used — read-only provider
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, s: String?, sa: Array<out String>?): Int = 0
    override fun delete(uri: Uri, s: String?, sa: Array<out String>?): Int = 0
}
