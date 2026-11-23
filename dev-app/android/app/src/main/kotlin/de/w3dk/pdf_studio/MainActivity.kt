package de.w3dk.pdf_studio

import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory
import com.tom_roush.pdfbox.util.Matrix
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.Calendar
import java.util.concurrent.Executors

/**
 * Nativer Teil von PDF-Studio:
 *  - export: baut das PDF mit PDFBox (Original-Seiten bleiben Vektor/Text)
 *  - saveToDownloads: Kopie nach Download/PDF-Studio (MediaStore)
 *  - listSaved / copySaved / renameSaved / deleteSaved: Liste der Startseite = Inhalt von
 *    Download/PDF-Studio (nur Dateien, die diese App angelegt hat – so will es Android)
 *  - openExternal: PDF in einer Anzeige-App öffnen
 *  - takeIncoming / "incoming": per „Öffnen mit“ oder „Teilen“ empfangene PDFs
 *  - pdfInfo / pdfRender / pdfClose: Anzeige mit dem eingebauten Android-PdfRenderer
 */
class MainActivity : FlutterActivity() {
    private val channelName = "de.w3dk.pdf_studio/native"
    private val executor = Executors.newSingleThreadExecutor()
    // PdfRenderer ist nicht threadsicher: alle Anzeige-Aufrufe laufen nacheinander auf diesem Thread.
    private val renderExecutor = Executors.newSingleThreadExecutor()
    private val renderers = LinkedHashMap<String, Pair<ParcelFileDescriptor, PdfRenderer>>(8, 0.75f, true)
    private var channel: MethodChannel? = null
    private val pending = mutableListOf<String>()
    private var pdfBoxReady = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) collectIncoming(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val before = pending.size
        collectIncoming(intent)
        if (pending.size > before) {
            val list = ArrayList(pending)
            pending.clear()
            channel?.invokeMethod("incoming", list)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeIncoming" -> {
                    val list = ArrayList(pending)
                    pending.clear()
                    result.success(list)
                }
                "export" -> {
                    val spec = call.argument<String>("spec")
                    val out = call.argument<String>("out")
                    if (spec == null || out == null) {
                        result.error("bad_args", "spec/out fehlt", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            export(spec, out)
                            runOnUiThread { result.success(out) }
                        } catch (e: Throwable) {
                            File(out).delete()
                            runOnUiThread {
                                result.error("export_failed", e.message ?: e.javaClass.simpleName, null)
                            }
                        }
                    }
                }
                "saveToDownloads" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (path == null || name == null) {
                        result.error("bad_args", "path/name fehlt", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            val r = saveToDownloads(File(path), name)
                            runOnUiThread { result.success(r) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("save_failed", e.message, null) }
                        }
                    }
                }
                "pdfInfo" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path fehlt", null)
                        return@setMethodCallHandler
                    }
                    renderExecutor.execute {
                        try {
                            val sizes = pdfInfo(path)
                            runOnUiThread { result.success(sizes) }
                        } catch (e: Throwable) {
                            closeRenderer(path)
                            runOnUiThread { result.error("pdf_open_failed", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }
                }
                "pdfRender" -> {
                    val path = call.argument<String>("path")
                    val index = call.argument<Int>("index") ?: 0
                    val width = call.argument<Int>("width") ?: 800
                    if (path == null) {
                        result.error("bad_args", "path fehlt", null)
                        return@setMethodCallHandler
                    }
                    renderExecutor.execute {
                        try {
                            val r = pdfRender(path, index, width)
                            runOnUiThread { result.success(r) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("pdf_render_failed", e.message ?: e.javaClass.simpleName, null) }
                        }
                    }
                }
                "pdfClose" -> {
                    val path = call.argument<String>("path")
                    renderExecutor.execute {
                        if (path == null) closeAllRenderers() else closeRenderer(path)
                    }
                    result.success(null)
                }
                "listSaved" -> io(result) { listSaved() }
                "copySaved" -> {
                    val id = call.argument<Number>("id")?.toLong()
                    val dest = call.argument<String>("dest")
                    if (id == null || dest == null) return@setMethodCallHandler result.error("bad_args", "id/dest fehlt", null)
                    io(result) { copySaved(id, File(dest)); dest }
                }
                "renameSaved" -> {
                    val id = call.argument<Number>("id")?.toLong()
                    val name = call.argument<String>("name")
                    if (id == null || name == null) return@setMethodCallHandler result.error("bad_args", "id/name fehlt", null)
                    io(result) { renameSaved(id, name) }
                }
                "deleteSaved" -> {
                    val id = call.argument<Number>("id")?.toLong()
                    if (id == null) return@setMethodCallHandler result.error("bad_args", "id fehlt", null)
                    io(result) { deleteSaved(id) }
                }
                "openExternal" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && openExternal(File(path)))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        renderExecutor.execute { closeAllRenderers() }
        renderExecutor.shutdown()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ Eingehende PDFs

    private fun collectIncoming(intent: Intent?) {
        if (intent == null) return
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> {
                @Suppress("DEPRECATION")
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
        }
        if (uris.isEmpty()) return
        val dir = File(cacheDir, "incoming").apply { mkdirs() }
        for (u in uris) {
            try {
                var name = displayName(u) ?: "Dokument.pdf"
                name = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                if (!name.lowercase().endsWith(".pdf")) name += ".pdf"
                val f = File(dir, "${System.currentTimeMillis()}_$name")
                contentResolver.openInputStream(u)?.use { input ->
                    f.outputStream().use { input.copyTo(it) }
                }
                if (f.length() > 0) pending.add(f.absolutePath)
            } catch (_: Exception) {
            }
        }
        // Absicht verbrauchen, damit sie bei Neustart nicht erneut greift
        intent.action = Intent.ACTION_MAIN
    }

    private fun displayName(u: Uri): String? {
        if (u.scheme == "file") return u.lastPathSegment
        return try {
            contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------ Anzeige (PdfRenderer)

    private fun renderer(path: String): PdfRenderer {
        renderers[path]?.let { return it.second }
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        val r = try {
            PdfRenderer(fd)
        } catch (e: Throwable) {
            fd.close()
            throw e
        }
        renderers[path] = fd to r
        while (renderers.size > 6) {
            val oldest = renderers.keys.first()
            closeRenderer(oldest)
        }
        return r
    }

    private fun closeRenderer(path: String) {
        renderers.remove(path)?.let { (fd, r) ->
            try { r.close() } catch (_: Throwable) {}
            try { fd.close() } catch (_: Throwable) {}
        }
    }

    private fun closeAllRenderers() {
        for (k in renderers.keys.toList()) closeRenderer(k)
    }

    /** Seitengrößen in Punkt (bereits gedreht), als [w0, h0, w1, h1, …]. */
    private fun pdfInfo(path: String): DoubleArray {
        val r = renderer(path)
        val out = DoubleArray(r.pageCount * 2)
        for (i in 0 until r.pageCount) {
            r.openPage(i).use { pg ->
                out[i * 2] = pg.width.toDouble()
                out[i * 2 + 1] = pg.height.toDouble()
            }
        }
        return out
    }

    /** Rendert eine Seite auf weißem Grund; liefert Breite, Höhe und RGBA-Pixel. */
    private fun pdfRender(path: String, index: Int, width: Int): Map<String, Any> {
        val r = renderer(path)
        r.openPage(index).use { pg ->
            val w = width.coerceIn(16, 4096)
            val h = (w.toDouble() * pg.height / pg.width).toInt().coerceIn(16, 6000)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try {
                bmp.eraseColor(Color.WHITE)
                pg.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val buf = ByteBuffer.allocate(w * h * 4)
                bmp.copyPixelsToBuffer(buf) // Speicherreihenfolge R, G, B, A
                return mapOf("w" to w, "h" to h, "px" to buf.array())
            } finally {
                bmp.recycle()
            }
        }
    }

    // ------------------------------------------------------------------ Export

    private fun export(specJson: String, outPath: String) {
        if (!pdfBoxReady) {
            PDFBoxResourceLoader.init(applicationContext)
            pdfBoxReady = true
        }
        val spec = JSONObject(specJson)
        val pages = spec.getJSONArray("pages")
        val opened = HashMap<String, PDDocument>()
        val out = PDDocument(MemoryUsageSetting.setupMixed(48L * 1024 * 1024))
        try {
            for (i in 0 until pages.length()) {
                val pj = pages.getJSONObject(i)
                val added = pj.optInt("rotate", 0)
                val path = pj.getString("path")
                val page: PDPage
                if (pj.getString("type") == "pdf") {
                    val src = opened.getOrPut(path) {
                        PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                    }
                    val sp = src.getPage(pj.getInt("index"))
                    // geerbte Eigenschaften fest an die Seite schreiben
                    sp.mediaBox = sp.mediaBox
                    sp.cropBox = sp.cropBox
                    sp.resources = sp.resources
                    val baseRot = sp.rotation
                    page = out.importPage(sp)
                    page.rotation = norm(baseRot + added)
                } else {
                    val w = pj.getDouble("wPt").toFloat()
                    val h = pj.getDouble("hPt").toFloat()
                    page = PDPage(PDRectangle(w, h))
                    out.addPage(page)
                    val img = if (path.lowercase().endsWith(".png")) {
                        val bmp = BitmapFactory.decodeFile(path)
                            ?: throw IllegalStateException("Bild nicht lesbar")
                        LosslessFactory.createFromImage(out, bmp).also { bmp.recycle() }
                    } else {
                        FileInputStream(path).use { JPEGFactory.createFromStream(out, it) }
                    }
                    PDPageContentStream(out, page).use { cs -> cs.drawImage(img, 0f, 0f, w, h) }
                    page.rotation = norm(added)
                }
                val ov = pj.optJSONArray("overlays")
                if (ov != null && ov.length() > 0) stamp(out, page, ov)
            }
            out.documentInformation.title = spec.optString("title", "Dokument")
            out.documentInformation.creator = "PDF-Studio (InLAB Consulting LLC)"
            out.documentInformation.producer = "PDF-Studio"
            out.documentInformation.creationDate = Calendar.getInstance()
            out.save(File(outPath))
        } finally {
            out.close()
            for (d in opened.values) {
                try {
                    d.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun norm(r: Int) = ((r % 360) + 360) % 360

    /** Elemente (PNG) aufrecht in Anzeige-Ausrichtung auf die Seite setzen. */
    private fun stamp(doc: PDDocument, page: PDPage, ov: JSONArray) {
        // Inhalts-Array nicht mit Duplikaten teilen
        val cos = page.cosObject
        val c = cos.getDictionaryObject(COSName.CONTENTS)
        if (c is COSArray) {
            val copy = COSArray()
            for (k in 0 until c.size()) copy.add(c.get(k))
            cos.setItem(COSName.CONTENTS, copy)
        }

        val box = page.cropBox
        val bw = box.width
        val bh = box.height
        val llx = box.lowerLeftX
        val lly = box.lowerLeftY
        val r = norm(page.rotation)
        val dispW = if (r == 90 || r == 270) bh else bw
        val dispH = if (r == 90 || r == 270) bw else bh
        // Anzeige (x rechts, y unten) -> Seitenkoordinaten: ux = a*x + c*y + e, uy = b*x + d*y + f
        val (a, b, cc, d, e, f) = when (r) {
            90 -> M6(0f, 1f, 1f, 0f, 0f, 0f)
            180 -> M6(-1f, 0f, 0f, 1f, bw, 0f)
            270 -> M6(0f, -1f, -1f, 0f, bw, bh)
            else -> M6(1f, 0f, 0f, -1f, 0f, bh)
        }
        PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
            for (i in 0 until ov.length()) {
                val o = ov.getJSONObject(i)
                val bmp = BitmapFactory.decodeFile(o.getString("png")) ?: continue
                val img = LosslessFactory.createFromImage(doc, bmp)
                bmp.recycle()
                val x0 = (o.getDouble("x") * dispW).toFloat()
                val y0 = (o.getDouble("y") * dispH).toFloat()
                val w = (o.getDouble("w") * dispW).toFloat()
                val h = (o.getDouble("h") * dispH).toFloat()
                // Ecke unten-links des Bildes in Anzeige-Koordinaten: (x0, y0 + h)
                val tx = a * x0 + cc * (y0 + h) + e + llx
                val ty = b * x0 + d * (y0 + h) + f + lly
                cs.drawImage(img, Matrix(a * w, b * w, -cc * h, -d * h, tx, ty))
            }
        }
    }

    private data class M6(val a: Float, val b: Float, val c: Float, val d: Float, val e: Float, val f: Float)

    // ------------------------------------------------------------------ Downloads / Anzeigen

    private fun saveToDownloads(src: File, name: String): String {
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/PDF-Studio")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Downloads-Ordner nicht erreichbar")
        try {
            resolver.openOutputStream(uri)?.use { os -> src.inputStream().use { it.copyTo(os) } }
                ?: throw IllegalStateException("Schreiben nicht möglich")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return displayName(uri) ?: name
    }

    // ------------------------------------------------------------------ Download/PDF-Studio

    private val savedRelPath get() = Environment.DIRECTORY_DOWNLOADS + "/PDF-Studio/"

    private fun savedUri(id: Long): Uri = ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, id)

    /** Läuft auf dem IO-Thread, Ergebnis/Fehler zurück auf den UI-Thread. */
    private fun io(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val r = block()
                runOnUiThread { result.success(r) }
            } catch (e: RecoverableSecurityException) {
                runOnUiThread { result.error("denied", "Diese Datei wurde nicht von PDF-Studio angelegt.", null) }
            } catch (e: Throwable) {
                runOnUiThread { result.error("io_failed", e.message ?: e.toString(), null) }
            }
        }
    }

    /** PDFs in Download/PDF-Studio, neueste zuerst: [{id, name, size, modified(ms)}]. */
    private fun listSaved(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val proj = arrayOf(
            MediaStore.Downloads._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED,
        )
        val sel = "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.IS_PENDING}=0"
        contentResolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI, proj, sel, arrayOf(savedRelPath),
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!name.endsWith(".pdf", ignoreCase = true)) continue
                out.add(mapOf(
                    "id" to c.getLong(0), "name" to name,
                    "size" to (if (c.isNull(2)) 0L else c.getLong(2)),
                    "modified" to (if (c.isNull(3)) 0L else c.getLong(3) * 1000L),
                ))
            }
        }
        return out
    }

    private fun copySaved(id: Long, dest: File) {
        dest.parentFile?.mkdirs()
        contentResolver.openInputStream(savedUri(id))?.use { input ->
            dest.outputStream().use { input.copyTo(it) }
        } ?: throw IllegalStateException("Datei nicht lesbar")
    }

    /** Liefert den tatsächlich vergebenen Namen. */
    private fun renameSaved(id: Long, name: String): String {
        val uri = savedUri(id)
        val v = ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, name) }
        if (contentResolver.update(uri, v, null, null) < 1) throw IllegalStateException("Umbenennen nicht möglich")
        return displayName(uri) ?: name
    }

    private fun deleteSaved(id: Long): Boolean = contentResolver.delete(savedUri(id), null, null) > 0

    private fun openExternal(file: File): Boolean {
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/pdf")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(i, "PDF anzeigen").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }
}
