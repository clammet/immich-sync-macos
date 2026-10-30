set -eu
cd "$(dirname "$0")/.."
swift build
swift test
python3 scripts/generate-project.py
plutil -lint Config/App-Info.plist Config/Extension-Info.plist Config/App.entitlements Config/Extension.entitlements ImmichSync.xcodeproj/project.pbxproj
