# 抓包环境搭建（10 分钟）

## 1. PC 端

```bash
pip install mitmproxy
# 启动抓包（默认 8080）
mitmdump -s capture/mitm_capture.py -p 8080
```

启动后 `~/.mitmproxy/mitmproxy-ca-cert.pem` 就是证书。

## 2. 手机端

1. 手机 WiFi → 手动代理 → 主机 `<PC_IP>`，端口 `8080`。
2. 浏览器访问 `http://mitm.it` → 下载并安装证书。
3. **Android 7+ 注意**：用户证书默认不被 APP 信任。两条路：
   - **有 root**：把证书塞进系统证书目录（`/system/etc/security/cacerts/`，注意文件名是 `<hash>.0`）。
   - **没 root**：用 Frida 脚本绕过 pinning（见 `frida/hook_ssl_bypass.js`），或用 `objection` / `apk-mitm` 改包。

## 3. 抓什么

打开零跑 APP，依次操作一遍**全部车控功能**，每个动作都做一次：

- 登录 / 短信验证码 / 刷新 token
- 车辆列表 / 车辆状态（电量、续航、车门、胎压）
- 锁车 / 解锁
- 寻车（闪灯鸣笛）
- 空调 开/关 / 温度 / 风量
- 车窗 开/关
- 后备箱 开
- 充电 开始/停止 / 充电限值
- 远程启动（如果有）

抓完后 `evidence/` 里会有一堆 `flow_*.json`。

## 4. 找签名

重点看每个请求的 `req_sign_headers`。典型形态：

```
sign: a1b2c3...        # 32/40/64 位十六进制 -> MD5/SHA1/SHA256
timestamp: 1728...     # 毫秒时间戳
nonce: 8~32 位随机串
token: eyJ...          # JWT 或自定义
```

把 `sign` 和同请求的 body+headers 一起喂给 `client/leapmotor_client.py` 里的签名复现器验证。

## 5. 抓不到 / 全是乱码？

说明有 SSL Pinning 或国密/自定义加密。上 Frida：

```bash
frida -U -f com.leapmotor.app -l frida/hook_okhttp.js
frida -U -f com.leapmotor.app -l frida/hook_sign.js
```

包名先用 `adb shell pm list packages | grep -i leap` 确认。
