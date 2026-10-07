// verify_sign.js — 用 Node 复现 bundle 里的原始 JS 签名逻辑，与 Python 实现比对
// 用法: node verify_sign.js
const crypto = require('crypto');

// ===== 从 index.android.bundle 逐字提取并还原的逻辑 =====
function formatSignValue(value) {
    if (Array.isArray(value)) {
        var hasObject = value.some(function (item) { return typeof item === "object" && item !== null; });
        if (!hasObject) { return value.toString(); }
        return value.map(function (obj) {
            if (typeof obj !== "object" || obj === null) { return String(obj); }
            var entries = Object.entries(obj)
                .filter(function (_ref11) { var v = _ref11[1]; return v != null && v !== undefined && v !== ""; })
                .map(function (_ref13) { var k = _ref13[0], v = _ref13[1]; return `${k}=${v}`; })
                .join(", ");
            return `{${entries}}`;
        }).join(",");
    }
    return String(value);
}

function buildSignValueString(body, signHeaders) {
    var signObj = {};
    Object.entries(body).forEach(function (_ref) { var k = _ref[0], v = _ref[1]; signObj[k] = v; });
    Object.entries(signHeaders).forEach(function (_ref3) { var k = _ref3[0], v = _ref3[1]; signObj[k] = v; });
    return Object.entries(signObj)
        .filter(function (_ref5) { var v = _ref5[1]; return v != null && v !== undefined && v !== ""; })
        .sort(function (_ref7, _ref8) {
            var keyA = _ref7[0], keyB = _ref8[0];
            if (keyA < keyB) return -1; if (keyA > keyB) return 1; return 0;
        })
        .map(function (_ref1) { var v = _ref1[1]; return formatSignValue(v); })
        .join("");
}

function parseKeyString(keyString) {
    var cleaned = keyString.replace(/[^0-9A-Fa-f]/g, "");
    var isLikelyHex = cleaned.length > 0 && cleaned.length === keyString.replace(/\s/g, "").length;
    if (isLikelyHex) { return Buffer.from(cleaned, "hex"); }
    return Buffer.from(keyString, "utf-8");
}

function generateHmacSha256(message, keyInput) {
    if (!message || !keyInput) return null;
    var key = parseKeyString(keyInput);
    return crypto.createHmac("sha256", key).update(message, "utf-8").digest("hex");
}

// ===== 测试向量（与 python client 自测一致）=====
const body = { vin: "TESTVIN0000000000", action: "lock" };
const sh = {
    acceptLanguage: "zh-CN", deviceType: "android", source: "app",
    version: "1.0.0", channel: "official", deviceId: "abc123",
    timestamp: "1728000000000", nonce: "123456",
};
const vs = buildSignValueString(body, sh);
console.log("JS valueStr =", vs);
console.log("JS sign     =", generateHmacSha256(vs, "0123456789abcdef0123456789abcdef"));

// 额外向量：数组/布尔/数字
const body2 = { a: [1, 2, 3], b: true, c: 0, d: "", e: null, f: [{ x: 1, y: "" }, { x: 2 }] };
const sh2 = { timestamp: "1", nonce: "2" };
console.log("JS valueStr2=", buildSignValueString(body2, sh2));
