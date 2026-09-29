package io.github.kylosonic.proxytunnel.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Password storage backed by the Android Keystore.
 *
 * The AES key is generated inside the Keystore and never leaves it — the app holds
 * only a handle, and on devices with a secure element the key material is not
 * extractable at all. Each secret is encrypted with a fresh 96-bit GCM IV, and the
 * stored blob is `iv || ciphertext`, base64.
 *
 * Written by hand rather than using `EncryptedSharedPreferences` because that
 * library is deprecated and still ships as an alpha; this is sixty lines of
 * well-understood code with no version risk.
 *
 * Passwords are never written to logs, never put in an Intent, and never included
 * in a diagnostic export.
 */
class SecretStore(context: Context) {

    private val prefs = context.getSharedPreferences("proxytunnel.secrets", Context.MODE_PRIVATE)
    private val lock = Any()

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // Deliberately NOT requiring user authentication: a VPN tunnel has to
                // come up when the phone boots and the screen is locked, and a
                // per-use biometric prompt would make that impossible.
                .setUserAuthenticationRequired(false)
                .build()
        )
        return generator.generateKey()
    }

    fun put(key: String, value: String) = synchronized(lock) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val blob = cipher.iv + ciphertext
        prefs.edit().putString(key, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    fun get(key: String): String? = synchronized(lock) {
        val encoded = prefs.getString(key, null) ?: return null
        return runCatching {
            val blob = Base64.decode(encoded, Base64.NO_WRAP)
            if (blob.size <= IV_BYTES) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES)
            )
            String(cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES), Charsets.UTF_8)
        }.getOrNull()
    }

    fun remove(key: String) = synchronized(lock) {
        prefs.edit().remove(key).apply()
    }

    fun has(key: String): Boolean = prefs.contains(key)

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "proxytunnel.secrets.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BITS = 128

        /** One password per profile, so deleting a profile deletes exactly one secret. */
        fun passwordKey(profileId: String) = "password.$profileId"
    }
}
