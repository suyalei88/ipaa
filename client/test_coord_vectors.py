#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_coord_vectors.py —— 校验 iOS 端 `API/LMCoordinate.swift` 的坐标换算

为什么需要这个：
    没有 Xcode 的机器上没法编译 Swift，而坐标换算是「一个常量写错就整体偏几百米」
    的纯算法。所以这里做两件事：
      1. 用独立实现算出参考向量，并断言它符合已知的物理事实（偏移量级、往返精度、
         境外不偏移）；
      2. **从 Swift 源文件里读回常量与参考值**，逐位比对 ——
         这样 Swift 侧改坏了常量，CI 立刻红，不用等上真机。

    python client/test_coord_vectors.py

背景（2026-10-07 用户报「车辆定位位置不对」）：
    车机上报的 2190/2191 到底是 WGS-84 还是 GCJ-02 无法从官方二进制静态判定
    （官方 App 里 wgs84ToGcj02: 和 gcj02ToWgs84: 两个方向都实现了）。
    合肥实测点 (31.801201, 117.342718) 两个方向相差 574 米 ——
    正是「偏到隔壁小区」的量级。所以 App 里给了三选一的校正开关。
"""
from __future__ import annotations

import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(
    HERE, "..", "ios", "LeapmotorLite", "LeapmotorLite", "API", "LMCoordinate.swift")

# ============================================================
# 与 LMCoordinate.swift 逐字对应的常量
# ============================================================

A = 6378245.0
EE = 0.00669342162296594323

# 合肥实测点（车机上报的原始 2190/2191）
HEFEI_LAT, HEFEI_LNG = 31.801201, 117.342718
# 参考实现算出的 GCJ-02 值（Swift 自检里也写了同一对数）
EXPECT_GCJ_LAT = 31.79931886581182
EXPECT_GCJ_LNG = 117.34837296266286

results: list[tuple[str, bool, str]] = []


def add(name: str, ok: bool, detail: str) -> None:
    results.append((name, bool(ok), detail))


# ============================================================
# 参考实现
# ============================================================

def out_of_china(lat: float, lng: float) -> bool:
    if lng < 72.004 or lng > 137.8347:
        return True
    if lat < 0.8293 or lat > 55.8271:
        return True
    return False


def _transform_lat(x: float, y: float) -> float:
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * math.pi) + 320.0 * math.sin(y * math.pi / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lng(x: float, y: float) -> float:
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * math.pi) + 20.0 * math.sin(2.0 * x * math.pi)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * math.pi) + 300.0 * math.sin(x / 30.0 * math.pi)) * 2.0 / 3.0
    return ret


def wgs84_to_gcj02(lat: float, lng: float) -> tuple[float, float]:
    if out_of_china(lat, lng):
        return lat, lng
    d_lat = _transform_lat(lng - 105.0, lat - 35.0)
    d_lng = _transform_lng(lng - 105.0, lat - 35.0)
    rad = lat / 180.0 * math.pi
    magic = math.sin(rad)
    magic = 1 - EE * magic * magic
    sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((A * (1 - EE)) / (magic * sqrt_magic) * math.pi)
    d_lng = (d_lng * 180.0) / (A / sqrt_magic * math.cos(rad) * math.pi)
    return lat + d_lat, lng + d_lng


def gcj02_to_wgs84(lat: float, lng: float) -> tuple[float, float]:
    if out_of_china(lat, lng):
        return lat, lng
    w_lat, w_lng = lat, lng
    for _ in range(6):
        g_lat, g_lng = wgs84_to_gcj02(w_lat, w_lng)
        e_lat, e_lng = g_lat - lat, g_lng - lng
        if abs(e_lat) < 1e-9 and abs(e_lng) < 1e-9:
            break
        w_lat -= e_lat
        w_lng -= e_lng
    return w_lat, w_lng


def haversine(p: tuple[float, float], q: tuple[float, float]) -> float:
    """与 CLLocation.distance(from:) 同量级（球面大圆距离），用于量级判定。"""
    r = 6371008.8
    p1, l1 = math.radians(p[0]), math.radians(p[1])
    p2, l2 = math.radians(q[0]), math.radians(q[1])
    h = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin((l2 - l1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(h))


# ============================================================
# 1. 参考向量
# ============================================================

def check_reference() -> None:
    g = wgs84_to_gcj02(HEFEI_LAT, HEFEI_LNG)
    ok = abs(g[0] - EXPECT_GCJ_LAT) < 1e-12 and abs(g[1] - EXPECT_GCJ_LNG) < 1e-12
    add("合肥点 WGS-84 → GCJ-02 等于参考向量", ok,
        f"{g[0]:.14f}, {g[1]:.14f}" if ok else f"得到 {g!r}")

    moved = haversine((HEFEI_LAT, HEFEI_LNG), g)
    add("偏移量级在 500~650 米（国内典型值）", 500 < moved < 650, f"{moved:.1f} 米")

    back = gcj02_to_wgs84(*g)
    res = haversine((HEFEI_LAT, HEFEI_LNG), back)
    add("GCJ-02 → WGS-84 往返残差 < 1 毫米", res < 0.001, f"{res * 1000:.6f} 毫米")

    # 全国几个点：偏移都要落在 200~700 米，且往返都要收敛
    worst = 0.0
    lo, hi = 1e9, 0.0
    for name, la, ln in [("北京国贸", 39.9087, 116.3975), ("上海人民广场", 31.2304, 121.4737),
                         ("深圳市民中心", 22.5460, 114.0580), ("乌鲁木齐", 43.8256, 87.6168),
                         ("漠河", 52.9722, 122.5389), ("三亚", 18.2528, 109.5119)]:
        gg = wgs84_to_gcj02(la, ln)
        d = haversine((la, ln), gg)
        lo, hi = min(lo, d), max(hi, d)
        worst = max(worst, haversine((la, ln), gcj02_to_wgs84(*gg)))
    add("全国 6 点偏移都落在 200~700 米", 200 < lo and hi < 700, f"{lo:.0f} ~ {hi:.0f} 米")
    add("全国 6 点往返残差 < 1 毫米", worst < 0.001, f"最大 {worst * 1000:.6f} 毫米")

    # 境外必须原样返回
    overseas_ok = True
    for la, ln in [(35.6762, 139.6503), (40.7128, -74.0060), (-33.8688, 151.2093)]:
        if wgs84_to_gcj02(la, ln) != (la, ln):
            overseas_ok = False
    add("境外坐标原样返回（不做偏移）", overseas_ok, "东京 / 纽约 / 悉尼")


# ============================================================
# 2. 从 Swift 源文件读回常量与参考值，逐位比对
# ============================================================

def check_swift_source() -> None:
    if not os.path.exists(SWIFT):
        add("读得到 API/LMCoordinate.swift", False, SWIFT)
        return
    add("读得到 API/LMCoordinate.swift", True, os.path.relpath(SWIFT, os.path.join(HERE, "..")))
    src = open(SWIFT, encoding="utf-8").read()

    # 2.1 两个魔数
    ok_a = "6378245.0" in src
    add("Swift 里 GCJ 长半轴 = 6378245.0", ok_a, "命中" if ok_a else "缺失")

    ok_ee = "0.00669342162296594323" in src
    add("Swift 里偏心率平方 = 0.00669342162296594323", ok_ee, "命中" if ok_ee else "缺失")

    # 2.2 境外判定边界
    bounds = ["72.004", "137.8347", "0.8293", "55.8271"]
    ok_b = all(b in src for b in bounds)
    add("Swift 里 outOfChina 的四个边界值完整", ok_b,
        " / ".join(bounds) if ok_b else f"缺少 {[b for b in bounds if b not in src]}")

    # 2.3 参考向量（十进制字面量，允许前后空格差异）
    ok_v = ("31.79931886581182" in src) and ("117.34837296266286" in src)
    add("Swift 自检里写入了同一组参考向量", ok_v,
        f"{EXPECT_GCJ_LAT}, {EXPECT_GCJ_LNG}")

    # 2.4 迭代反解必须真的在迭代（有循环 + 残差提前退出）
    ok_it = bool(re.search(r"for\s+_\s+in\s+0\.\.<6", src)) and "1e-9" in src
    add("Swift 的 GCJ→WGS 用的是迭代反解（6 轮 + 1e-9 提前退出）", ok_it,
        "for _ in 0..<6 / 1e-9")

    # 2.5 三个校正选项都要在，且 .none 不能做换算
    ok_cases = all(k in src for k in ["case none", "case wgs84ToGcj02", "case gcj02ToWgs84"])
    add("三个校正选项齐全（none / wgs84ToGcj02 / gcj02ToWgs84）", ok_cases, "齐全")

    # 2.6 关键：默认值必须是「加偏移」那个方向
    #     用户报「位置不对」时用的就是 .none（等于不换算），默认再给 .none 等于没修。
    m = re.search(r"static let fallback:\s*LMCarCoordFix\s*=\s*\.(\w+)", src)
    got_fallback = m.group(1) if m else None
    add("默认校正方式不是 .none（否则等于没修）", got_fallback == "wgs84ToGcj02",
        f"fallback = .{got_fallback}")

    # 2.7 持久化 key 必须用自己的前缀，别碰官方 App 的 UserDefaults
    m_key = re.search(r'storageKey\s*=\s*"([^"]+)"', src)
    got_key = m_key.group(1) if m_key else None
    add("UserDefaults key 用 lm3rd. 前缀", bool(got_key and got_key.startswith("lm3rd.")),
        got_key or "未找到")


def main() -> int:
    check_reference()
    check_swift_source()

    width = max(len(n) for n, _, _ in results)
    all_ok = True
    for name, ok, detail in results:
        all_ok &= ok
        print(f"[{'OK ' if ok else 'FAIL'}] {name.ljust(width)}  {detail}")

    print(f"\n{sum(1 for _, o, _ in results if o)}/{len(results)} passed"
          f"  {'✅ 与 Swift 实现一致' if all_ok else '❌ 有不一致'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
