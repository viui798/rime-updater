package com.viui798.rime_updater

import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class RimeFilesTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val service = RimeFileService()
    private lateinit var root: File
    @Before fun setup() {
        root = File(context.getExternalFilesDir(null), "test-${UUID.randomUUID()}").apply { mkdirs() }
        File(root, "default.yaml").writeText("old")
    }
    @After fun clean() { root.deleteRecursively() }
    private fun hash(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun commit(expected: JSONObject, writes: Map<String, String>) {
        val bundle = File(context.cacheDir, "test-${UUID.randomUUID()}.zip")
        try {
            ZipOutputStream(bundle.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("__manifest__.json"))
                zip.write(JSONObject().put("expected", expected).put("writes", JSONArray(writes.keys.toList())).toString().toByteArray()); zip.closeEntry()
                for ((path, text) in writes) { zip.putNextEntry(ZipEntry(path)); zip.write(text.toByteArray()); zip.closeEntry() }
            }
            ParcelFileDescriptor.open(bundle, ParcelFileDescriptor.MODE_READ_ONLY).use { service.commit(root.path, it) }
        } finally { bundle.delete() }
    }
    @Test fun discoversReadsAndSkipsBuild() {
        File(root, "build").mkdir(); File(root, "build/ignored").writeText("generated")
        assertTrue(JSONObject(service.inspect(root.path)).getBoolean("found"))
        assertEquals(listOf("default.yaml"), JSONArray(service.files(root.path)).let { (0 until it.length()).map(it::getString) })
        assertEquals("old", ParcelFileDescriptor.AutoCloseInputStream(service.read(root.path, "default.yaml")).bufferedReader().use { it.readText() })
    }
    @Test fun discoversNestedSchemeRootsWithoutTargetingTheirContainer() {
        File(root, "default.yaml").delete()
        for (name in listOf("九键虎", "虎整句", "schemas/另一个方案")) {
            File(root, name).mkdirs(); File(root, "$name/default.yaml").writeText("config: {}")
        }
        File(root, "conf").mkdir(); File(root, "conf/default.yaml").writeText("frontend: settings")
        val found = JSONArray(service.discoverRoots(root.path))
        val paths = (0 until found.length()).map { found.getJSONObject(it).getString("path") }.toSet()
        assertEquals(setOf("${root.path}/九键虎", "${root.path}/虎整句", "${root.path}/schemas/另一个方案"), paths)
        assertFalse(paths.contains(root.path))
    }
    @Test fun commitsOverwriteCreateDeleteAndBackup() {
        File(root, "remove.yaml").writeText("delete me")
        commit(JSONObject().put("default.yaml", hash("old")).put("remove.yaml", hash("delete me"))
            .put("new.yaml", JSONObject.NULL).put(".cheese-tiger-backup/test/default.yaml", JSONObject.NULL),
            mapOf("default.yaml" to "new", "new.yaml" to "added", ".cheese-tiger-backup/test/default.yaml" to "old"))
        assertEquals("new", File(root, "default.yaml").readText())
        assertFalse(File(root, "remove.yaml").exists())
        assertEquals("added", File(root, "new.yaml").readText())
        assertEquals("old", File(root, ".cheese-tiger-backup/test/default.yaml").readText())
    }
    @Test fun conflictRejectsEntireBatch() {
        File(root, "changed.yaml").writeText("input method edited")
        try {
            commit(JSONObject().put("default.yaml", hash("old")).put("changed.yaml", hash("before")),
                mapOf("default.yaml" to "should not write", "changed.yaml" to "should not write"))
            fail("must reject conflict")
        } catch (_: IllegalStateException) { }
        assertEquals("old", File(root, "default.yaml").readText())
        assertEquals("input method edited", File(root, "changed.yaml").readText())
        assertFalse(root.listFiles()!!.any { it.name.startsWith(".rime-updater-txn-") })
    }
    @Test fun restoresEarlierWritesWhenLaterWriteFails() {
        File(root, "z-blocked").writeText("this parent is a file")
        try {
            commit(JSONObject().put("default.yaml", hash("old")).put("z-blocked/new.yaml", JSONObject.NULL),
                mapOf("default.yaml" to "new", "z-blocked/new.yaml" to "cannot write"))
            fail("must fail and restore earlier writes")
        } catch (_: IllegalStateException) { }
        assertEquals("old", File(root, "default.yaml").readText())
        assertEquals("this parent is a file", File(root, "z-blocked").readText())
        assertFalse(root.listFiles()!!.any { it.name.startsWith(".rime-updater-txn-") })
    }
    @Test fun rejectsTraversalAndPrivateRoots() {
        try { service.read(root.path, "../outside"); fail("must reject traversal") } catch (_: IllegalArgumentException) { }
        try { service.files(context.filesDir.path); fail("must reject private root") } catch (_: IllegalArgumentException) { }
        try {
            commit(JSONObject().put("../outside", JSONObject.NULL), mapOf("../outside" to "escape")); fail("must reject zip traversal")
        } catch (_: IllegalStateException) { }
        assertFalse(File(root.parentFile, "outside").exists())
    }
}
