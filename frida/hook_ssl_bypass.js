/*
 * hook_ssl_bypass.js — 绕过 SSL Pinning（抓包抓不到时用）
 * 用法: frida -U -f com.leapmotor.app -l frida/hook_ssl_bypass.js --no-pause
 */
Java.perform(function () {
    var TAG = "[SSL]";

    // OkHttp3 CertificatePinner
    try {
        var CertificatePinner = Java.use("okhttp3.CertificatePinner");
        CertificatePinner.check.overload("java.lang.String", "java.util.List").implementation = function (h, l) {
            console.log(TAG + " bypass CertificatePinner: " + h);
            return;
        };
    } catch (e) {}

    // TrustManager 全放行
    try {
        var X509TrustManager = Java.use("javax.net.ssl.X509TrustManager");
        var TrustManager = Java.registerClass({
            name: "com.frida.TrustAll",
            implements: [X509TrustManager],
            methods: {
                checkClientTrusted: function () {},
                checkServerTrusted: function () {},
                getAcceptedIssuers: function () { return []; }
            }
        });
        var SSLContext = Java.use("javax.net.ssl.SSLContext");
        var ctx = SSLContext.getInstance("TLS");
        ctx.init(null, [TrustManager.$new()], null);
        var SSLContextImpl = Java.use("javax.net.ssl.SSLContext");
        SSLContextImpl.getDefault.implementation = function () { return ctx; };
        console.log(TAG + " TrustManager hooked");
    } catch (e) {}

    // HostnameVerifier
    try {
        var OkHostnameVerifier = Java.use("okhttp3.internal.tls.OkHostnameVerifier");
        OkHostnameVerifier.verify.overload("java.lang.String", "javax.net.ssl.SSLSession").implementation = function () {
            return true;
        };
    } catch (e) {}

    console.log(TAG + " done");
});
