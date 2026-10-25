"""Generate the checked-in Xcode project using Python's standard library only."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(name, value):
    key = ident(name)
    objects[key] = value
    return key


def ref(name):
    return ident(name)


def quoted(value):
    return json.dumps(value, ensure_ascii=False)


def config_list(name, settings):
    configs = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        if name == "Project":
            values.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                           "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym"})
            if mode == "Debug":
                values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
                values["ENABLE_TESTABILITY"] = "YES"
        configs.append(add(f"{name}{mode}", {"isa": "XCBuildConfiguration", "name": mode,
                                           "buildSettings": values}))
    return add(f"{name}Configs", {"isa": "XCConfigurationList", "buildConfigurations": configs,
                                 "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"})


def phase(name, kind, files):
    return add(name, {"isa": kind, "buildActionMask": 2147483647, "files": files,
                      "runOnlyForDeploymentPostprocessing": 0})


source_files = sorted((ROOT / "CodexIPad").glob("*.swift"))
test_files = sorted((ROOT / "CodexIPadTests").glob("*.swift"))
source_refs, test_refs, source_builds, test_builds = [], [], [], []
for files, refs, builds in [(source_files, source_refs, source_builds), (test_files, test_refs, test_builds)]:
    for path in files:
        file_ref = add(path.name, {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                                  "path": path.name, "sourceTree": "<group>"})
        refs.append(file_ref)
        builds.append(add(path.name + "Build", {"isa": "PBXBuildFile", "fileRef": file_ref}))

plist = add("Info.plist", {"isa": "PBXFileReference", "lastKnownFileType": "text.plist.xml",
                           "path": "Info.plist", "sourceTree": "<group>"})
bridge_file = add("BridgeResource", {"isa": "PBXFileReference", "lastKnownFileType": "text.script.python",
                                   "path": "../backend/bridge.py", "sourceTree": "<group>"})
bridge_build = add("BridgeResourceBuild", {"isa": "PBXBuildFile", "fileRef": bridge_file})
packages, products, framework_builds = [], [], []
for name, url, version, product in [
    ("Citadel", "https://github.com/orlandos-nl/Citadel.git", "0.12.1", "Citadel"),
    ("NIO", "https://github.com/apple/swift-nio.git", "2.81.0", "NIOCore"),
    ("NIOSSH", "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4", "NIOSSH"),
]:
    requirement = {"kind": "exactVersion", "version": version} if name != "NIO" else {
        "kind": "upToNextMajorVersion", "minimumVersion": version}
    package = add(name + "Package", {"isa": "XCRemoteSwiftPackageReference", "repositoryURL": url,
                                     "requirement": requirement})
    packages.append(package)
    dependency = add(product + "Product", {"isa": "XCSwiftPackageProductDependency",
                                          "package": package, "productName": product})
    products.append(dependency)
    framework_builds.append(add(product + "Framework", {"isa": "PBXBuildFile", "productRef": dependency}))

app = add("AppProduct", {"isa": "PBXFileReference", "explicitFileType": "wrapper.application",
                         "path": "CodexIPad.app", "sourceTree": "BUILT_PRODUCTS_DIR"})
tests = add("TestsProduct", {"isa": "PBXFileReference", "explicitFileType": "wrapper.cfbundle",
                             "path": "CodexIPadTests.xctest", "sourceTree": "BUILT_PRODUCTS_DIR"})
app_group = add("AppGroup", {"isa": "PBXGroup", "children": source_refs + [plist, bridge_file],
                             "path": "CodexIPad", "sourceTree": "<group>"})
test_group = add("TestsGroup", {"isa": "PBXGroup", "children": test_refs,
                                "path": "CodexIPadTests", "sourceTree": "<group>"})
product_group = add("ProductsGroup", {"isa": "PBXGroup", "children": [app, tests],
                                      "name": "Products", "sourceTree": "<group>"})
main_group = add("MainGroup", {"isa": "PBXGroup", "children": [app_group, test_group, product_group],
                              "sourceTree": "<group>"})

project_configs = config_list("Project", {
    "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SWIFT_VERSION": "5.0",
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
})
app_configs = config_list("App", {
    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.raycao.codexipad",
    "INFOPLIST_FILE": "CodexIPad/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "TARGETED_DEVICE_FAMILY": "2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO", "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "2", "MARKETING_VERSION": "0.2.0",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
})
test_configs = config_list("Tests", {
    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "com.raycao.codexipad.tests",
    "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "2",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "CODE_SIGN_STYLE": "Automatic",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/CodexIPad.app/CodexIPad",
    "BUNDLE_LOADER": "$(TEST_HOST)",
})
app_target = add("AppTarget", {
    "isa": "PBXNativeTarget", "buildConfigurationList": app_configs,
    "buildPhases": [phase("AppSources", "PBXSourcesBuildPhase", source_builds),
                    phase("AppFrameworks", "PBXFrameworksBuildPhase", framework_builds),
                    phase("AppResources", "PBXResourcesBuildPhase", [bridge_build])],
    "buildRules": [], "dependencies": [], "name": "CodexIPad", "productName": "CodexIPad",
    "productReference": app, "productType": "com.apple.product-type.application",
    "packageProductDependencies": products,
})
proxy = add("TestProxy", {"isa": "PBXContainerItemProxy", "containerPortal": ref("ProjectObject"),
                          "proxyType": 1, "remoteGlobalIDString": app_target, "remoteInfo": "CodexIPad"})
dependency = add("TestDependency", {"isa": "PBXTargetDependency", "target": app_target, "targetProxy": proxy})
test_target = add("TestsTarget", {
    "isa": "PBXNativeTarget", "buildConfigurationList": test_configs,
    "buildPhases": [phase("TestSources", "PBXSourcesBuildPhase", test_builds),
                    phase("TestFrameworks", "PBXFrameworksBuildPhase", []),
                    phase("TestResources", "PBXResourcesBuildPhase", [])],
    "buildRules": [], "dependencies": [dependency], "name": "CodexIPadTests",
    "productName": "CodexIPadTests", "productReference": tests,
    "productType": "com.apple.product-type.bundle.unit-test",
})
project = add("ProjectObject", {
    "isa": "PBXProject", "attributes": {"LastUpgradeCheck": "1600", "BuildIndependentTargetsInParallel": "YES",
        "TargetAttributes": {app_target: {"CreatedOnToolsVersion": "16.0"},
                             test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target}}},
    "buildConfigurationList": project_configs, "compatibilityVersion": "Xcode 14.0",
    "developmentRegion": "zh_CN", "hasScannedForEncodings": 0, "knownRegions": ["en", "zh_CN", "Base"],
    "mainGroup": main_group, "productRefGroup": product_group, "projectDirPath": "", "projectRoot": "",
    "targets": [app_target, test_target], "packageReferences": packages,
})


def serialize(value, indent=0):
    tab = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join(f"{tab}\t{quoted(k)} = {serialize(v, indent + 1)};\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{tab}\t{serialize(v, indent + 1)},\n" for v in value) + tab + ")"
    return str(value) if isinstance(value, int) else quoted(value)


project_dir = ROOT / "CodexIPad.xcodeproj"
project_dir.mkdir(exist_ok=True)
document = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(document) + "\n", encoding="utf-8")
scheme_dir = project_dir / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
app_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="CodexIPad.app" BlueprintName="CodexIPad" ReferencedContainer="container:CodexIPad.xcodeproj"/>'
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="CodexIPadTests.xctest" BlueprintName="CodexIPadTests" ReferencedContainer="container:CodexIPad.xcodeproj"/>'
(scheme_dir / "CodexIPad.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''', encoding="utf-8")
print(f"Generated {project_dir} ({len(source_files)} app sources, {len(test_files)} test sources).")
