package com.viui798.rime_updater

import android.app.Activity
import android.content.ComponentName
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import rikka.shizuku.Shizuku
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ShizukuBridge(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var remote: IRimeFiles? = null
    private var waiting: MethodChannel.Result? = null
    private val args = Shizuku.UserServiceArgs(ComponentName(activity, RimeFileService::class.java))
        .daemon(false).processNameSuffix("rime_files").version(3)
    private val listener = Shizuku.OnRequestPermissionResultListener { code, grant ->
        if (code == 701) { waiting?.success(grant == PackageManager.PERMISSION_GRANTED); waiting = null }
    }
    init { Shizuku.addRequestPermissionResultListener(listener) }
    fun dispose() {
        Shizuku.removeRequestPermissionResultListener(listener)
        waiting?.error("closed", "页面已关闭", null); waiting = null
        worker.shutdown()
    }
    private fun status(): Map<String, Any> {
        val running = Shizuku.pingBinder()
        return mapOf("running" to running, "granted" to (running && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED))
    }
    private fun service(): IRimeFiles {
        check(status()["granted"] == true) { "请先启动 Shizuku 并授权 Rime 更新器" }
        remote?.takeIf { it.asBinder().pingBinder() }?.let { return it }
        val latch = CountDownLatch(1)
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { remote = IRimeFiles.Stub.asInterface(binder); latch.countDown() }
            override fun onServiceDisconnected(name: ComponentName) { remote = null }
        }
        var bindingError: Throwable? = null
        main.post {
            try { Shizuku.bindUserService(args, connection) }
            catch (error: Throwable) { bindingError = error; latch.countDown() }
        }
        check(latch.await(15, TimeUnit.SECONDS)) { "Shizuku 文件服务连接超时" }
        bindingError?.let { throw IllegalStateException(it.message, it) }
        return checkNotNull(remote)
    }
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (!call.method.startsWith("shizuku")) return false
        if (call.method == "shizukuStatus") { result.success(status()); return true }
        if (call.method == "shizukuRequest") {
            if (!Shizuku.pingBinder()) result.error("stopped", "请先打开 Shizuku 并启动服务", null)
            else if (status()["granted"] == true) result.success(true)
            else if (waiting != null) result.error("busy", "正在等待授权", null)
            else { waiting = result; Shizuku.requestPermission(701) }
            return true
        }
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "shizukuDiscover" -> discover()
                    "shizukuStage" -> {
                        val svc = service()
                        val root = call.argument<String>("root")!!
                        val dest = File(activity.cacheDir, "rime-stage-${java.util.UUID.randomUUID()}").apply { mkdir() }
                        try {
                            val entries = JSONArray(svc.files(root))
                            for (i in 0 until entries.length()) {
                                val rel = entries.getString(i)
                                val output = File(dest, rel)
                                require(output.canonicalPath.startsWith(dest.canonicalPath + "/"))
                                output.parentFile!!.mkdirs()
                                ParcelFileDescriptor.AutoCloseInputStream(svc.read(root, rel)).use { input ->
                                    output.outputStream().use { input.copyTo(it) }
                                }
                            }
                            dest.path
                        } catch (error: Exception) { dest.deleteRecursively(); throw error }
                    }
                    "shizukuCommit" -> {
                        val bundle = File(call.argument<String>("bundle")!!)
                        require(bundle.canonicalPath.startsWith(activity.cacheDir.canonicalPath + "/"))
                        ParcelFileDescriptor.open(bundle, ParcelFileDescriptor.MODE_READ_ONLY).use {
                            service().commit(call.argument<String>("root")!!, it)
                        }
                    }
                    else -> error("未知文件操作")
                }
                main.post { result.success(value) }
            } catch (error: Exception) { main.post { result.error("shizuku", error.message ?: error.toString(), null) } }
        }
        return true
    }
    private fun discover(): String {
        val result = JSONArray()
        val manager = activity.getSystemService(Activity.INPUT_METHOD_SERVICE) as InputMethodManager
        val packages = manager.inputMethodList.associate { it.packageName to it.loadLabel(activity.packageManager).toString() }.toMutableMap()
        // Some forks expose the engine through a separate app, without an IME service of their own.
        for (pkg in listOf("com.osfans.trime", "com.osfans.trime.mie", "com.viui.trime.cheese", "org.fcitx.fcitx5.android.fx.rime", "com.ihsiao.apps.hamster", "com.vyv.tigertyper", "com.fxliang.foxy")) {
            try { val info = activity.packageManager.getApplicationInfo(pkg, 0); packages.putIfAbsent(pkg, info.loadLabel(activity.packageManager).toString()) } catch (_: Exception) { }
        }
        val svc = service()
        for ((pkg, label) in packages) {
            val isRime = pkg.contains("trime") || pkg.contains("rime") || pkg.contains("hamster") || pkg.contains("tigertyper") || pkg == "com.fxliang.foxy"
            if (!isRime) continue
            var found = false
            val suffixes = if (pkg == "com.fxliang.foxy") listOf("foxy/rime") else
                listOf("rime", "data/rime", "Rime", "RimeUserData", "fcitx5/rime")
            for (suffix in suffixes) {
                val path = "/storage/emulated/0/Android/data/$pkg/files/$suffix"
                try {
                    val roots = JSONArray(svc.discoverRoots(path))
                    if (roots.length() == 0) continue
                    for (index in 0 until roots.length()) {
                        val info = roots.getJSONObject(index)
                        val suffix = info.optString("suffix")
                        info.put("label", if (suffix.isEmpty()) label else "$label · $suffix").put("package", pkg)
                        result.put(info)
                    }
                    found = true
                    break // Avoid aliases such as rime/Rime on case-folded shared storage.
                } catch (_: Exception) { }
            }
            if (!found) result.put(JSONObject().put("label", label).put("package", pkg).put("found", false))
        }
        return result.toString()
    }
}
