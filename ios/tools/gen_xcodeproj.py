#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_xcodeproj.py —— 纯 Python 生成 `LeapmotorLite.xcodeproj`

为什么不用 XcodeGen：
    XcodeGen 要 `brew install`，而 GitHub Actions / 别人的 Mac 上不一定有。
    这个脚本只用标准库，Mac 自带 Python 3，零依赖。

产物：
    ios/LeapmotorLite/LeapmotorLite.xcodeproj/project.pbxproj
    ios/LeapmotorLite/LeapmotorLite.xcodeproj/xcshareddata/xcschemes/LeapmotorLite.xcscheme

用法：
    python ios/tools/gen_xcodeproj.py            # 生成
    python ios/tools/gen_xcodeproj.py --check    # 只做一致性自检
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS_DIR = os.path.normpath(os.path.join(HERE, ".."))
PROJ_DIR = os.path.join(IOS_DIR, "LeapmotorLite")           # 含 project.yml / README
SRC_DIR = os.path.join(PROJ_DIR, "LeapmotorLite")           # 含 .swift / Info.plist
XCODEPROJ = os.path.join(PROJ_DIR, "LeapmotorLite.xcodeproj")

TARGET_NAME = "LeapmotorLite"
BUNDLE_ID = "com.example.leapmotorlite"
MARKETING_VERSION = "1.0.0"
BUILD_NUMBER = "1"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.9"

# 这些目录名排在最前（只是美观，不影响构建）
# ★ 2026-10-09：`Views`（SwiftUI 页面）已在 UIKit 迁移 Phase 3~6 中整体删除。
DIR_ORDER = ["Crypto", "API", "BLE", "Store", "UIKit", "Support", "Car3D"]

# ★ 整目录资源：这些目录按 Xcode 的「蓝色文件夹引用」（lastKnownFileType = folder）
#   原样拷进 .app 根目录，**不递归展开**成 PBXGroup。
#   必须这样做的原因：3D 车模包里有 .fbx/.js/.csv/.png 等几十个文件，
#   逐个建 PBXFileReference 既没必要，而且 .js/.fbx 会被当成源码文件误处理；
#   folder 引用保证 bundle 内相对路径与官方 H5 里写死的 './D19_2026/xxx.fbx' 完全一致。
RESOURCE_DIRS = ["Car3D"]


def uid(key: str) -> str:
    """确定性的 24 位大写 hex UUID（Xcode 只要求唯一 + 24 hex）。"""
    return hashlib.md5(("lm:" + key).encode()).hexdigest()[:24].upper()


def quote(s: str) -> str:
    """OpenStep plist 字符串：需要时加引号。"""
    if s == "":
        return '""'
    if re.fullmatch(r"[A-Za-z0-9_./$()@-]+", s):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ============================================================
# 收集文件
# ============================================================

class Node:
    __slots__ = ("name", "rel", "is_dir", "children", "kind")

    def __init__(self, name, rel, is_dir):
        self.name = name
        # ★★ rel 必须用 '/' 作分隔符，跟操作系统无关。
        #    因为 uid('fr/' + rel) 是拿 rel 做 md5 的：如果 Windows 上拼成
        #    'Views\Theme.swift'、Linux 上拼成 'Views/Theme.swift'，
        #    同一个文件在两端会算出两个完全不同的 UUID，
        #    CI 的 `--check` 字节比对就会误报「工程文件和源码不一致」。
        #    （这个坑真踩过：本地绿、CI 红，日志里源文件数还是 17 == 17。）
        assert "\\" not in rel, f"rel 不能含反斜杠: {rel!r}"
        self.rel = rel
        self.is_dir = is_dir
        self.children: list[Node] = []
        self.kind = ""


