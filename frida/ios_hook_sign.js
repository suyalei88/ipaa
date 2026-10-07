/*
 * ios_hook_sign.js —— 零跑 iOS 签名密钥 / 明文 / 结果 三件套 dump
 * ==========================================================================
 * 目标：拿到 signKey（HMAC 密钥）。算法已 100% 还原，只缺这一把 key。
 *
 * 用法：
 *   frida -U -f com.leapmotor.developer -l frida/ios_hook_sign.js --no-pause
 *   # 然后在 App 里点一次「刷新车况」或任意车控按钮
 *
 * 四路取证（互为兜底，哪路先出用哪路）：
 *   [A] 原生签名方法：signStringWithParams:signatureParams:serverKey:
 *       -> 直接打印 serverKey（最优）
 *   [B] CommonCrypto CCHmac / CCHmacInit / CCHmacUpdate
 *       -> 打印 key + data + 32B 结果（最可靠，加固也拦不住）
 *   [C] NSURLSession / NSURLConnection -> 打印请求头里的 sign + URL + body
 *       -> 用于把 (message, sign) 配对
 *   [D] RN bridge: AIRequestInfoPlugin.getRequestInfo -> 打印 signKey 字段
 *
 * 拿到 serverKey 后：
 *   把 hex/base64 值填进 app/config.json 的 "sign_key"，算法立刻闭环。
 */

var TAG = "[LP-SIGN]";
function log(m) { console.log(TAG + " " + m); }

function hex(buf, max) {
    if (!buf) return "null";
    try {
        var u = new Uint8Array(buf.slice(0, max || 256));
        var s = "";
        for (var i = 0; i < u.length; i++) {
            var b = u[i].toString(16);
            s += (b.length === 1 ? "0" : "") + b;
        }
        return s;
    } catch (e) { return "<err " + e + ">"; }
}
function b64(buf) {
    try { return btoa(String.fromCharCode.apply(null, new Uint8Array(buf))); }
    catch (e) { return "<err>"; }
}
function s(o) {
    try { return o === null ? "null" : String(o); } catch (e) { return "<err>"; }
}

/* ------------------------------------------------------------------ */
/* [A] 原生签名方法                                                     */
/* ------------------------------------------------------------------ */
var SELECTORS = [
    "signStringWithParams:signatureParams:serverKey:",
    "signatureForGroupProWithParameters:path:signKey:",
    "sign:withToken:",
    "signParamsWithPassword:",
    "signSM2WithData:priKey:signString:",
    "signWithAppID:data:option:",
    "signatureWithKey:data:",
    "signatureWithKey:",
    "signvalueWithData:",
    "hmacSHA256StringWithKey:",
    "hmacSHA256DataWithKey:",
];

function hookSelector(sel) {
    var hit = 0;
    try {
        ObjC.enumerateLoadedClassesSync().forEach(function (name) {
            var cls = ObjC.classes[name];
            if (!cls || !cls[sel]) return;
            try {
                Interceptor.attach(cls[sel].implementation, {
                    onEnter: function (args) {
                        this.n = sel.split(":").filter(Boolean).length;
                        log("=== " + name + " -[" + sel + "] ===");
                        for (var i = 0; i < this.n; i++) {
                            try {
                                var o = new ObjC.Object(args[2 + i]);
                                var cn = o.$className || "";
                                log("   arg[" + i + "] <" + cn + "> = " + s(o));
                                if (cn.indexOf("Data") >= 0) {
                                    var len = o.length();
                                    log("        bytes(" + len + ") = " +
                                        hex(o.bytes(), Math.min(len, 128)) +
                                        "   b64 = " + b64(o.bytes()));
                                }
                            } catch (e) { log("   arg[" + i + "] = " + args[2 + i]); }
                        }
                    },
                    onLeave: function (ret) {
                        try { log("   >>> return = " + s(new ObjC.Object(ret))); }
                        catch (e) { log("   >>> return = " + ret); }
                    }
                });
                hit++;
            } catch (e) {}
        });
    } catch (e) { log("enum failed: " + e); }
    if (hit) log("[A] hooked " + sel + "  (" + hit + " class)");
}
SELECTORS.forEach(hookSelector);

/* 加固下 enumerateLoadedClasses 可能拿不到，用 dlopen 后的 class_getName 兜底扫描 */
function hookSelectorViaRuntime(sel) {
    try {
        var objc_getClassList = Module.findExportByName(null, "objc_getClassList");
        var class_getName = Module.findExportByName(null, "class_getName");
        var class_getInstanceMethod = Module.findExportByName(null, "class_getInstanceMethod");
        var class_getClassMethod = Module.findExportByName(null, "class_getClassMethod");
        var method_getImplementation = Module.findExportByName(null, "method_getImplementation");
        if (!objc_getClassList || !class_getInstanceMethod) return;
        var getClassList = new NativeFunction(objc_getClassList, "int", ["pointer", "int"]);
        var n = getClassList(ptr(0), 0);
        if (n <= 0 || n > 200000) return;
        var arr = Memory.alloc(n * Process.pointerSize);
        n = getClassList(arr, n);
        var getInst = new NativeFunction(class_getInstanceMethod, "pointer", ["pointer", "pointer"]);
        var getImpl = new NativeFunction(method_getImplementation, "pointer", ["pointer"]);
        var selPtr = Memory.allocUtf8String(sel);
        var found = 0;
        for (var i = 0; i < n; i++) {
            var cls = arr.add(i * Process.pointerSize).readPointer();
            var m = getInst(cls, selPtr);
            if (m.isNull()) continue;
            var imp = getImpl(m);
            if (imp.isNull()) continue;
            Interceptor.attach(imp, {
                onEnter: function (args) {
                    log("[A2] " + sel + " arg1=" + s(new ObjC.Object(args[2])) +
                        " arg2=" + s(new ObjC.Object(args[3])) +
                        " arg3=" + s(new ObjC.Object(args[4])));
                },
                onLeave: function (ret) {
                    try { log("[A2] >>> " + s(new ObjC.Object(ret))); } catch (e) {}
                }
            });
            found++;
        }
        if (found) log("[A2] runtime-hooked " + sel + " x" + found);
    } catch (e) { log("[A2] err " + e); }
}
SELECTORS.forEach(hookSelectorViaRuntime);

