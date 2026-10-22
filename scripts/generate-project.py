#!/usr/bin/env python3
"""追跡対象のソース一覧から再現可能なXcodeプロジェクトを生成する。"""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parent.parent
objects = {}
def uid(name): return hashlib.sha256(str(name).encode()).hexdigest()[:24].upper()
def obj(name, body):
    key = uid(name); objects[key] = body; return key
def quoted(s): return json.dumps(str(s))
def arr(xs): return '(' + ', '.join(xs) + (',' if xs else '') + ')'
def ref(path, kind):
    return obj(path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(path)}; sourceTree = SOURCE_ROOT;')
files = sorted(root.glob('Forblaze/**/*.swift'))
tests = sorted(root.glob('ForblazeTests/**/*.swift'))
sounds=sorted(root.glob('Forblaze/Resources/Sounds/*.wav'))
catalogs=sorted(root.glob('Forblaze/Resources/*.xcassets'))
assets=sorted(p for catalog in catalogs for p in catalog.rglob('*') if p.is_file() and p.name!='.DS_Store')
identity_files=sorted(files+sounds+assets+list(root.glob('Packages/ForblazeKit/Sources/**/*.swift'))+[root/'Forblaze/Info.plist',root/'Forblaze/forblaze.entitlements',root/'Packages/ForblazeKit/Package.swift'])
build_identity=hashlib.sha256(b''.join(str(p.relative_to(root)).encode()+b'\0'+p.read_bytes() for p in identity_files)).hexdigest()[:16]
refs = {str(p.relative_to(root)): ref(p.relative_to(root), 'sourcecode.swift') for p in files+tests}
sound_refs={str(p.relative_to(root)):ref(p.relative_to(root),'audio.wav') for p in sounds}
catalog_refs={str(p.relative_to(root)):ref(p.relative_to(root),'folder.assetcatalog') for p in catalogs}
package = obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = Packages/ForblazeKit;')
products=[]; targets=[]
for target in ('Forblaze', 'ForblazeTests'):
    isapp = target == 'Forblaze'
    product=obj(target+'product', f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if isapp else "wrapper.cfbundle"}; path = {"forblaze.app" if isapp else "ForblazeTests.xctest"}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    chosen = files if isapp else tests + [p for p in files if 'Features' in p.parts or 'Presentation' in p.parts or p.name == 'AppComposition.swift']
    builds=[obj(target+str(p), f'isa = PBXBuildFile; fileRef = {refs[str(p.relative_to(root))]};') for p in chosen]
    source=obj(target+'sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    dependencies=[]; frameworks=[]
    for lib in ('ForblazeCore','ForblazeApplication','ForblazeMacOS'):
        dep=obj(target+lib, f'isa = XCSwiftPackageProductDependency; productName = {lib};')
        dependencies.append(dep); frameworks.append(obj(target+lib+'build', f'isa = PBXBuildFile; productRef = {dep};'))
    framework=obj(target+'frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {arr(frameworks)}; runOnlyForDeploymentPostprocessing = 0;')
    phases=[source,framework]
    if isapp:
        sound_builds=[obj('soundbuild'+name,f'isa = PBXBuildFile; fileRef = {key};') for name,key in sound_refs.items()]
        catalog_builds=[obj('catalogbuild'+name,f'isa = PBXBuildFile; fileRef = {key};') for name,key in catalog_refs.items()]
        phases.append(obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr(sound_builds+catalog_builds)}; runOnlyForDeploymentPostprocessing = 0;'))
    configs=[]
    for mode in ('Debug','Release'):
        settings='ALWAYS_SEARCH_USER_PATHS = NO; SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 26.0; CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_OPTIMIZATION_LEVEL = '+('"-Onone";' if mode=='Debug' else '"-O";')
        settings += f' FORBLAZE_BUILD_IDENTIFIER = {quoted(build_identity)};'
        settings += ' PRODUCT_BUNDLE_IDENTIFIER = '+('"dev.kazuki-oshino.forblaze";' if isapp else '"dev.kazuki-oshino.forblaze.tests";')
        settings += ' PRODUCT_NAME = '+('forblaze; INFOPLIST_FILE = Forblaze/Info.plist; ENABLE_TESTABILITY = YES;' if isapp else 'ForblazeTests; GENERATE_INFOPLIST_FILE = YES;')
        if isapp: settings += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'
        configs.append(obj(target+mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ {settings} }};'))
    configlist=obj(target+'configs', f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationName = Debug;')
    tid=obj(target, f'isa = PBXNativeTarget; name = {target}; productName = {target}; productReference = {product}; productType = {quoted("com.apple.product-type.application" if isapp else "com.apple.product-type.bundle.unit-test")}; buildConfigurationList = {configlist}; buildPhases = {arr(phases)}; dependencies = (); packageProductDependencies = {arr(dependencies)};')
    targets.append(tid)
pg=obj('products', f'isa = PBXGroup; name = Products; children = {arr(products)}; sourceTree = "<group>";')
group=obj('rootgroup', f'isa = PBXGroup; children = {arr(list(refs.values())+list(sound_refs.values())+list(catalog_refs.values())+[pg])}; sourceTree = "<group>";')
configs=[obj('project'+m, f'isa = XCBuildConfiguration; name = {m}; buildSettings = {{ ARCHS = arm64; }};') for m in ('Debug','Release')]
cl=obj('projectconfig', f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationName = Debug;')
pr=obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2630; }}; buildConfigurationList = {cl}; compatibilityVersion = "Xcode 15.0"; developmentRegion = ja; knownRegions = (ja, en, Base); mainGroup = {group}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = {arr(targets)}; packageReferences = {arr([package])};')
out=root/'Forblaze.xcodeproj'; out.mkdir(exist_ok=True)
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(f'{k} = {{ {v} }};' for k,v in sorted(objects.items()))+f'\n}}; rootObject = {pr}; }}\n')
scheme=out/'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
def br(i,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{i}" BuildableName="{name}" BlueprintName="{ "Forblaze" if name=="forblaze.app" else "ForblazeTests"}" ReferencedContainer="container:Forblaze.xcodeproj"/>'
(scheme/'Forblaze.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{br(targets[0],'forblaze.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug"><Testables><TestableReference skipped="NO">{br(targets[1],'ForblazeTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug"><BuildableProductRunnable>{br(targets[0],'forblaze.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