def scan(root: str, rel: str = "") -> list[Node]:
    out: list[Node] = []
    # ★ rel 里的分隔符一律用 '/'，不要用 os.path.join —— 见下面 Node.rel 的注释。
    #   但拼文件系统路径时要按当前平台的 sep 还原，否则 Windows 上 mixed sep 也能跑，
    #   只是不干净。
    base = os.path.join(root, *rel.split("/")) if rel else root
    for name in sorted(os.listdir(base)):
        if name.startswith("."):
            continue
        full = os.path.join(base, name)
        r = f"{rel}/{name}" if rel else name
        if os.path.isdir(full):
            if name.endswith(".xcassets"):
                n = Node(name, r, False)
                n.kind = "assetcatalog"
                out.append(n)
                continue
            if name in RESOURCE_DIRS:
                # 整目录 folder 引用，见 RESOURCE_DIRS 的注释
                n = Node(name, r, False)
                n.kind = "folder"
                out.append(n)
                continue
            n = Node(name, r, True)
            n.children = scan(root, r)
            out.append(n)
        elif name.endswith(".swift"):
            n = Node(name, r, False)
            n.kind = "swift"
            out.append(n)
        elif name.endswith(".plist"):
            # 只在 Xcode 导航器里显示，不参与任何 build phase
            n = Node(name, r, False)
            n.kind = "plist"
            out.append(n)
    # 目录排序
    def sort_key(n: Node):
        if n.is_dir:
            try:
                return (0, DIR_ORDER.index(n.name), n.name)
            except ValueError:
                return (0, len(DIR_ORDER), n.name)
        return (1, 0, n.name)
    out.sort(key=sort_key)
    return out


def walk(nodes: list[Node]):
    for n in nodes:
        yield n
        if n.is_dir:
            yield from walk(n.children)


# ============================================================
# pbxproj
# ============================================================

