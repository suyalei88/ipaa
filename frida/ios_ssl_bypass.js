/*
 * ios_ssl_bypass.js — iOS 端 SSL Pinning 全面绕过
 * ================================================
 * 目标 APP: 零跑 (leapmotorCarOwner)
 * 用法（越狱机 + frida）:
 *   frida -U -f <bundleId> -l frida/ios_ssl_bypass.js --no-pause
 *   或对已运行进程: frida -U -n Leapmotor -l frida/ios_ssl_bypass.js
 *
 * 覆盖:
 *   1) Security.framework  SecTrustEvaluate / SecTrustEvaluateWithError
 *   2) BoringSSL           SSL_set_verify / SSL_CTX_set_custom_verify
 *   3) OpenSSL             SSL_CTX_set_verify / SSL_get_verify_result
 *   4) NSURLSession        didReceiveChallenge 回调
 *   5) CFNetwork           tls_helper_create_peer_trust
 *   6) 常见第三方 pinning 库 (TrustKit / AFNetworking)
 */

var TAG = "[iOS-SSL]";

function log(m) { console.log(TAG + " " + m); }

// ---------- 1. Security.framework ----------
try {
    var Security = Module.load("Security");
    ["SecTrustEvaluate", "SecTrustEvaluateWithError"].forEach(function (fn) {
        var p = Module.findExportByName("Security", fn);
        if (!p) return;
        Interceptor.replace(p, new NativeCallback(function () {
            log("bypass " + fn);
            // 返回 errSecSuccess(0) / true
            return fn === "SecTrustEvaluateWithError" ? 1 : 0;
        }, "int", []));
        log("hooked " + fn);
    });
} catch (e) { log("Security hook failed: " + e); }

// ---------- 2. BoringSSL / OpenSSL ----------
["SSL_set_verify", "SSL_CTX_set_verify"].forEach(function (name) {
    try {
        var p = Module.findExportByName(null, name);
        if (!p) { log("not found: " + name); return; }
        Interceptor.replace(p, new NativeCallback(function (ctx, mode, cb) {
            log("bypass " + name);
            // 不调用原函数 = 不做验证
        }, "void", ["pointer", "int", "pointer"]));
        log("hooked " + name);
    } catch (e) { log(name + " failed: " + e); }
});

// BoringSSL 自定义校验（iOS 15+ 常见）
try {
    var p = Module.findExportByName(null, "SSL_CTX_set_custom_verify");
    if (p) {
        Interceptor.replace(p, new NativeCallback(function () {}, "void",
            ["pointer", "int", "pointer"]));
        log("hooked SSL_CTX_set_custom_verify");
    }
} catch (e) {}

// OpenSSL 校验结果
try {
    var p = Module.findExportByName(null, "SSL_get_verify_result");
    if (p) {
        Interceptor.replace(p, new NativeCallback(function () { return 0; },
            "long", ["pointer"]));
        log("hooked SSL_get_verify_result");
    }
} catch (e) {}

// ---------- 3. CFNetwork ----------
try {
    var p = Module.findExportByName(null, "tls_helper_create_peer_trust");
    if (p) {
        Interceptor.replace(p, new NativeCallback(function () { return 0; },
            "int", ["pointer", "bool", "pointer"]));
        log("hooked tls_helper_create_peer_trust");
    }
} catch (e) {}

// ---------- 4. NSURLSession 挑战回调 ----------
if (ObjC.available) {
    try {
        var NSURLSession = ObjC.classes.NSURLSession;
        var method = "- URLSession:didReceiveChallenge:completionHandler:";
        var impl = NSURLSession.class().instanceMethodForSelector_(
            ObjC.selector(method));
        Interceptor.attach(impl, {
            onEnter: function (args) {
                log("NSURLSession didReceiveChallenge -> bypass");
                // 直接回调 serverTrust + useCredential
                var challenge = new ObjC.Object(args[3]);
                var completion = args[4];
                var trust = challenge.protectionSpace().serverTrust();
                var cred = ObjC.classes.NSURLCredential
                    .credentialForTrust_(trust);
                var block = new ObjC.Block(completion);
                block.implementation(0 /* useCredential */, cred);
            }
        });
        log("hooked NSURLSession challenge");
    } catch (e) { log("NSURLSession hook failed: " + e); }

    // ---------- 5. TrustKit / AFNetworking ----------
    ["TSKPinningValidator", "AFSecurityPolicy", "TrustKit"].forEach(function (cn) {
        if (ObjC.classes[cn]) log("found pinning class: " + cn + " (可能需要额外处理)");
    });
}

log("installed. 现在配合 mitmproxy 抓包。");
