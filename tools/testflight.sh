#!/bin/zsh
# Archive the iPhone app (with the Watch app) and upload it to TestFlight.
#   tools/testflight.sh            # archive + upload
#   tools/testflight.sh archive    # archive only
# Needs: the App Store Connect app record for com.kellamadams.tennisbuddy, and Xcode signed in to team B8QLYC5T9U.
# App Store Connect bumps the build number automatically (manageAppVersionAndBuildNumber).
set -euo pipefail
cd "$(dirname "$0")/../apple"
ARCHIVE="${TMPDIR:-/tmp}/TennisBuddy-iOS.xcarchive"

if [[ "${1:-}" != "upload" ]]; then
  xcodegen generate
  xcodebuild archive -project TennisBuddy.xcodeproj -scheme TennisBuddy-iOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation
fi
[[ "${1:-}" == "archive" ]] && { echo "Archived to $ARCHIVE"; exit 0; }

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions-TestFlight.plist \
  -exportPath "${TMPDIR:-/tmp}/TennisBuddy-export" -allowProvisioningUpdates
echo "Uploaded. It shows up in App Store Connect → TestFlight after processing (10–30 min)."
