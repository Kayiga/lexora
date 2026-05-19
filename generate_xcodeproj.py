#!/usr/bin/env python3
"""
Generates LinguaFlow.xcodeproj from scratch — no external tools needed.
Run from the LinguaFlow/ directory.
"""

import hashlib, os

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
XCODEPROJ   = os.path.join(PROJECT_DIR, "LinguaFlow.xcodeproj")
PBXPROJ     = os.path.join(XCODEPROJ, "project.pbxproj")

BUNDLE_ID    = "com.yiga.LinguaFlow"
KEYBOARD_ID  = "com.yiga.LinguaFlow.Keyboard"
DEPLOY       = "18.0"
SWIFT_VER    = "6.0"

def u(name): return hashlib.md5(name.encode()).hexdigest().upper()[:24]

# ── Source file lists ─────────────────────────────────────────────────────────
APP_SOURCES = [
    ("LinguaFlowApp.swift",            "LinguaFlow/LinguaFlowApp.swift"),
    ("UserVoiceProfile.swift",         "LinguaFlow/Models/UserVoiceProfile.swift"),
    ("TranscriptionSession.swift",     "LinguaFlow/Models/TranscriptionSession.swift"),
    ("VocabularyEntry.swift",          "LinguaFlow/Models/VocabularyEntry.swift"),
    ("AppState.swift",                 "LinguaFlow/Services/AppState.swift"),
    ("SpeechEngine.swift",             "LinguaFlow/Services/SpeechEngine.swift"),
    ("LanguageIntelligence.swift",     "LinguaFlow/Services/LanguageIntelligence.swift"),
    ("LearningEngine.swift",           "LinguaFlow/Services/LearningEngine.swift"),
    ("CloudSyncService.swift",         "LinguaFlow/Services/CloudSyncService.swift"),
    ("DashboardView.swift",            "LinguaFlow/Views/Dashboard/DashboardView.swift"),
    ("RecordingView.swift",            "LinguaFlow/Views/Recording/RecordingView.swift"),
    ("WaveformView.swift",             "LinguaFlow/Views/Recording/WaveformView.swift"),
    ("VoiceProfileView.swift",         "LinguaFlow/Views/Profile/VoiceProfileView.swift"),
    ("TranscriptionHistoryView.swift", "LinguaFlow/Views/History/TranscriptionHistoryView.swift"),
    ("SettingsView.swift",             "LinguaFlow/Views/Settings/SettingsView.swift"),
    ("OnboardingView.swift",           "LinguaFlow/Views/Onboarding/OnboardingView.swift"),
    ("Color+Extensions.swift",         "LinguaFlow/Extensions/Color+Extensions.swift"),
]
KB_SOURCES = [
    ("KeyboardViewController.swift", "LinguaFlowKeyboard/KeyboardViewController.swift"),
]

# These model files are compiled into BOTH targets so the keyboard extension
# can decode the shared UserVoiceProfile from App Group storage.
KB_SHARED_SOURCES = [
    ("UserVoiceProfile.swift", "LinguaFlow/Models/UserVoiceProfile.swift"),
    ("VocabularyEntry.swift",  "LinguaFlow/Models/VocabularyEntry.swift"),
]

# ── UIDs ──────────────────────────────────────────────────────────────────────
P            = u("project")
MAIN_GRP     = u("mainGroup")
PROD_GRP     = u("productsGroup")
APP_GRP      = u("appGroupRoot")
MDL_GRP      = u("modelsGroup")
SVC_GRP      = u("servicesGroup")
VW_GRP       = u("viewsGroup")
DASH_GRP     = u("dashboardGroup")
REC_GRP      = u("recordingGroup")
PROF_GRP     = u("profileGroup")
HIST_GRP     = u("historyGroup")
SET_GRP      = u("settingsGroup")
ONB_GRP      = u("onboardingGroup")
EXT_GRP      = u("extensionsGroup")
KB_GRP       = u("keyboardGroup")
APP_TGT      = u("appTarget")
KB_TGT       = u("keyboardTarget")
APP_PROD     = u("appProduct")
KB_PROD      = u("keyboardProduct")
APP_SRC_BP   = u("appSourcesBP")
APP_FWK_BP   = u("appFrameworksBP")
APP_RES_BP   = u("appResourcesBP")
APP_EMB_BP   = u("appEmbedExtBP")
KB_SRC_BP    = u("kbSourcesBP")
KB_FWK_BP    = u("kbFrameworksBP")
KB_RES_BP    = u("kbResourcesBP")
PROJ_CFGL    = u("projConfigList")
APP_CFGL     = u("appConfigList")
KB_CFGL      = u("kbConfigList")
PROJ_DBG     = u("projDebug")
PROJ_REL     = u("projRelease")
APP_DBG      = u("appDebug")
APP_REL      = u("appRelease")
KB_DBG       = u("kbDebug")
KB_REL       = u("kbRelease")
APP_PLIST    = u("appInfoPlist")
KB_PLIST     = u("kbInfoPlist")
KB_EMBED_BF  = u("kbEmbedBuildFile")

