/*
 * hook_sign.js — 定位零跑 APP 的签名/加密算法
 * 用法:
 *   frida -U -f com.leapmotor.app -l frida/hook_sign.js --no-pause
 *
 * 思路: 车控签名 99% 走 MessageDigest / Mac / Cipher，
 *       或者把 Java 字符串丢进 native (JNI) 做加密。
 *       本脚本把三层的入参/出参全打出来，签名输入=sign 前的明文拼接，
 *       输出=请求里的 sign 字段，两边一对就还原了。
 */
Java.perform(function () {
    var TAG = "[CRYPTO]";

    function hex(bytes) {
        var s = "";
        for (var i = 0; i < bytes.length; i++) {
            var b = (bytes[i] & 0xff).toString(16);
            s += (b.length === 1 ? "0" : "") + b;
        }
        return s;
    }

    // ---- 1. MessageDigest: MD5 / SHA1 / SHA256 ----
    try {
        var MD = Java.use("java.security.MessageDigest");
        MD.digest.overload().implementation = function () {
            var out = this.digest();
            console.log(TAG + " MD." + this.getAlgorithm() + "() -> " + hex(out));
            return out;
        };
        MD.digest.overload("[B").implementation = function (input) {
            console.log(TAG + " MD." + this.getAlgorithm() + "(" + hex(input) + ")");
            var out = this.digest(input);
            console.log(TAG + "   -> " + hex(out));
            return out;
        };
        MD.update.overload("[B").implementation = function (input) {
            console.log(TAG + " MD.update(" + hex(input) + ")  alg=" + this.getAlgorithm());
            return this.update(input);
        };
        console.log(TAG + " hooked MessageDigest");
    } catch (e) { console.log(TAG + " MD hook failed: " + e); }

    // ---- 2. Mac: HMAC ----
    try {
        var Mac = Java.use("javax.crypto.Mac");
        Mac.doFinal.overload("[B").implementation = function (input) {
            console.log(TAG + " HMAC." + this.getAlgorithm() + "(" + hex(input) + ")");
            var out = this.doFinal(input);
            console.log(TAG + "   -> " + hex(out));
            return out;
        };
        Mac.init.overload("java.security.Key").implementation = function (k) {
            try { console.log(TAG + " HMAC.init key=" + hex(k.getEncoded())); } catch (e) {}
            return this.init(k);
        };
        console.log(TAG + " hooked Mac");
    } catch (e) { console.log(TAG + " Mac hook failed: " + e); }

    // ---- 3. Cipher: AES/DES 加密 ----
    try {
        var Cipher = Java.use("javax.crypto.Cipher");
        Cipher.doFinal.overload("[B").implementation = function (input) {
            console.log(TAG + " Cipher." + this.getAlgorithm() + " in(" + hex(input) + ")");
            var out = this.doFinal(input);
            console.log(TAG + "   -> " + hex(out));
            return out;
        };
        console.log(TAG + " hooked Cipher");
    } catch (e) { console.log(TAG + " Cipher hook failed: " + e); }

    // ---- 4. 常见签名类名兜底 ----
    ["com.leapmotor.*", "*SignUtil*", "*SignHelper*", "*EncryptUtil*", "*CryptoUtil*", "*SecurityUtil*"].forEach(function (pat) {
        Java.enumerateLoadedClasses({
            onMatch: function (name) {
                if (pat.replace(/\*/g, "").length && name.toLowerCase().indexOf(pat.replace(/\*/g, "").toLowerCase()) >= 0) {
                    console.log(TAG + " class: " + name);
                }
            },
            onComplete: function () {}
        });
    });
});