def build_pbxproj() -> str:
    tree = scan(SRC_DIR)
    flat = list(walk(tree))

    swift = [n for n in flat if n.kind == "swift"]
    assets = [n for n in flat if n.kind == "assetcatalog"]
    folders = [n for n in flat if n.kind == "folder"]
    plists = [n for n in flat if n.kind == "plist"]
    dirs = [n for n in flat if n.is_dir]

    if not swift:
        raise SystemExit(f"没找到 .swift 文件，检查 {SRC_DIR}")

    U_APP = uid("product/app")
    U_MAINGROUP = uid("group/root")
    U_PRODUCTS = uid("group/Products")
    U_SRCDIR = uid("group/srcroot")
    U_TARGET = uid("target/app")
    U_PROJECT = uid("project")
    U_SRC_PHASE = uid("phase/sources")
    U_FW_PHASE = uid("phase/frameworks")
    U_RES_PHASE = uid("phase/resources")
    U_PROJ_CONF = uid("conf/project")
    U_TGT_CONF = uid("conf/target")
    U_CONF_DEBUG = uid("conf/debug")
    U_CONF_RELEASE = uid("conf/release")
    U_TGT_DEBUG = uid("conf/target/debug")
    U_TGT_RELEASE = uid("conf/target/release")

    L: list[str] = []
    A = L.append

    A("// !$*UTF8*$!")
    A("{")
    A("\tarchiveVersion = 1;")
    A("\tclasses = {")
    A("\t};")
    A("\tobjectVersion = 56;")
    A("\tobjects = {")
    A("")

    # ---------- PBXBuildFile ----------
    A("/* Begin PBXBuildFile section */")
    for n in swift:
        A(f"\t\t{uid('bf/' + n.rel)} /* {n.name} in Sources */ = {{isa = PBXBuildFile; "
          f"fileRef = {uid('fr/' + n.rel)} /* {n.name} */; }};")
    for n in assets:
        A(f"\t\t{uid('bf/' + n.rel)} /* {n.name} in Resources */ = {{isa = PBXBuildFile; "
          f"fileRef = {uid('fr/' + n.rel)} /* {n.name} */; }};")
    for n in folders:
        A(f"\t\t{uid('bf/' + n.rel)} /* {n.name} in Resources */ = {{isa = PBXBuildFile; "
          f"fileRef = {uid('fr/' + n.rel)} /* {n.name} */; }};")
    A("/* End PBXBuildFile section */")
    A("")

    # ---------- PBXFileReference ----------
    A("/* Begin PBXFileReference section */")
    A(f"\t\t{U_APP} /* {TARGET_NAME}.app */ = {{isa = PBXFileReference; "
      f"explicitFileType = wrapper.application; includeInIndex = 0; "
      f"path = {TARGET_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for n in swift:
        A(f"\t\t{uid('fr/' + n.rel)} /* {n.name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = sourcecode.swift; path = {quote(n.name)}; sourceTree = \"<group>\"; }};")
    for n in assets:
        A(f"\t\t{uid('fr/' + n.rel)} /* {n.name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = folder.assetcatalog; path = {quote(n.name)}; sourceTree = \"<group>\"; }};")
    for n in folders:
        A(f"\t\t{uid('fr/' + n.rel)} /* {n.name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = folder; path = {quote(n.name)}; sourceTree = \"<group>\"; }};")
    for n in plists:
        A(f"\t\t{uid('fr/' + n.rel)} /* {n.name} */ = {{isa = PBXFileReference; "
          f"lastKnownFileType = text.plist.xml; path = {quote(n.name)}; sourceTree = \"<group>\"; }};")
    A("/* End PBXFileReference section */")
    A("")

    # ---------- PBXFrameworksBuildPhase ----------
    A("/* Begin PBXFrameworksBuildPhase section */")
    A(f"\t\t{U_FW_PHASE} /* Frameworks */ = {{")
    A("\t\t\tisa = PBXFrameworksBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXFrameworksBuildPhase section */")
    A("")

    # ---------- PBXGroup ----------
    A("/* Begin PBXGroup section */")

    # 根
    A(f"\t\t{U_MAINGROUP} = {{")
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    A(f"\t\t\t\t{U_SRCDIR} /* {TARGET_NAME} */,")
    A(f"\t\t\t\t{U_PRODUCTS} /* Products */,")
    A("\t\t\t);")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    # Products
    A(f"\t\t{U_PRODUCTS} /* Products */ = {{")
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    A(f"\t\t\t\t{U_APP} /* {TARGET_NAME}.app */,")
    A("\t\t\t);")
    A("\t\t\tname = Products;")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    # 源根
    A(f"\t\t{U_SRCDIR} /* {TARGET_NAME} */ = {{")
    A("\t\t\tisa = PBXGroup;")
    A("\t\t\tchildren = (")
    for n in tree:
        ref = uid("grp/" + n.rel) if n.is_dir else uid("fr/" + n.rel)
        A(f"\t\t\t\t{ref} /* {n.name} */,")
    A("\t\t\t);")
    A(f"\t\t\tpath = {TARGET_NAME};")
    A("\t\t\tsourceTree = \"<group>\";")
    A("\t\t};")

    # 子目录
    for n in dirs:
        A(f"\t\t{uid('grp/' + n.rel)} /* {n.name} */ = {{")
        A("\t\t\tisa = PBXGroup;")
        A("\t\t\tchildren = (")
        for c in n.children:
            A(f"\t\t\t\t{uid('grp/' + c.rel) if c.is_dir else uid('fr/' + c.rel)} /* {c.name} */,")
        A("\t\t\t);")
        A(f"\t\t\tpath = {quote(n.name)};")
        A("\t\t\tsourceTree = \"<group>\";")
        A("\t\t};")

    A("/* End PBXGroup section */")
    A("")

    # ---------- PBXNativeTarget ----------
    A("/* Begin PBXNativeTarget section */")
    A(f"\t\t{U_TARGET} /* {TARGET_NAME} */ = {{")
    A("\t\t\tisa = PBXNativeTarget;")
    A(f"\t\t\tbuildConfigurationList = {U_TGT_CONF} /* Build configuration list for PBXNativeTarget \"{TARGET_NAME}\" */;")
    A("\t\t\tbuildPhases = (")
    A(f"\t\t\t\t{U_SRC_PHASE} /* Sources */,")
    A(f"\t\t\t\t{U_FW_PHASE} /* Frameworks */,")
    A(f"\t\t\t\t{U_RES_PHASE} /* Resources */,")
    A("\t\t\t);")
    A("\t\t\tbuildRules = (")
    A("\t\t\t);")
    A("\t\t\tdependencies = (")
    A("\t\t\t);")
    A(f"\t\t\tname = {TARGET_NAME};")
    A(f"\t\t\tproductName = {TARGET_NAME};")
    A(f"\t\t\tproductReference = {U_APP} /* {TARGET_NAME}.app */;")
    A("\t\t\tproductType = \"com.apple.product-type.application\";")
    A("\t\t};")
    A("/* End PBXNativeTarget section */")
    A("")

    # ---------- PBXProject ----------
    A("/* Begin PBXProject section */")
    A(f"\t\t{U_PROJECT} /* Project object */ = {{")
    A("\t\t\tisa = PBXProject;")
    A("\t\t\tattributes = {")
    A("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    A("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    A("\t\t\t\tLastUpgradeCheck = 1500;")
    A("\t\t\t\tTargetAttributes = {")
    A(f"\t\t\t\t\t{U_TARGET} = {{")
    A("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    A("\t\t\t\t\t};")
    A("\t\t\t\t};")
    A("\t\t\t};")
    A(f"\t\t\tbuildConfigurationList = {U_PROJ_CONF} /* Build configuration list for PBXProject \"{TARGET_NAME}\" */;")
    A("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    A("\t\t\tdevelopmentRegion = en;")
    A("\t\t\thasScannedForEncodings = 0;")
    A("\t\t\tknownRegions = (")
    A("\t\t\t\ten,")
    A("\t\t\t\tBase,")
    A("\t\t\t\t\"zh-Hans\",")
    A("\t\t\t);")
    A(f"\t\t\tmainGroup = {U_MAINGROUP};")
    A(f"\t\t\tproductRefGroup = {U_PRODUCTS} /* Products */;")
    A("\t\t\tprojectDirPath = \"\";")
    A("\t\t\tprojectRoot = \"\";")
    A("\t\t\ttargets = (")
    A(f"\t\t\t\t{U_TARGET} /* {TARGET_NAME} */,")
    A("\t\t\t);")
    A("\t\t};")
    A("/* End PBXProject section */")
    A("")

    # ---------- PBXResourcesBuildPhase ----------
    A("/* Begin PBXResourcesBuildPhase section */")
    A(f"\t\t{U_RES_PHASE} /* Resources */ = {{")
    A("\t\t\tisa = PBXResourcesBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    for n in assets:
        A(f"\t\t\t\t{uid('bf/' + n.rel)} /* {n.name} in Resources */,")
    for n in folders:
        A(f"\t\t\t\t{uid('bf/' + n.rel)} /* {n.name} in Resources */,")
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXResourcesBuildPhase section */")
    A("")

    # ---------- PBXSourcesBuildPhase ----------
    A("/* Begin PBXSourcesBuildPhase section */")
    A(f"\t\t{U_SRC_PHASE} /* Sources */ = {{")
    A("\t\t\tisa = PBXSourcesBuildPhase;")
    A("\t\t\tbuildActionMask = 2147483647;")
    A("\t\t\tfiles = (")
    for n in swift:
        A(f"\t\t\t\t{uid('bf/' + n.rel)} /* {n.name} in Sources */,")
    A("\t\t\t);")
    A("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    A("\t\t};")
    A("/* End PBXSourcesBuildPhase section */")
    A("")

    # ---------- XCBuildConfiguration ----------
    A("/* Begin XCBuildConfiguration section */")

    A(f"\t\t{U_CONF_DEBUG} /* Debug */ = {{")
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    for k, v in project_settings("Debug"):
        A(f"\t\t\t\t{k} = {v};")
    A("\t\t\t};")
    A("\t\t\tname = Debug;")
    A("\t\t};")

    A(f"\t\t{U_CONF_RELEASE} /* Release */ = {{")
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    for k, v in project_settings("Release"):
        A(f"\t\t\t\t{k} = {v};")
    A("\t\t\t};")
    A("\t\t\tname = Release;")
    A("\t\t};")

    A(f"\t\t{U_TGT_DEBUG} /* Debug */ = {{")
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    for k, v in target_settings():
        A(f"\t\t\t\t{k} = {v};")
    A("\t\t\t};")
    A("\t\t\tname = Debug;")
    A("\t\t};")

    A(f"\t\t{U_TGT_RELEASE} /* Release */ = {{")
    A("\t\t\tisa = XCBuildConfiguration;")
    A("\t\t\tbuildSettings = {")
    for k, v in target_settings():
        A(f"\t\t\t\t{k} = {v};")
    A("\t\t\t};")
    A("\t\t\tname = Release;")
    A("\t\t};")

    A("/* End XCBuildConfiguration section */")
    A("")

    # ---------- XCConfigurationList ----------
    A("/* Begin XCConfigurationList section */")
    A(f"\t\t{U_PROJ_CONF} /* Build configuration list for PBXProject \"{TARGET_NAME}\" */ = {{")
    A("\t\t\tisa = XCConfigurationList;")
    A("\t\t\tbuildConfigurations = (")
    A(f"\t\t\t\t{U_CONF_DEBUG} /* Debug */,")
    A(f"\t\t\t\t{U_CONF_RELEASE} /* Release */,")
    A("\t\t\t);")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    A(f"\t\t{U_TGT_CONF} /* Build configuration list for PBXNativeTarget \"{TARGET_NAME}\" */ = {{")
    A("\t\t\tisa = XCConfigurationList;")
    A("\t\t\tbuildConfigurations = (")
    A(f"\t\t\t\t{U_TGT_DEBUG} /* Debug */,")
    A(f"\t\t\t\t{U_TGT_RELEASE} /* Release */,")
    A("\t\t\t);")
    A("\t\t\tdefaultConfigurationIsVisible = 0;")
    A("\t\t\tdefaultConfigurationName = Release;")
    A("\t\t};")
    A("/* End XCConfigurationList section */")

    A("\t};")
    A(f"\trootObject = {U_PROJECT} /* Project object */;")
    A("}")
    A("")
    return "\n".join(L)


def project_settings(config: str) -> list[tuple[str, str]]:
    common = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CLANG_WARN_BOOL_CONVERSION", "YES"),
        ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
        ("CLANG_WARN_EMPTY_BODY", "YES"),
        ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("ENABLE_USER_SCRIPT_SANDBOXING", "YES"),
        ("GCC_C_LANGUAGE_STANDARD", "gnu17"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
        ("GCC_WARN_UNUSED_FUNCTION", "YES"),
        ("GCC_WARN_UNUSED_VARIABLE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
        ("LOCALIZATION_PREFERS_STRING_CATALOGS", "YES"),
        ("MTL_FAST_MATH", "YES"),
        ("SDKROOT", "iphoneos"),
        ("SWIFT_VERSION", SWIFT_VERSION),
    ]
    if config == "Debug":
        return common + [
            ("DEBUG_INFORMATION_FORMAT", "dwarf"),
            ("ENABLE_TESTABILITY", "YES"),
            ("GCC_DYNAMIC_NO_PIC", "NO"),
            ("GCC_OPTIMIZATION_LEVEL", "0"),
            ("GCC_PREPROCESSOR_DEFINITIONS", '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)'),
            ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
            ("ONLY_ACTIVE_ARCH", "YES"),
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
            ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
        ]
    return common + [
        ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
    ]


def target_settings() -> list[tuple[str, str]]:
    return [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", BUILD_NUMBER),
        ("DEVELOPMENT_TEAM", '""'),
        ("GENERATE_INFOPLIST_FILE", "NO"),
        ("INFOPLIST_FILE", f"{TARGET_NAME}/Support/Info.plist"),
        ("INFOPLIST_KEY_UILaunchScreen_Generation", "NO"),
        ("LD_RUNPATH_SEARCH_PATHS", '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)'),
        ("MARKETING_VERSION", MARKETING_VERSION),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
        ("PRODUCT_NAME", '"$(TARGET_NAME)"'),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("SWIFT_STRICT_CONCURRENCY", "minimal"),
        ("TARGETED_DEVICE_FAMILY", '"1,2"'),
    ]


# ============================================================
# scheme
# ============================================================

def build_scheme() -> str:
    t = uid("target/app")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{t}"
               BuildableName = "{TARGET_NAME}.app"
               BlueprintName = "{TARGET_NAME}"
               ReferencedContainer = "container:{TARGET_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{t}"
            BuildableName = "{TARGET_NAME}.app"
            BlueprintName = "{TARGET_NAME}"
            ReferencedContainer = "container:{TARGET_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{t}"
            BuildableName = "{TARGET_NAME}.app"
            BlueprintName = "{TARGET_NAME}"
            ReferencedContainer = "container:{TARGET_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


# ============================================================
# 自检
# ============================================================

def check(pbx: str) -> list[str]:
    """结构自检：括号平衡 + 所有被引用的 UUID 都已定义。"""
    errs: list[str] = []

    depth = 0
    for ch in pbx:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                errs.append("花括号提前闭合")
                break
    if depth != 0:
        errs.append(f"花括号不平衡，残余 {depth}")

    # 定义的 UUID：行首 `<UUID> = {` 或 `<UUID> /* ... */ = {`
    defined = set(re.findall(r"^\t\t([0-9A-F]{24})\b", pbx, re.M))
    # 被引用的 UUID
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", pbx))
    missing = referenced - defined
    if missing:
        errs.append(f"引用了未定义的 UUID：{sorted(missing)[:5]}")

    if f"rootObject = {uid('project')}" not in pbx:
        errs.append("rootObject 不对")
    return errs


# 金标：这几个值是在 Linux（GitHub Actions ubuntu runner）上跑出来的。
# 任何平台都必须算出同样的结果，否则 pbxproj 会随生成机器漂移，
# CI 的 `--check` 就会报「工程文件和源码不一致」。
# ★ 真踩过：rel 用 os.path.join 拼，Windows 出 'Crypto\LMAES.swift'、
#   Linux 出 'Crypto/LMAES.swift'，同一个文件两个 UUID。
GOLDEN_UID = {
    "project":                   "82A94B4421FD82FF334E2209",
    "target/app":                "B2F65123D784A7AC5A2356A1",
    "fr/Crypto/LMAES.swift":     "4EC379FB7D7EFFC185646B9C",
    "grp/Views":                 "D154BF9AE96ED6D023BE10B6",
}


def selftest() -> list[str]:
    """跨平台确定性自测：UUID 派生 + rel 分隔符。"""
    errs: list[str] = []
    for key, want in GOLDEN_UID.items():
        got = uid(key)
        if got != want:
            errs.append(f"uid({key!r}) = {got}，期望 {want}"
                        f"（rel 分隔符或 md5 前缀被改过？）")

    # scan() 产出的 rel 必须是 '/' 分隔（Node.__init__ 里还有 assert 兜底）
    try:
        rels = [n.rel for n in walk(scan(SRC_DIR))]
    except AssertionError as e:
        return errs + [f"scan() 产出非法 rel：{e}"]
    bad = [r for r in rels if "\\" in r]
    if bad:
        errs.append(f"rel 含反斜杠：{bad[:3]}")
    return errs


# ============================================================
# main
# ============================================================

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只自检，不写文件")
    args = ap.parse_args()

    pbx = build_pbxproj()
    errs = check(pbx)
    if errs:
        print("自检失败：")
        for e in errs:
            print("  -", e)
        return 1

    golden = selftest()
    if golden:
        print("跨平台确定性自测失败：")
        for e in golden:
            print("  -", e)
        return 1

    swift_n = pbx.count("in Sources */ = {isa = PBXBuildFile")
    print(f"pbxproj 自检通过（{len(pbx.splitlines())} 行，{swift_n} 个源文件，"
          f"UUID 金标 {len(GOLDEN_UID)}/{len(GOLDEN_UID)}）")

    proj_file = os.path.join(XCODEPROJ, "project.pbxproj")

    if args.check:
        # ★ 光比对「生成结果自洽」不够：新增了 .swift 却忘了重新生成 pbxproj 的话，
        #   文件根本不会进 Sources build phase，CI 会「成功」但功能悄悄缺失。
        #   这里直接跟磁盘上的文件逐字节比，把这类静默漏编译堵死。
        if not os.path.exists(proj_file):
            print(f"[x] 缺少 {proj_file}（跑一次不带 --check 的生成）")
            return 1
        with open(proj_file, encoding="utf-8") as f:
            on_disk = f.read()
        if on_disk != pbx:
            disk_n = on_disk.count("in Sources */ = {isa = PBXBuildFile")
            print(f"[x] {os.path.relpath(proj_file)} 与源码目录不一致："
                  f"磁盘 {disk_n} 个源文件，重新生成应为 {swift_n} 个。")
            # 数量相等时上面的信息等于废话，直接把第一处差异打出来。
            a, b = on_disk.splitlines(), pbx.splitlines()
            for i in range(max(len(a), len(b))):
                la = a[i] if i < len(a) else "<缺行>"
                lb = b[i] if i < len(b) else "<缺行>"
                if la != lb:
                    print(f"    首个差异在第 {i + 1} 行：")
                    print(f"      磁盘: {la.strip()[:110]}")
                    print(f"      重新生成: {lb.strip()[:110]}")
                    break
            print("    修复：python ios/tools/gen_xcodeproj.py 然后一起提交。")
            return 1
        print(f"project.pbxproj 与源码目录一致（{swift_n} 个源文件）")
        return 0

    scheme_dir = os.path.join(XCODEPROJ, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)

    with open(proj_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(pbx)
    with open(os.path.join(scheme_dir, f"{TARGET_NAME}.xcscheme"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(build_scheme())

    print("project ->", proj_file)
    print("scheme  ->", os.path.join(scheme_dir, f"{TARGET_NAME}.xcscheme"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