def fref(n): return u("fref_" + n)
def bf(n):   return u("bfile_" + n)

# ── pbxproj helpers ───────────────────────────────────────────────────────────
T  = "\t"
T2 = "\t\t"
T3 = "\t\t\t"
T4 = "\t\t\t\t"

def sec(name, content):
    return f"{T2}/* Begin {name} section */\n{content}\n{T2}/* End {name} section */"

def obj(uid, pairs):
    """Render a single PBX object."""
    inner = "".join(f"\n{T3}{k} = {v};" for k, v in pairs)
    return f"{T2}{uid} = {{{inner}\n{T2}}};"

def arr(*items):
    if not items: return "()"
    joined = "".join(f"\n{T4}{i}," for i in items)
    return f"({joined}\n{T3})"

def ci(uid, comment): return f"{uid} /* {comment} */"

# ── Build settings ────────────────────────────────────────────────────────────
def proj_debug_settings():
    return {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "MTL_FAST_MATH": "YES",
        "ONLY_ACTIVE_ARCH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    }

def proj_release_settings():
    return {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_TESTABILITY": "NO",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_OPTIMIZATION_LEVEL": "s",
        "GCC_PREPROCESSOR_DEFINITIONS": '("$(inherited)")',
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "MTL_FAST_MATH": "YES",
        "ONLY_ACTIVE_ARCH": "NO",
        "SDKROOT": "iphoneos",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    }

def app_settings(variant):
    base = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"LinguaFlow/Info.plist"',
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f'"{BUNDLE_ID}"',
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT_VER,
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    if variant == "Release":
        base["VALIDATE_PRODUCT"] = "YES"
    return base

def kb_settings(variant):
    base = {
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": '"LinguaFlowKeyboard/Info.plist"',
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks")',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f'"{KEYBOARD_ID}"',
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": SWIFT_VER,
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }
    if variant == "Release":
        base["VALIDATE_PRODUCT"] = "YES"
    return base

def render_settings(d):
    """Render a dict of build settings into pbxproj key = value; lines."""
    lines = []
    for k, v in sorted(d.items()):
        lines.append(f"{T4}{k} = {v};")
    return "\n".join(lines)

def build_cfg(uid, name, settings_dict):
    return (
        f"{T2}{uid} = {{\n"
        f"{T3}isa = XCBuildConfiguration;\n"
        f"{T3}buildSettings = {{\n"
        + render_settings(settings_dict) + "\n"
        f"{T3}}};\n"
        f"{T3}name = {name};\n"
        f"{T2}}};"
    )

# ── Generate project.pbxproj ──────────────────────────────────────────────────
def gen_pbxproj():
    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append(f"{T}archiveVersion = 1;")
    out.append(f"{T}classes = {{")
    out.append(f"{T}}};")
    out.append(f"{T}objectVersion = 77;")
    out.append(f"{T}objects = {{")
    out.append("")

    # ── PBXBuildFile ──────────────────────────────────────────────────────────
    bfs = []
    for name, _ in APP_SOURCES:
        bfs.append(f"{T2}{bf(name)} = {{isa = PBXBuildFile; fileRef = {fref(name)}; }};")
    for name, _ in KB_SOURCES:
        bfs.append(f"{T2}{bf(name)} = {{isa = PBXBuildFile; fileRef = {fref(name)}; }};")
    # Shared model files compiled into the keyboard extension (separate build file UID)
    for name, _ in KB_SHARED_SOURCES:
        bfs.append(f"{T2}{bf('kb_' + name)} = {{isa = PBXBuildFile; fileRef = {fref(name)}; }};")
    # Embed-extension build file
    bfs.append(f'{T2}{KB_EMBED_BF} = {{isa = PBXBuildFile; fileRef = {KB_PROD}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
    out.append(sec("PBXBuildFile", "\n".join(bfs)))
    out.append("")

    # ── PBXCopyFilesBuildPhase ────────────────────────────────────────────────
    embed = (
        f"{T2}{APP_EMB_BP} = {{\n"
        f"{T3}isa = PBXCopyFilesBuildPhase;\n"
        f"{T3}buildActionMask = 2147483647;\n"
        f"{T3}dstPath = \"\";\n"
        f"{T3}dstSubfolderSpec = 13;\n"
        f"{T3}files = (\n"
        f"{T4}{ci(KB_EMBED_BF, 'LinguaFlowKeyboard.appex in Embed Foundation Extensions')},\n"
        f"{T3});\n"
        f"{T3}name = \"Embed Foundation Extensions\";\n"
        f"{T3}runOnlyForDeploymentPostprocessing = 0;\n"
        f"{T2}}};"
    )
    out.append(sec("PBXCopyFilesBuildPhase", embed))
    out.append("")

    # ── PBXFileReference ──────────────────────────────────────────────────────
    frefs = []
    for name, path in APP_SOURCES + KB_SOURCES:
        frefs.append(f'{T2}{fref(name)} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "{name}"; path = "{path}"; sourceTree = "<group>"; }};')
    frefs.append(f'{T2}{APP_PLIST} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = "Info.plist"; path = "LinguaFlow/Info.plist"; sourceTree = "<group>"; }};')
    frefs.append(f'{T2}{KB_PLIST} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = "Info.plist"; path = "LinguaFlowKeyboard/Info.plist"; sourceTree = "<group>"; }};')
    frefs.append(f'{T2}{APP_PROD} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "LinguaFlow.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    frefs.append(f'{T2}{KB_PROD} = {{isa = PBXFileReference; explicitFileType = wrapper.app-extension; includeInIndex = 0; path = "LinguaFlowKeyboard.appex"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    out.append(sec("PBXFileReference", "\n".join(frefs)))
    out.append("")

    # ── PBXGroup ──────────────────────────────────────────────────────────────
    def grp(uid, name_or_path, children, is_path=False):
        attr = f'path = "{name_or_path}"' if is_path else f'name = "{name_or_path}"'
        kids = "".join(f"\n{T4}{ci(c, lbl)}," for c, lbl in children)
        return (
            f"{T2}{uid} = {{\n"
            f"{T3}isa = PBXGroup;\n"
            f"{T3}children = ({kids}\n{T3});\n"
            f"{T3}{attr};\n"
            f"{T3}sourceTree = \"<group>\";\n"
            f"{T2}}};"
        )

    groups = []
    groups.append(grp(PROD_GRP, "Products", [
        (APP_PROD, "LinguaFlow.app"),
        (KB_PROD,  "LinguaFlowKeyboard.appex"),
    ]))
    groups.append(grp(EXT_GRP, "Extensions", [
        (fref("Color+Extensions.swift"), "Color+Extensions.swift"),
    ]))
    groups.append(grp(DASH_GRP, "Dashboard", [
        (fref("DashboardView.swift"), "DashboardView.swift"),
    ]))
    groups.append(grp(REC_GRP, "Recording", [
        (fref("RecordingView.swift"),  "RecordingView.swift"),
        (fref("WaveformView.swift"),   "WaveformView.swift"),
    ]))
    groups.append(grp(PROF_GRP, "Profile", [
        (fref("VoiceProfileView.swift"), "VoiceProfileView.swift"),
    ]))
    groups.append(grp(HIST_GRP, "History", [
        (fref("TranscriptionHistoryView.swift"), "TranscriptionHistoryView.swift"),
    ]))
    groups.append(grp(SET_GRP, "Settings", [
        (fref("SettingsView.swift"), "SettingsView.swift"),
    ]))
    groups.append(grp(ONB_GRP, "Onboarding", [
        (fref("OnboardingView.swift"), "OnboardingView.swift"),
    ]))
    groups.append(grp(VW_GRP, "Views", [
        (DASH_GRP, "Dashboard"),
        (REC_GRP,  "Recording"),
        (PROF_GRP, "Profile"),
        (HIST_GRP, "History"),
        (SET_GRP,  "Settings"),
        (ONB_GRP,  "Onboarding"),
    ]))
    groups.append(grp(MDL_GRP, "Models", [
        (fref("UserVoiceProfile.swift"),     "UserVoiceProfile.swift"),
        (fref("TranscriptionSession.swift"), "TranscriptionSession.swift"),
        (fref("VocabularyEntry.swift"),      "VocabularyEntry.swift"),
    ]))
    groups.append(grp(SVC_GRP, "Services", [
        (fref("AppState.swift"),             "AppState.swift"),
        (fref("SpeechEngine.swift"),         "SpeechEngine.swift"),
        (fref("LanguageIntelligence.swift"), "LanguageIntelligence.swift"),
        (fref("LearningEngine.swift"),       "LearningEngine.swift"),
        (fref("CloudSyncService.swift"),     "CloudSyncService.swift"),
    ]))
    groups.append(grp(APP_GRP, "LinguaFlow", [
        (fref("LinguaFlowApp.swift"), "LinguaFlowApp.swift"),
        (MDL_GRP,    "Models"),
        (SVC_GRP,    "Services"),
        (VW_GRP,     "Views"),
        (EXT_GRP,    "Extensions"),
        (APP_PLIST,  "Info.plist"),
    ]))
    groups.append(grp(KB_GRP, "LinguaFlowKeyboard", [
        (fref("KeyboardViewController.swift"), "KeyboardViewController.swift"),
        (KB_PLIST, "Info.plist"),
    ]))
    groups.append(grp(MAIN_GRP, "LinguaFlow", [
        (APP_GRP,   "LinguaFlow"),
        (KB_GRP,    "LinguaFlowKeyboard"),
        (PROD_GRP,  "Products"),
    ]))
    out.append(sec("PBXGroup", "\n".join(groups)))
    out.append("")

    # ── PBXNativeTarget ───────────────────────────────────────────────────────
    targets = []

    def native_target(uid, name, bundle_type, product_uid, product_type, cfgl, phases):
        phase_refs = "".join(f"\n{T4}{ci(ph, lbl)}," for ph, lbl in phases)
        cfgl_label = 'Build configuration list for PBXNativeTarget "' + name + '"'
        return (
            f"{T2}{uid} = {{\n"
            f"{T3}isa = PBXNativeTarget;\n"
            f"{T3}buildConfigurationList = {ci(cfgl, cfgl_label)};\n"
            f"{T3}buildPhases = ({phase_refs}\n{T3});\n"
            f"{T3}buildRules = ();\n"
            f"{T3}dependencies = ();\n"
            f"{T3}name = {name};\n"
            f"{T3}productName = {name};\n"
            f"{T3}productReference = {ci(product_uid, f'{name}.{bundle_type}')};\n"
            f"{T3}productType = \"{product_type}\";\n"
            f"{T2}}};"
        )

    targets.append(native_target(APP_TGT, "LinguaFlow", "app", APP_PROD,
        "com.apple.product-type.application", APP_CFGL, [
            (APP_SRC_BP, "Sources"),
            (APP_FWK_BP, "Frameworks"),
            (APP_RES_BP, "Resources"),
            (APP_EMB_BP, "Embed Foundation Extensions"),
        ]))
    targets.append(native_target(KB_TGT, "LinguaFlowKeyboard", "appex", KB_PROD,
        "com.apple.product-type.app-extension", KB_CFGL, [
            (KB_SRC_BP, "Sources"),
            (KB_FWK_BP, "Frameworks"),
            (KB_RES_BP, "Resources"),
        ]))
    out.append(sec("PBXNativeTarget", "\n".join(targets)))
    out.append("")

    # ── PBXProject ────────────────────────────────────────────────────────────
    proj_cfgl_label = 'Build configuration list for PBXProject "LinguaFlow"'
    proj = (
        f"{T2}{P} /* Project object */ = {{\n"
        f"{T3}isa = PBXProject;\n"
        f"{T3}attributes = {{\n"
        f"{T4}BuildIndependentTargetsInParallel = 1;\n"
        f"{T4}LastSwiftUpdateCheck = 1640;\n"
        f"{T4}LastUpgradeCheck = 1640;\n"
        f"{T4}TargetAttributes = {{\n"
        f"{T4}\t{APP_TGT} = {{ CreatedOnToolsVersion = 16.4; }};\n"
        f"{T4}\t{KB_TGT}  = {{ CreatedOnToolsVersion = 16.4; }};\n"
        f"{T4}}};\n"
        f"{T3}}};\n"
        f"{T3}buildConfigurationList = {ci(PROJ_CFGL, proj_cfgl_label)};\n"
        f"{T3}compatibilityVersion = \"Xcode 14.0\";\n"
        f"{T3}developmentRegion = en;\n"
        f"{T3}hasScannedForEncodings = 0;\n"
        f"{T3}knownRegions = (\n{T4}en,\n{T4}Base,\n{T3});\n"
        f"{T3}mainGroup = {MAIN_GRP};\n"
        f"{T3}productRefGroup = {ci(PROD_GRP, 'Products')};\n"
        f"{T3}projectDirPath = \"\";\n"
        f"{T3}projectRoot = \"\";\n"
        f"{T3}targets = (\n"
        f"{T4}{ci(APP_TGT, 'LinguaFlow')},\n"
        f"{T4}{ci(KB_TGT, 'LinguaFlowKeyboard')},\n"
        f"{T3});\n"
        f"{T2}}};"
    )
    out.append(sec("PBXProject", proj))
    out.append("")

    # ── Build Phases ──────────────────────────────────────────────────────────
    def sources_phase(uid, files):
        kids = "".join(f"\n{T4}{ci(bf(n), f'{n} in Sources')}," for n in files)
        return (
            f"{T2}{uid} = {{\n"
            f"{T3}isa = PBXSourcesBuildPhase;\n"
            f"{T3}buildActionMask = 2147483647;\n"
            f"{T3}files = ({kids}\n{T3});\n"
            f"{T3}runOnlyForDeploymentPostprocessing = 0;\n"
            f"{T2}}};"
        )

    def empty_phase(uid, isa):
        return (
            f"{T2}{uid} = {{\n"
            f"{T3}isa = {isa};\n"
            f"{T3}buildActionMask = 2147483647;\n"
            f"{T3}files = ();\n"
            f"{T3}runOnlyForDeploymentPostprocessing = 0;\n"
            f"{T2}}};"
        )

    app_file_names = [n for n, _ in APP_SOURCES]
    kb_file_names  = [n for n, _ in KB_SOURCES]

    # Build the keyboard sources phase manually so it uses kb_-prefixed UIDs for shared files
    def kb_sources_phase():
        lines = []
        for n in kb_file_names:
            lines.append(f"\n{T4}{ci(bf(n), n + ' in Sources')},")
        for n, _ in KB_SHARED_SOURCES:
            lines.append(f"\n{T4}{ci(bf('kb_' + n), n + ' in Sources')},")
        kids = "".join(lines)
        return (
            f"{T2}{KB_SRC_BP} = {{\n"
            f"{T3}isa = PBXSourcesBuildPhase;\n"
            f"{T3}buildActionMask = 2147483647;\n"
            f"{T3}files = ({kids}\n{T3});\n"
            f"{T3}runOnlyForDeploymentPostprocessing = 0;\n"
            f"{T2}}};"
        )

    src_phases = [
        sources_phase(APP_SRC_BP, app_file_names),
        kb_sources_phase(),
    ]
    fwk_phases = [
        empty_phase(APP_FWK_BP, "PBXFrameworksBuildPhase"),
        empty_phase(KB_FWK_BP,  "PBXFrameworksBuildPhase"),
    ]
    res_phases = [
        empty_phase(APP_RES_BP, "PBXResourcesBuildPhase"),
        empty_phase(KB_RES_BP,  "PBXResourcesBuildPhase"),
    ]

    out.append(sec("PBXSourcesBuildPhase",   "\n".join(src_phases)))
    out.append("")
    out.append(sec("PBXFrameworksBuildPhase", "\n".join(fwk_phases)))
    out.append("")
    out.append(sec("PBXResourcesBuildPhase",  "\n".join(res_phases)))
    out.append("")

    # ── XCBuildConfiguration ──────────────────────────────────────────────────
    cfgs = [
        build_cfg(PROJ_DBG,  "Debug",   proj_debug_settings()),
        build_cfg(PROJ_REL,  "Release", proj_release_settings()),
        build_cfg(APP_DBG,   "Debug",   app_settings("Debug")),
        build_cfg(APP_REL,   "Release", app_settings("Release")),
        build_cfg(KB_DBG,    "Debug",   kb_settings("Debug")),
        build_cfg(KB_REL,    "Release", kb_settings("Release")),
    ]
    out.append(sec("XCBuildConfiguration", "\n".join(cfgs)))
    out.append("")

    # ── XCConfigurationList ───────────────────────────────────────────────────
    def cfg_list(uid, target_label, dbg, rel):
        return (
            f"{T2}{uid} = {{\n"
            f"{T3}isa = XCConfigurationList;\n"
            f"{T3}buildConfigurations = (\n"
            f"{T4}{ci(dbg, 'Debug')},\n"
            f"{T4}{ci(rel, 'Release')},\n"
            f"{T3});\n"
            f"{T3}defaultConfigurationIsVisible = 0;\n"
            f"{T3}defaultConfigurationName = Release;\n"
            f"{T2}}};"
        )

    cfglists = [
        cfg_list(PROJ_CFGL, 'PBXProject "LinguaFlow"',          PROJ_DBG, PROJ_REL),
        cfg_list(APP_CFGL,  'PBXNativeTarget "LinguaFlow"',      APP_DBG,  APP_REL),
        cfg_list(KB_CFGL,   'PBXNativeTarget "LinguaFlowKeyboard"', KB_DBG, KB_REL),
    ]
    out.append(sec("XCConfigurationList", "\n".join(cfglists)))
    out.append("")

    out.append(f"\t}};")
    out.append(f"\trootObject = {ci(P, 'Project object')};")
    out.append("}")
    return "\n".join(out)

# ── Scheme file ───────────────────────────────────────────────────────────────
def gen_scheme():
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1640"
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
               BlueprintIdentifier = "{APP_TGT}"
               BuildableName = "LinguaFlow.app"
               BlueprintName = "LinguaFlow"
               ReferencedContainer = "container:LinguaFlow.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{KB_TGT}"
               BuildableName = "LinguaFlowKeyboard.appex"
               BlueprintName = "LinguaFlowKeyboard"
               ReferencedContainer = "container:LinguaFlow.xcodeproj">
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
            BlueprintIdentifier = "{APP_TGT}"
            BuildableName = "LinguaFlow.app"
            BlueprintName = "LinguaFlow"
            ReferencedContainer = "container:LinguaFlow.xcodeproj">
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
            BlueprintIdentifier = "{APP_TGT}"
            BuildableName = "LinguaFlow.app"
            BlueprintName = "LinguaFlow"
            ReferencedContainer = "container:LinguaFlow.xcodeproj">
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
</Scheme>"""

# ── Workspace ─────────────────────────────────────────────────────────────────
def gen_workspace():
    return """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>"""

# ── Write everything ──────────────────────────────────────────────────────────
os.makedirs(XCODEPROJ, exist_ok=True)

# project.pbxproj
pbxproj_content = gen_pbxproj()
with open(PBXPROJ, "w", encoding="utf-8") as f:
    f.write(pbxproj_content)

# project.xcworkspace/contents.xcworkspacedata
ws_dir = os.path.join(XCODEPROJ, "project.xcworkspace")
os.makedirs(ws_dir, exist_ok=True)
with open(os.path.join(ws_dir, "contents.xcworkspacedata"), "w") as f:
    f.write(gen_workspace())

# xcshareddata/xcschemes/LinguaFlow.xcscheme
schemes_dir = os.path.join(XCODEPROJ, "xcshareddata", "xcschemes")
os.makedirs(schemes_dir, exist_ok=True)
with open(os.path.join(schemes_dir, "LinguaFlow.xcscheme"), "w") as f:
    f.write(gen_scheme())

print("Generated:")
print(f"  {PBXPROJ}")
print(f"  {ws_dir}/contents.xcworkspacedata")
print(f"  {schemes_dir}/LinguaFlow.xcscheme")
print(f"\nApp target UID:      {APP_TGT}")
print(f"Keyboard target UID: {KB_TGT}")
print(f"Source files:        {len(APP_SOURCES)} app + {len(KB_SOURCES)} keyboard")
