/*
 * ios_hook_request.js — iOS 端 dump 请求/响应 + 抓签名（mitmproxy 兜底）
 * =====================================================================
 * 用法:
 *   frida -U -f <bundleId> -l frida/ios_hook_request.js --no-pause
 *
 * 覆盖:
 *   - NSURLSession / NSURLConnection 请求+响应
 *   - CommonCrypto (CCHmac / CCCrypt / CC_MD5 / CC_SHA256) 交叉验证签名
 *   - 如果 iOS 端也是 React Native，顺带 hook AIRequestInfoPlugin
 */
var TAG = "[iOS-REQ]";
function log(m) { console.log(TAG + " " + m); }

if (ObjC.available) {
    // ---------- 请求头 ----------
    try {
        var NSMutableURLRequest = ObjC.classes.NSMutableURLRequest;
        Interceptor.attach(
            NSMutableURLRequest["- setValue:forHTTPHeaderField:"].implementation,
            {
                onEnter: function (args) {
                    try {
                        var v = new ObjC.Object(args[2]).toString();
                        var f = new ObjC.Object(args[3]).toString();
                        log("H " + f + ": " + v);
                    } catch (e) {}
                }
            });
        log("hooked setValue:forHTTPHeaderField:");
    } catch (e) { log("header hook failed: " + e); }

    // ---------- 请求体 + URL ----------
    function hookTask(sel) {
        try {
            var m = ObjC.classes.NSURLSession[sel];
            if (!m) return;
            Interceptor.attach(m.implementation, {
                onEnter: function (args) {
                    try {
                        var req = new ObjC.Object(args[2]);
                        var url = req.URL().absoluteString().toString();
                        var method = req.HTTPMethod().toString();
                        log(">>> " + method + " " + url);
                        var body = req.HTTPBody();
                        if (body && !body.isNull()) {
                            var data = new ObjC.Object(body);
                            var s = ObjC.classes.NSString.alloc()
                                .initWithData_encoding_(data, 4);
                            if (s) log("    BODY: " + s.toString());
                        }
                        var hs = req.allHTTPHeaderFields();
                        if (hs && !hs.isNull()) log("    HEADERS: " + hs.toString());
                    } catch (e) {}
                }
            });
            log("hooked " + sel);
        } catch (e) { log(sel + " failed: " + e); }
    }
    hookTask("- dataTaskWithRequest:");
    hookTask("- dataTaskWithRequest:completionHandler:");
    hookTask("- uploadTaskWithRequest:fromData:");

    // ---------- 响应 ----------
    try {
        var NSHTTPURLResponse = ObjC.classes.NSHTTPURLResponse;
        log("hint: 响应体建议直接看 mitmproxy，更全");
    } catch (e) {}
}

// ---------- CommonCrypto 签名交叉验证 ----------
["CCHmac", "CCCrypt", "CC_MD5", "CC_SHA256", "CC_SHA1"].forEach(function (fn) {
    try {
        var p = Module.findExportByName(null, fn);
        if (!p) return;
        log("found " + fn + " @ " + p);
        if (fn === "CCHmac") {
            Interceptor.attach(p, {
                onEnter: function (args) {
                    try {
                        this.outPtr = args[5];
                        var algo = args[0].toInt32();
                        var keyLen = args[2].toInt32();
                        var key = Memory.readByteArray(args[1], keyLen);
                        var dataLen = args[4].toInt32();
                        var data = Memory.readByteArray(args[3], Math.min(dataLen, 256));
                        log("CCHmac algo=" + algo + " key=" + hex(key) + " data=" + hex(data));
                    } catch (e) {}
                },
                onLeave: function (retval) {
                    try {
                        var out = Memory.readByteArray(this.outPtr, 32);
                        log("  CCHmac -> " + hex(out));
                    } catch (e) {}
                }
            });
        }
    } catch (e) {}
});

function hex(buf) {
    if (!buf) return "null";
    var u = new Uint8Array(buf);
    var s = "";
    for (var i = 0; i < u.length; i++) {
        var b = u[i].toString(16);
        s += (b.length === 1 ? "0" : "") + b;
    }
    return s;
}

// ---------- 如果 iOS 也是 RN ----------
if (ObjC.available) {
    try {
        var cls = ObjC.classes.AIRequestInfoPlugin;
        if (cls) log("检测到 AIRequestInfoPlugin (RN) — 用 frida/hook_leapmotor.js 抓 signKey");
    } catch (e) {}
}

log("installed.");
