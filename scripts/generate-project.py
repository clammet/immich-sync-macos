"""Generate the checked-in Xcode project, using only Python's standard library."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def key(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(identity, isa, **values):
    ident = key(identity)
    objects[ident] = dict(isa=isa, **values)
    return ident

def ref(path, kind="sourcecode.swift"):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="SOURCE_ROOT")

config = ref("Config/Base.xcconfig", "text.xcconfig")
app_sources = [ref(str(p.relative_to(ROOT))) for p in sorted((ROOT / "Sources/ImmichSyncApp").glob("*.swift"))]
ext_sources = [ref(str(p.relative_to(ROOT))) for p in sorted((ROOT / "Sources/ImmichFileProvider").glob("*.swift"))]
badge = ref("Resources/IgnoredBadge.icns", "image.icns")
package = add("package", "XCLocalSwiftPackageReference", relativePath=".")
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Immich Sync.app", sourceTree="BUILT_PRODUCTS_DIR")
ext_product = add("ext-product", "PBXFileReference", explicitFileType="wrapper.app-extension", path="ImmichFileProvider.appex", sourceTree="BUILT_PRODUCTS_DIR")

def configs(name, settings):
    values = []
    for mode in ["Debug", "Release"]:
        mode_settings = dict(settings)
        mode_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        mode_settings["ONLY_ACTIVE_ARCH"] = "YES" if mode == "Debug" else "NO"
        if mode == "Debug": mode_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        values.append(add(name + mode, "XCBuildConfiguration", baseConfigurationReference=config, name=mode, buildSettings=mode_settings))
    return add(name + "configs", "XCConfigurationList", buildConfigurations=values, defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

def target(name, sources, product, extension=False):
    core = add(name + "core", "XCSwiftPackageProductDependency", package=package, productName="ImmichCore")
    core_link = add(name + "corelink", "PBXBuildFile", productRef=core)
    source_files = [add(name + source, "PBXBuildFile", fileRef=source) for source in sources]
    phase_sources = add(name + "sources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=source_files, runOnlyForDeploymentPostprocessing="0")
    phase_frameworks = add(name + "frameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[core_link], runOnlyForDeploymentPostprocessing="0")
    resources = [add("badge-build", "PBXBuildFile", fileRef=badge)] if extension else []
    phase_resources = add(name + "resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
    settings = dict(PRODUCT_NAME="ImmichFileProvider" if extension else "Immich Sync", PRODUCT_MODULE_NAME="ImmichFileProvider" if extension else "ImmichSyncApp",
        PRODUCT_BUNDLE_IDENTIFIER="$(IMMICH_BUNDLE_PREFIX).FileProvider" if extension else "$(IMMICH_BUNDLE_PREFIX)",
        INFOPLIST_FILE="Config/Extension-Info.plist" if extension else "Config/App-Info.plist",
        CODE_SIGN_ENTITLEMENTS="Config/Extension.entitlements" if extension else "Config/App.entitlements",
        GENERATE_INFOPLIST_FILE="NO", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"])
    if extension:
        settings.update(APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES")
    return add(name, "PBXNativeTarget", name=name, productName=name, productReference=product,
        productType="com.apple.product-type.app-extension" if extension else "com.apple.product-type.application",
        buildConfigurationList=configs(name, settings), buildPhases=[phase_sources, phase_frameworks, phase_resources], buildRules=[], dependencies=[], packageProductDependencies=[core])

ext = target("ImmichFileProvider", ext_sources, ext_product, extension=True)
app = target("ImmichSync", app_sources, app_product)
proxy = add("ext-proxy", "PBXContainerItemProxy", containerPortal=key("project"), proxyType="1", remoteGlobalIDString=ext, remoteInfo="ImmichFileProvider")
dependency = add("ext-dependency", "PBXTargetDependency", target=ext, targetProxy=proxy)
embed = add("embed-ext-file", "PBXBuildFile", fileRef=ext_product, settings=dict(ATTRIBUTES=["RemoveHeadersOnCopy"]))
embed_phase = add("embed-ext", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", files=[embed], name="Embed App Extensions", runOnlyForDeploymentPostprocessing="0")
objects[app]["dependencies"] = [dependency]
objects[app]["buildPhases"].append(embed_phase)
products = add("products", "PBXGroup", name="Products", children=[app_product, ext_product], sourceTree="<group>")
source_group = add("sources", "PBXGroup", name="Sources", children=app_sources + ext_sources, sourceTree="<group>")
config_group = add("config", "PBXGroup", name="Configuration", children=[config] + [ref("Config/" + p, "text.plist.xml") for p in ["App-Info.plist", "Extension-Info.plist", "App.entitlements", "Extension.entitlements"]], sourceTree="<group>")
group = add("main", "PBXGroup", children=[source_group, config_group, badge, products], sourceTree="<group>")
project = add("project", "PBXProject", attributes=dict(LastUpgradeCheck="1600", BuildIndependentTargetsInParallel="YES"),
    buildConfigurationList=configs("project", dict(SDKROOT="macosx", CLANG_ENABLE_MODULES="YES")), compatibilityVersion="Xcode 14.0",
    developmentRegion="en", hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products,
    projectDirPath="", projectRoot="", targets=[app, ext], packageReferences=[package])

def render(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + render(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (level + 1) + render(v, level + 1) + ",\n" for v in value) + "\t" * level + ")"
    return json.dumps(value)

folder = ROOT / "ImmichSync.xcodeproj"
folder.mkdir(exist_ok=True)
(folder / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")
scheme = folder / "xcshareddata/xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
(scheme / "ImmichSync.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Immich Sync.app" BlueprintName="ImmichSync" ReferencedContainer="container:ImmichSync.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Immich Sync.app" BlueprintName="ImmichSync" ReferencedContainer="container:ImmichSync.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated ImmichSync.xcodeproj")
