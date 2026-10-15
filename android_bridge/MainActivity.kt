package sa.masroof.masroof_smart

import android.Manifest
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "sa.masroof.smart/sms"
    private val requestCode = 7401
    private var pending: MethodChannel.Result? = null
    private var enabledBanks: Set<String> = emptySet()
    private var startMillis: Long = 0L
    private var endMillis: Long? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            if (call.method == "hasSmsPermission") {
                result.success(ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED)
                return@setMethodCallHandler
            }
            if (call.method != "readBankSms") { result.notImplemented(); return@setMethodCallHandler }
            @Suppress("UNCHECKED_CAST")
            val args = call.arguments as? Map<String, Any?> ?: emptyMap()
            @Suppress("UNCHECKED_CAST")
            enabledBanks = (args["enabledBanks"] as? List<String>)?.toSet() ?: emptySet()
            startMillis = (args["startMillis"] as? Number)?.toLong() ?: 0L
            endMillis = (args["endMillis"] as? Number)?.toLong()
            if (enabledBanks.isEmpty()) { result.success(emptyList<Map<String, Any>>()); return@setMethodCallHandler }
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
                result.success(readMessages(startMillis, endMillis))
            } else {
                pending = result
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_SMS), requestCode)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == this.requestCode) {
            val result = pending
            pending = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) result?.success(readMessages(startMillis, endMillis))
            else result?.error("SMS_PERMISSION_DENIED", "SMS permission was not granted", null)
        }
    }

    private fun readMessages(fromMillis: Long, throughMillis: Long?): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < 19) return emptyList()
        val aliases = mapOf(
            "مصرف الراجحي" to listOf("rajhi", "alrajhi", "الراجحي"),
            "الأهلي السعودي" to listOf("snb", "alahli", "الأهلي"),
            "بنك الرياض" to listOf("riyad", "الرياض"),
            "مصرف الإنماء" to listOf("alinma", "الإنماء"),
            "بنك البلاد" to listOf("bilad", "البلاد"),
            "البنك السعودي الأول" to listOf("sab", "alawwal", "sabb", "ساب"),
            "البنك العربي الوطني" to listOf("anb", "العربي"),
            "بنك الجزيرة" to listOf("bankaljazira", "الجزيرة"),
            "بنك الخليج الدولي" to listOf("gib", "الخليج"),
            "البنك السعودي للاستثمار" to listOf("saib", "الاستثمار"),
            "بنك الإمارات دبي الوطني" to listOf("enbd", "الإمارات دبي"),
            "بنك D360" to listOf("d360", "دي 360"),
            "بنك إس تي سي" to listOf("stc bank", "stcbank", "إس تي سي")
        )
        val allowed = enabledBanks.flatMap { aliases[it] ?: emptyList() }.map { it.lowercase() }
        if (allowed.isEmpty()) return emptyList()
        val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE)
        val result = mutableListOf<Map<String, Any>>()
        val selection = if (throughMillis == null) "${Telephony.Sms.DATE} >= ?" else "${Telephony.Sms.DATE} >= ? AND ${Telephony.Sms.DATE} <= ?"
        val selectionArgs = if (throughMillis == null) arrayOf(fromMillis.toString()) else arrayOf(fromMillis.toString(), throughMillis.toString())
        val cursor: Cursor? = contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI, projection, selection, selectionArgs, "${Telephony.Sms.DATE} DESC")
        cursor?.use {
            val idIndex = it.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressIndex = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIndex = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIndex = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (it.moveToNext()) {
                val sender = it.getString(addressIndex) ?: ""
                val lower = sender.lowercase()
                val match = enabledBanks.firstOrNull { bank -> (aliases[bank] ?: emptyList()).any { lower.contains(it.lowercase()) } } ?: continue
                val body = it.getString(bodyIndex) ?: ""
                val lowerBody = body.lowercase()
                if (listOf("otp", "one-time", "verification", "verify", "رمز", "تحقق", "كود", "temporary password", "security code", "رمز الدخول", "رمز التفعيل").any { lowerBody.contains(it) }) continue
                result.add(mapOf("id" to it.getString(idIndex), "sender" to sender, "body" to body, "date" to it.getLong(dateIndex), "bank" to match))
            }
        }
        return result
    }
}
