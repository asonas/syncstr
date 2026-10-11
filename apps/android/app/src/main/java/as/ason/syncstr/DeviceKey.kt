package `as`.ason.syncstr

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class DeviceKey(context: Context) {
    private val preferences = context.getSharedPreferences("identity", Context.MODE_PRIVATE)

    fun load(): ByteArray {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "syncstr-device-wrap"
        val encrypted = preferences.getString("secret", null)
        check(encrypted == null || store.containsAlias(alias)) { "端末の鍵を復元できません。登録情報を保護する鍵が見つかりません。" }
        val wrapping = if (store.containsAlias(alias)) store.getKey(alias, null) as SecretKey else {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (encrypted != null) {
            val iv = Base64.decode(requireNotNull(preferences.getString("iv", null)), Base64.NO_WRAP)
            cipher.init(Cipher.DECRYPT_MODE, wrapping, GCMParameterSpec(128, iv))
            return cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)).also { check(it.size == 32) }
        }
        val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
        cipher.init(Cipher.ENCRYPT_MODE, wrapping)
        check(preferences.edit().putString("secret", Base64.encodeToString(cipher.doFinal(secret), Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit()) { "端末の鍵を保存できません。" }
        return secret
    }
}
