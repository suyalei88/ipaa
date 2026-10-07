/*
 * hook_okhttp.js — dump 零跑 APP 全部 HTTP 请求/响应
 * 用法:
 *   frida -U -f com.leapmotor.app -l frida/hook_okhttp.js --no-pause
 *
 * 覆盖 OkHttp3 / HttpURLConnection，抓 method / url / headers / body。
 * 需要先确认包名: adb shell pm list packages | grep -i leap
 */
Java.perform(function () {
    var TAG = "[OKHTTP]";

    function bytesToString(buf) {
        if (buf === null) return "null";
        try {
            var JString = Java.use("java.lang.String");
            return JString.$new(buf);
        } catch (e) {
            return "<bytes:" + buf + ">";
        }
    }

    // ---- OkHttp3 拦截器层：最干净 ----
    try {
        var Interceptor = Java.use("okhttp3.Interceptor");
        var RealInterceptorChain = Java.use("okhttp3.internal.http.RealInterceptorChain");
        // 直接 hook 链的 proceed，拿到 Request
        RealInterceptorChain.proceed.overload("okhttp3.Request").implementation = function (req) {
            console.log("\n" + TAG + " >>> " + req.method() + " " + req.url().toString());
            var hs = req.headers();
            for (var i = 0; i < hs.size(); i++) {
                console.log(TAG + "   H " + hs.name(i) + ": " + hs.value(i));
            }
            var body = req.body();
            if (body !== null) {
                try {
                    var Buffer = Java.use("okio.Buffer");
                    var b = Buffer.$new();
                    body.writeTo(b);
                    console.log(TAG + "   BODY: " + b.readUtf8());
                } catch (e) {
                    console.log(TAG + "   BODY: <unreadable>");
                }
            }
            var resp = this.proceed(req);
            try {
                var peek = resp.peekBody(1024 * 1024);
                console.log(TAG + " <<< " + resp.code() + " " + peek.string());
            } catch (e) {}
            return resp;
        };
        console.log(TAG + " hooked RealInterceptorChain.proceed");
    } catch (e) {
        console.log(TAG + " okhttp chain hook failed: " + e);
    }

    // ---- Request.Builder 兜底 ----
    try {
        var Builder = Java.use("okhttp3.Request$Builder");
        Builder.addHeader.implementation = function (k, v) {
            console.log(TAG + "   +H " + k + ": " + v);
            return this.addHeader(k, v);
        };
        Builder.header.implementation = function (k, v) {
            console.log(TAG + "   =H " + k + ": " + v);
            return this.header(k, v);
        };
        console.log(TAG + " hooked Request$Builder headers");
    } catch (e) {
        console.log(TAG + " builder hook failed: " + e);
    }
});
