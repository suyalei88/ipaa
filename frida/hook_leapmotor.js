/*
 * hook_leapmotor.js — 零跑 APP (com.dahua.leapmotor) 专用
 * ========================================================
 * 目标：
 *   1) 抓出 AIRequestInfoPlugin.getRequestInfo 返回的 headerInfo（含 signKey/token/baseURL/deviceId）
 *   2) dump 所有 OkHttp 请求/响应（拿到真实车控端点 + sign header）
 *   3) hook Java 层 MD5/HMAC/AES，交叉验证签名
 *
 * 用法:
 *   frida -U -f com.dahua.leapmotor -l frida/hook_leapmotor.js --no-pause
 *
 * 注意: 该 APK 是 360 加固(jiagu VIP)，自带反调试/反 Frida。
 *   直接跑可能被检测。建议:
 *     - Magisk + Zygisk + DenyList 隐藏 root
 *     - 改名 frida-server / 用 frida-gadget 重打包
 *     - 或 LSPosed 里用 Xposed 模块绕
 *   先跑 `frida-ps -U` 能列出进程再继续。
 */
Java.perform(function () {
    var TAG = "[LP]";

    function hex(bytes) {
        var s = "";
        for (var i = 0; i < bytes.length; i++) {
            var b = (bytes[i] & 0xff).toString(16);
            s += (b.length === 1 ? "0" : "") + b;
        }
        return s;
    }

    // ============ 1. 挖 RequestInfo（signKey 来源）============
    // 目标是任何返回含 signKey 的 getRequestInfo。做类枚举兜底。
    function hookRequestInfoClasses() {
        var patterns = ["RequestInfo", "CarInfo", "leapcrypto", "LeapCrypto", "SignUtil", "AuthUtil"];
        Java.enumerateLoadedClasses({
            onMatch: function (name) {
                patterns.forEach(function (p) {
                    if (name.indexOf(p) < 0) return;
                    try {
                        var clazz = Java.use(name);
                        var methods = clazz.class.getDeclaredMethods();
                        methods.forEach(function (m) {
                            var mn = m.getName();
                            if (mn.indexOf("getRequestInfo") < 0 && mn.indexOf("RequestInfo") < 0) return;
                            console.log(TAG + " found method: " + name + "." + mn);
                            try {
                                clazz[mn].overload.apply(clazz, m.getParameterTypes().map(function (t) {
                                    return t.getName();
                                })).implementation = function () {
                                    var r = this[mn].apply(this, arguments);
                                    console.log(TAG + " >>> " + name + "." + mn + " -> " + r);
                                    return r;
                                };
                            } catch (e) {}
                        });
                    } catch (e) {}
                });
            },
            onComplete: function () {}
        });
    }
    hookRequestInfoClasses();
    // 稍后类加载完再扫一遍
    setTimeout(hookRequestInfoClasses, 4000);
    setTimeout(hookRequestInfoClasses, 9000);

    // ============ 2. OkHttp 全量 dump ============
    try {
        var RealChain = Java.use("okhttp3.internal.http.RealInterceptorChain");
        RealChain.proceed.overload("okhttp3.Request").implementation = function (req) {
            var url = req.url().toString();
            console.log("\n" + TAG + " HTTP >>> " + req.method() + " " + url);
            var hs = req.headers();
            for (var i = 0; i < hs.size(); i++) {
                var k = hs.name(i), v = hs.value(i);
                console.log(TAG + "   H " + k + ": " + v);
            }
            var body = req.body();
            if (body !== null) {
                try {
                    var Buffer = Java.use("okio.Buffer");
                    var b = Buffer.$new();
                    body.writeTo(b);
                    console.log(TAG + "   BODY: " + b.readUtf8());
                } catch (e) {}
            }
            var resp = this.proceed(req);
            try {
                var peek = resp.peekBody(2 * 1024 * 1024);
                console.log(TAG + " HTTP <<< " + resp.code() + " " + peek.string());
            } catch (e) {}
            return resp;
        };
        console.log(TAG + " hooked OkHttp RealInterceptorChain");
    } catch (e) { console.log(TAG + " okhttp hook failed: " + e); }

    // ============ 3. Java 加密层交叉验证 ============
    try {
        var MD = Java.use("java.security.MessageDigest");
        MD.digest.overload("[B").implementation = function (input) {
            var out = this.digest(input);
            console.log(TAG + " MD." + this.getAlgorithm() + "(" + hex(input) + ") -> " + hex(out));
            return out;
        };
        console.log(TAG + " hooked MessageDigest");
    } catch (e) {}

    try {
        var Mac = Java.use("javax.crypto.Mac");
        Mac.doFinal.overload("[B").implementation = function (input) {
            var out = this.doFinal(input);
            console.log(TAG + " HMAC." + this.getAlgorithm() + "(" + hex(input) + ") -> " + hex(out));
            return out;
        };
        Mac.init.overload("java.security.Key").implementation = function (k) {
            try { console.log(TAG + " HMAC key=" + hex(k.getEncoded())); } catch (e) {}
            return this.init(k);
        };
        console.log(TAG + " hooked Mac");
    } catch (e) {}

    try {
        var Cipher = Java.use("javax.crypto.Cipher");
        Cipher.doFinal.overload("[B").implementation = function (input) {
            var out = this.doFinal(input);
            console.log(TAG + " Cipher." + this.getAlgorithm() + " in=" + hex(input) + " out=" + hex(out));
            return out;
        };
        console.log(TAG + " hooked Cipher");
    } catch (e) {}

    console.log(TAG + " hooks installed");
});
