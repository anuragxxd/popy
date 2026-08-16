#!/bin/bash
set -euo pipefail

# ============================================================
#  Popy — macOS Clipboard History Manager
#  Setup Script: generates Xcode project and builds the app
#  No external dependencies required (no XcodeGen needed)
# ============================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[✓]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $1"; }
fail()  { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
step()  { echo -e "\n${BOLD}→ $1${RESET}"; }

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# --------------------------------------------------
# 1. Check prerequisites
# --------------------------------------------------
step "Checking prerequisites..."

if ! command -v swift &>/dev/null; then
    fail "Swift is not installed. Install Xcode or Xcode Command Line Tools first."
fi
info "Swift found: $(swift --version 2>&1 | head -1)"

if ! command -v xcodebuild &>/dev/null; then
    fail "xcodebuild not found. Install Xcode from the App Store."
fi
info "Xcode found: $(xcodebuild -version 2>&1 | head -1)"

# --------------------------------------------------
# 2. Generate Xcode project (no external tools needed)
# --------------------------------------------------
step "Generating Xcode project..."

mkdir -p Popy.xcodeproj

cat > Popy.xcodeproj/project.pbxproj << 'PBXPROJ'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		A1000001 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000001 /* main.swift */; };
		A1000002 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000002 /* AppDelegate.swift */; };
		A1000003 /* ClipboardItem.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000003 /* ClipboardItem.swift */; };
		A1000004 /* ClipboardManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000004 /* ClipboardManager.swift */; };
		A1000005 /* LoginItemManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000005 /* LoginItemManager.swift */; };
		A1000006 /* KeyboardSimulator.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000008 /* KeyboardSimulator.swift */; };
		A1000007 /* PreferencesManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000009 /* PreferencesManager.swift */; };
		A1000008 /* UpdateManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000011 /* UpdateManager.swift */; };
		A1000009 /* KeychainStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000012 /* KeychainStore.swift */; };
		A1000010 /* HotkeyManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000013 /* HotkeyManager.swift */; };
		A1000011 /* FnKeyListener.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000014 /* FnKeyListener.swift */; };
		A1000012 /* AudioRecorder.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000015 /* AudioRecorder.swift */; };
		A1000013 /* TranscriptionService.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000016 /* TranscriptionService.swift */; };
		A1000014 /* VoiceInputController.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000017 /* VoiceInputController.swift */; };
		A1000015 /* DictationHUD.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000018 /* DictationHUD.swift */; };
		A1000016 /* SystemAudioMuter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B1000019 /* SystemAudioMuter.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		B1000001 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		B1000002 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
		B1000003 /* ClipboardItem.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClipboardItem.swift; sourceTree = "<group>"; };
		B1000004 /* ClipboardManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ClipboardManager.swift; sourceTree = "<group>"; };
		B1000005 /* LoginItemManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LoginItemManager.swift; sourceTree = "<group>"; };
		B1000006 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		B1000007 /* Popy.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Popy.entitlements; sourceTree = "<group>"; };
		B1000008 /* KeyboardSimulator.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeyboardSimulator.swift; sourceTree = "<group>"; };
		B1000009 /* PreferencesManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreferencesManager.swift; sourceTree = "<group>"; };
		B1000010 /* Popy.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Popy.app; sourceTree = BUILT_PRODUCTS_DIR; };
		B1000011 /* UpdateManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UpdateManager.swift; sourceTree = "<group>"; };
		B1000012 /* KeychainStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = KeychainStore.swift; sourceTree = "<group>"; };
		B1000013 /* HotkeyManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HotkeyManager.swift; sourceTree = "<group>"; };
		B1000014 /* FnKeyListener.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FnKeyListener.swift; sourceTree = "<group>"; };
		B1000015 /* AudioRecorder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AudioRecorder.swift; sourceTree = "<group>"; };
		B1000016 /* TranscriptionService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TranscriptionService.swift; sourceTree = "<group>"; };
		B1000017 /* VoiceInputController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = VoiceInputController.swift; sourceTree = "<group>"; };
		B1000018 /* DictationHUD.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DictationHUD.swift; sourceTree = "<group>"; };
		B1000019 /* SystemAudioMuter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemAudioMuter.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		C1000001 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		D1000001 /* Root */ = {
			isa = PBXGroup;
			children = (
				D1000002 /* Popy */,
				D1000006 /* Products */,
			);
			sourceTree = "<group>";
		};
		D1000002 /* Popy */ = {
			isa = PBXGroup;
			children = (
				B1000001 /* main.swift */,
				B1000002 /* AppDelegate.swift */,
				D1000003 /* Models */,
				D1000004 /* Services */,
				D1000005 /* Resources */,
			);
			path = Popy;
			sourceTree = "<group>";
		};
		D1000003 /* Models */ = {
			isa = PBXGroup;
			children = (
				B1000003 /* ClipboardItem.swift */,
			);
			path = Models;
			sourceTree = "<group>";
		};
		D1000004 /* Services */ = {
			isa = PBXGroup;
			children = (
				B1000004 /* ClipboardManager.swift */,
				B1000005 /* LoginItemManager.swift */,
				B1000008 /* KeyboardSimulator.swift */,
				B1000009 /* PreferencesManager.swift */,
				B1000011 /* UpdateManager.swift */,
				B1000012 /* KeychainStore.swift */,
				B1000013 /* HotkeyManager.swift */,
				B1000014 /* FnKeyListener.swift */,
				B1000015 /* AudioRecorder.swift */,
				B1000016 /* TranscriptionService.swift */,
				B1000017 /* VoiceInputController.swift */,
				B1000018 /* DictationHUD.swift */,
				B1000019 /* SystemAudioMuter.swift */,
			);
			path = Services;
			sourceTree = "<group>";
		};
		D1000005 /* Resources */ = {
			isa = PBXGroup;
			children = (
				B1000006 /* Info.plist */,
				B1000007 /* Popy.entitlements */,
			);
			path = Resources;
			sourceTree = "<group>";
		};
		D1000006 /* Products */ = {
			isa = PBXGroup;
			children = (
				B1000010 /* Popy.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		E1000001 /* Popy */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = F1000003 /* Build configuration list for PBXNativeTarget "Popy" */;
			buildPhases = (
				E1000002 /* Sources */,
				C1000001 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Popy;
			productName = Popy;
			productReference = B1000010 /* Popy.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		F1000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastUpgradeCheck = 1420;
			};
			buildConfigurationList = F1000002 /* Build configuration list for PBXProject "Popy" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = D1000001 /* Root */;
			productRefGroup = D1000006 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				E1000001 /* Popy */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		E1000002 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A1000001 /* main.swift in Sources */,
				A1000002 /* AppDelegate.swift in Sources */,
				A1000003 /* ClipboardItem.swift in Sources */,
				A1000004 /* ClipboardManager.swift in Sources */,
				A1000005 /* LoginItemManager.swift in Sources */,
				A1000006 /* KeyboardSimulator.swift in Sources */,
				A1000007 /* PreferencesManager.swift in Sources */,
				A1000008 /* UpdateManager.swift in Sources */,
				A1000009 /* KeychainStore.swift in Sources */,
				A1000010 /* HotkeyManager.swift in Sources */,
				A1000011 /* FnKeyListener.swift in Sources */,
				A1000012 /* AudioRecorder.swift in Sources */,
				A1000013 /* TranscriptionService.swift in Sources */,
				A1000014 /* VoiceInputController.swift in Sources */,
				A1000015 /* DictationHUD.swift in Sources */,
				A1000016 /* SystemAudioMuter.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		G1000001 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MACOSX_DEPLOYMENT_TARGET = 12.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		G1000002 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				MACOSX_DEPLOYMENT_TARGET = 12.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		G1000003 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Popy/Resources/Popy.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				INFOPLIST_FILE = Popy/Resources/Info.plist;
				MACOSX_DEPLOYMENT_TARGET = 12.0;
				MARKETING_VERSION = 1.2.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.popy.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		G1000004 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_ENTITLEMENTS = Popy/Resources/Popy.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Manual;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				INFOPLIST_FILE = Popy/Resources/Info.plist;
				MACOSX_DEPLOYMENT_TARGET = 12.0;
				MARKETING_VERSION = 1.2.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.popy.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		F1000002 /* Build configuration list for PBXProject "Popy" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				G1000001 /* Debug */,
				G1000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		F1000003 /* Build configuration list for PBXNativeTarget "Popy" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				G1000003 /* Debug */,
				G1000004 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

	};
	rootObject = F1000001 /* Project object */;
}
PBXPROJ

info "Xcode project generated: Popy.xcodeproj"

# --------------------------------------------------
# 3. Generate xcscheme so xcodebuild finds the scheme
# --------------------------------------------------
step "Generating build scheme..."

mkdir -p Popy.xcodeproj/xcshareddata/xcschemes

cat > Popy.xcodeproj/xcshareddata/xcschemes/Popy.xcscheme << 'SCHEME'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1420"
   version = "1.3">
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
               BlueprintIdentifier = "E1000001"
               BuildableName = "Popy.app"
               BlueprintName = "Popy"
               ReferencedContainer = "container:Popy.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
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
            BlueprintIdentifier = "E1000001"
            BuildableName = "Popy.app"
            BlueprintName = "Popy"
            ReferencedContainer = "container:Popy.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
SCHEME

info "Build scheme generated"

# --------------------------------------------------
# 4. Build the project
# --------------------------------------------------
step "Building Popy (Release)..."

# Prefer a stable local signing identity over ad-hoc signing.
#
# Ad-hoc signatures make TCC store a *cdhash* requirement, which changes on
# every rebuild and silently revokes Accessibility — breaking paste while
# System Settings still shows the app as allowed. A certificate-based
# signature makes the requirement depend on the cert instead, so grants
# survive rebuilds. See create-signing-identity.sh.
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Popy Local Code Signing"; then
    SIGN_IDENTITY="Popy Local Code Signing"
    info "Signing with stable identity: $SIGN_IDENTITY"
else
    warn "No local signing identity — falling back to ad-hoc."
    echo "    Accessibility permission will reset on every rebuild."
    echo "    Fix permanently with: bash create-signing-identity.sh"
fi

if [ -n "${CI:-}" ]; then
    # In CI, show full output for debugging
    xcodebuild \
        -project Popy.xcodeproj \
        -scheme Popy \
        -configuration Release \
        -derivedDataPath build \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        build
else
    # Locally, filter to relevant lines
    xcodebuild \
        -project Popy.xcodeproj \
        -scheme Popy \
        -configuration Release \
        -derivedDataPath build \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        build 2>&1 | grep -E "(BUILD|error:|warning:|Compiling|Linking|✗)" || true
fi

BUILD_APP="build/Build/Products/Release/Popy.app"
if [ ! -d "$BUILD_APP" ]; then
    FOUND_APP=$(find build -name "Popy.app" -type d 2>/dev/null | head -1)
    if [ -n "$FOUND_APP" ]; then
        BUILD_APP="$FOUND_APP"
    else
        fail "Build failed. Run 'xcodebuild -project Popy.xcodeproj -scheme Popy -configuration Release -derivedDataPath build 2>&1' to see full errors."
    fi
fi

info "Build successful!"

# --------------------------------------------------
# 4b. Bundle the voice-input engine
# --------------------------------------------------
step "Bundling voice engine..."

WHISPER_BIN="$PROJECT_DIR/vendor/whisper-cli"
if [ -f "$WHISPER_BIN" ]; then
    mkdir -p "$BUILD_APP/Contents/Resources"
    cp "$WHISPER_BIN" "$BUILD_APP/Contents/Resources/whisper-cli"
    chmod +x "$BUILD_APP/Contents/Resources/whisper-cli"

    # Ad-hoc re-sign: copying an executable into the bundle after xcodebuild
    # invalidates the app's signature, which makes macOS refuse to launch it.
    codesign --force --deep --sign "$SIGN_IDENTITY" "$BUILD_APP" 2>/dev/null \
        && info "Bundled whisper-cli ($(lipo -archs "$WHISPER_BIN" 2>/dev/null)) and re-signed" \
        || warn "Bundled whisper-cli but re-signing failed"
else
    warn "vendor/whisper-cli not found — voice input will be disabled in this build."
    echo "    Build it with: bash build-whisper.sh"
fi

# --------------------------------------------------
# 5. Done
# --------------------------------------------------
echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "${BOLD}  Popy built successfully!${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
echo "  App:  $PROJECT_DIR/$BUILD_APP"
echo ""
echo "  Run now:              open \"$BUILD_APP\""
echo "  Install to Apps:      cp -R \"$BUILD_APP\" /Applications/"
echo "  Open in Xcode:        open Popy.xcodeproj"
echo "  Package as DMG:       bash package.sh"
echo ""
