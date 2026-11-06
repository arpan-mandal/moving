#!/usr/bin/env python3
"""Generate a dependency-free Xcode project using the same source/resource tree as build.sh."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
project = root / 'Moving.xcodeproj'
project.mkdir(exist_ok=True)
def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def quote(value): return '"' + str(value).replace('\\','\\\\').replace('"','\\"') + '"'
objects = []
def add(name, isa, body):
    key = uid(name); objects.append(f'{key} = {{isa = {isa}; {body} }};'); return key
source_refs, source_builds = [], []
for file in sorted((root/'Sources').glob('*.swift')):
    name = str(file.relative_to(root))
    ref = add(name, 'PBXFileReference', f'lastKnownFileType = sourcecode.swift; path = {quote(file.name)}; sourceTree = "<group>";')
    source_refs.append(ref)
    source_builds.append(add(name+'-build','PBXBuildFile',f'fileRef = {ref};'))
resource_refs, resource_builds = [], []
for name, kind in [('Wallpapers','folder'),('Moving.icns','image.icns'),('MovingMark.png','image.png')]:
    ref = add(name, 'PBXFileReference',f'lastKnownFileType = {kind}; path = {quote(name)}; sourceTree = "<group>";')
    resource_refs.append(ref); resource_builds.append(add(name+'-build','PBXBuildFile',f'fileRef = {ref};'))
for name, kind in [('Info.plist','text.plist.xml'),('Moving.entitlements','text.plist.entitlements')]:
    resource_refs.append(add(name,'PBXFileReference',f'lastKnownFileType = {kind}; path = {quote(name)}; sourceTree = "<group>";'))
sources = add('Sources','PBXGroup',f'children = ({",".join(source_refs)}); path = Sources; sourceTree = "<group>";')
resources = add('Resources','PBXGroup',f'children = ({",".join(resource_refs)}); path = Resources; sourceTree = "<group>";')
app = add('Moving.app','PBXFileReference','explicitFileType = wrapper.application; includeInIndex = 0; path = Moving.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('Products','PBXGroup',f'children = ({app}); name = Products; sourceTree = "<group>";')
main = add('Main','PBXGroup',f'children = ({sources},{resources},{products}); sourceTree = "<group>";')
source_phase = add('SourcePhase','PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = ({",".join(source_builds)}); runOnlyForDeploymentPostprocessing = 0;')
resource_phase = add('ResourcePhase','PBXResourcesBuildPhase',f'buildActionMask = 2147483647; files = ({",".join(resource_builds)}); runOnlyForDeploymentPostprocessing = 0;')
framework_phase = add('FrameworkPhase','PBXFrameworksBuildPhase','buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
project_configs, target_configs = [], []
for config in ['Debug','Release']:
    project_settings = {'MACOSX_DEPLOYMENT_TARGET':'14.0','SDKROOT':'macosx','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','ARCHS':'$(ARCHS_STANDARD)','ONLY_ACTIVE_ARCH':'YES' if config=='Debug' else 'NO','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O','SWIFT_COMPILATION_MODE':'singlefile' if config=='Debug' else 'wholemodule'}
    if config=='Debug': project_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
    target_settings = {'PRODUCT_BUNDLE_IDENTIFIER':'com.motion.wallpaper','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Resources/Info.plist','CODE_SIGN_ENTITLEMENTS':'Resources/Moving.entitlements','CODE_SIGN_STYLE':'Automatic','ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'YES','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks','COMBINE_HIDPI_IMAGES':'YES','CURRENT_PROJECT_VERSION':'7','MARKETING_VERSION':'1.2.0'}
    def settings(values): return ' '.join(f'{key} = {quote(value)};' for key,value in values.items())
    project_configs.append(add('Project'+config,'XCBuildConfiguration',f'buildSettings = {{{settings(project_settings)}}}; name = {config};'))
    target_configs.append(add('Target'+config,'XCBuildConfiguration',f'buildSettings = {{{settings(target_settings)}}}; name = {config};'))
project_list = add('ProjectConfigList','XCConfigurationList',f'buildConfigurations = ({",".join(project_configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target_list = add('TargetConfigList','XCConfigurationList',f'buildConfigurations = ({",".join(target_configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = add('MovingTarget','PBXNativeTarget',f'buildConfigurationList = {target_list}; buildPhases = ({source_phase},{framework_phase},{resource_phase}); buildRules = (); dependencies = (); name = Moving; productName = Moving; productReference = {app}; productType = "com.apple.product-type.application";')
proj = add('MovingProject','PBXProject',f'attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600;}}; buildConfigurationList = {project_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(objects) +'\n}; rootObject = '+proj+'; }\n')
scheme = project/'xcshareddata/xcschemes/Moving.xcscheme'; scheme.parent.mkdir(parents=True, exist_ok=True)
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Moving.app" BlueprintName="Moving" ReferencedContainer="container:Moving.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Moving.app" BlueprintName="Moving" ReferencedContainer="container:Moving.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Moving.app" BlueprintName="Moving" ReferencedContainer="container:Moving.xcodeproj"/></BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