/* ------------------------------------------------------------------ */
/* [B] CommonCrypto —— 最可靠的兜底                                     */
/* ------------------------------------------------------------------ */
function hookCC(name, keyIdx, dataIdx, dataLenIdx, outIdx) {
    var p = Module.findExportByName(null, name);
    if (!p) { log("[B] " + name + " not found"); return; }
    log("[B] hooking " + name);
    Interceptor.attach(p, {
        onEnter: function (args) {
            try {
                var k = args[keyIdx], klen = args[2].toInt32();
                var d = args[dataIdx], dlen = args[dataLenIdx].toInt32();
                this.out = args[outIdx];
                log("[B] " + name + " key(" + klen + ")=" + hex(k, Math.min(klen, 128)) +
                    "  data(" + dlen + ")=" + hex(d, Math.min(dlen, 512)));
                try { log("[B]     data-ascii = " + Memory.readUtf8String(d, Math.min(dlen, 512))); } catch (e) {}
            } catch (e) { log("[B] " + name + " onEnter err " + e); }
        },
        onLeave: function () {
            try { log("[B]   -> " + hex(this.out, 32)); } catch (e) {}
        }
    });
}
/* CCHmac(algorithm, key, keyLength, data, dataLength, out) */
hookCC("CCHmac", 1, 3, 4, 5);

/* CC_SHA256 / CC_MD5 也顺带看一眼（有的实现先 hash 再 hmac） */
["CC_SHA256", "CC_MD5"].forEach(function (fn) {
    var p = Module.findExportByName(null, fn);
    if (!p) return;
    Interceptor.attach(p, {
        onEnter: function (args) {
            try {
                var len = args[1].toInt32();
                log("[B] " + fn + " data(" + len + ")=" + hex(args[0], Math.min(len, 256)));
            } catch (e) {}
        }
    });
});

/* ------------------------------------------------------------------ */
/* [C] 网络层 —— 配对 (message, sign)                                   */
/* ------------------------------------------------------------------ */
function hookRequestClass(clsName) {
    var cls = ObjC.classes[clsName];
    if (!cls) return;
    ["- resume", "- setValue:forHTTPHeaderField:", "- setAllHTTPHeaderFields:"].forEach(function (sel) {
        if (!cls[sel]) return;
        try {
            Interceptor.attach(cls[sel].implementation, {
                onEnter: function (args) {
                    try {
                        var o = new ObjC.Object(args[0]);
                        if (sel.indexOf("HeaderFields") >= 0) {
                            log("[C] " + clsName + " headers = " + s(new ObjC.Object(args[2])));
                        } else if (sel.indexOf("forHTTPHeaderField") >= 0) {
                            log("[C] " + clsName + " hdr " + s(new ObjC.Object(args[2])) +
                                " = " + s(new ObjC.Object(args[3])));
                        } else {
                            log("[C] " + clsName + " resume url = " +
                                s(o.valueForKey_("URL")));
                        }
                    } catch (e) {}
                }
            });
        } catch (e) {}
    });
}
["NSURLSessionTask", "NSMutableURLRequest", "NSURLRequest"].forEach(hookRequestClass);

/* ------------------------------------------------------------------ */
/* [D] RN bridge —— AIRequestInfoPlugin.getRequestInfo                  */
/* ------------------------------------------------------------------ */
(function () {
    var cls = ObjC.classes["AIRequestInfoPlugin"];
    if (!cls) { log("[D] AIRequestInfoPlugin 未注册（可能加固延迟加载）"); return; }
    var sel = "getRequestInfo:tokenErrorCode:resolve:reject:";
    if (!cls[sel]) { log("[D] 方法名不匹配，现有方法见日志"); return; }
    try {
        Interceptor.attach(cls[sel].implementation, {
            onEnter: function (args) {
                this.resolve = args[4];
                log("[D] getRequestInfo tokenErrorCode=" + args[3].toInt32());
            },
            onLeave: function () {
                try {
                    var d = new ObjC.Object(this.resolve);
                    log("[D] resolve(dict) = " + s(d));
                    var k = d.objectForKey_("signKey");
                    if (k && !k.isNull()) {
                        log("[D] ★★★ signKey = " + s(k));
                        if (k.$className && k.$className.indexOf("Data") >= 0) {
                            log("[D] ★★★ signKey(hex) = " + hex(k.bytes(), k.length()) +
                                "  b64 = " + b64(k.bytes()));
                        }
                    }
                } catch (e) { log("[D] resolve err " + e); }
            }
        });
        log("[D] hooked AIRequestInfoPlugin.getRequestInfo");
    } catch (e) { log("[D] err " + e); }
})();

log("installed. 现在去 App 里点一下【刷新车况】或任意【车控】按钮。");
log("优先看 [A]/[D] 的 serverKey/signKey；没有就看 [B] CCHmac 的 key。");
