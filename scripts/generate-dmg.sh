# This script requires create-dmg to be installed from https://github.com/sindresorhus/create-dmg
BUILD_CONFIG=$1
OVERRIDE_VERSION=$2

fail()
{
	echo "$1" 1>&2
	exit 1
}

if [ "$BUILD_CONFIG" != "Debug" ] && [ "$BUILD_CONFIG" != "Release" ]; then
  fail "Invalid build configuration - expected 'Debug' or 'Release'"
fi

BUILD_ROOT=$PWD/build
SOURCE_ROOT=$PWD
BUILD_FOLDER=$BUILD_ROOT/build-$BUILD_CONFIG
INSTALLER_FOLDER=$BUILD_ROOT/installer-$BUILD_CONFIG

# Use override version if provided, otherwise read from version.txt
if [ "$OVERRIDE_VERSION" != "" ]; then
  VERSION="$OVERRIDE_VERSION"
else
  VERSION=`cat $SOURCE_ROOT/app/version.txt`
fi

if [ "$SIGNING_PROVIDER_SHORTNAME" == "" ]; then
  SIGNING_PROVIDER_SHORTNAME=$SIGNING_IDENTITY
fi
if [ "$SIGNING_IDENTITY" == "" ]; then
  SIGNING_IDENTITY=$SIGNING_PROVIDER_SHORTNAME
fi

[ "$SIGNING_IDENTITY" == "" ] || git diff-index --quiet HEAD -- || fail "Signed release builds must not have unstaged changes!"

# Locate tools
QMAKE_CMD="qmake"
command -v qmake6 >/dev/null 2>&1 && QMAKE_CMD="qmake6"

MOC_CMD="moc"
if [ -n "$Qt6_DIR" ] && [ -x "$Qt6_DIR/libexec/moc" ]; then
  MOC_CMD="$Qt6_DIR/libexec/moc"
elif [ -n "$Qt6_DIR" ] && [ -x "$Qt6_DIR/bin/moc" ]; then
  MOC_CMD="$Qt6_DIR/bin/moc"
elif command -v moc-qt6 >/dev/null 2>&1; then
  MOC_CMD="moc-qt6"
fi

MACDEPLOYQT_CMD="macdeployqt"
if [ -n "$Qt6_DIR" ] && [ -x "$Qt6_DIR/bin/macdeployqt" ]; then
  MACDEPLOYQT_CMD="$Qt6_DIR/bin/macdeployqt"
fi

echo Pre-generating inline MOC files
"$MOC_CMD" "$SOURCE_ROOT/app/backend/computermanager.cpp" -o "$SOURCE_ROOT/app/backend/computermanager.moc" || true
"$MOC_CMD" "$SOURCE_ROOT/app/backend/boxartmanager.cpp" -o "$SOURCE_ROOT/app/backend/boxartmanager.moc" || true
"$MOC_CMD" "$SOURCE_ROOT/app/gui/computermodel.cpp" -o "$SOURCE_ROOT/app/gui/computermodel.moc" || true

echo Cleaning output directories
rm -rf $BUILD_FOLDER
rm -rf $INSTALLER_FOLDER
mkdir -p $BUILD_ROOT
mkdir -p $BUILD_FOLDER
mkdir -p $INSTALLER_FOLDER

echo Configuring the project
pushd $BUILD_FOLDER
$QMAKE_CMD "$SOURCE_ROOT/artemis.pro" \
  CONFIG+=release \
  CONFIG+=sdk_no_version_check \
  QMAKE_MACOSX_DEPLOYMENT_TARGET=14.0 \
  QMAKE_APPLE_DEVICE_ARCHS="x86_64 arm64" \
  QMAKE_CXXFLAGS+="-Wno-implicit-function-declaration -Wno-error=implicit-function-declaration" \
  QMAKE_CFLAGS+="-Wno-implicit-function-declaration -Wno-error=implicit-function-declaration" \
  || fail "Qmake failed!"
popd

echo Compiling Artemis in $BUILD_CONFIG configuration
pushd $BUILD_FOLDER
make -j$(sysctl -n hw.logicalcpu) $(echo "$BUILD_CONFIG" | tr '[:upper:]' '[:lower:]') || fail "Make failed!"
popd

echo Saving dSYM file
pushd $BUILD_FOLDER
dsymutil app/Artemis.app/Contents/MacOS/Artemis -o Artemis-$VERSION.dsym || fail "dSYM creation failed!"
cp -R Artemis-$VERSION.dsym $INSTALLER_FOLDER || fail "dSYM copy failed!"
popd

echo Creating app bundle
EXTRA_ARGS=
if [ "$BUILD_CONFIG" == "Debug" ]; then EXTRA_ARGS="$EXTRA_ARGS -use-debug-libs"; fi
echo Extra deployment arguments: $EXTRA_ARGS
$MACDEPLOYQT_CMD $BUILD_FOLDER/app/Artemis.app $EXTRA_ARGS -qmldir=$SOURCE_ROOT/app/gui -appstore-compliant || fail "macdeployqt failed!"
echo Removing dSYM files from app bundle
find $BUILD_FOLDER/app/Artemis.app/ -name '*.dSYM' | xargs rm -rf

if [ "$SIGNING_IDENTITY" != "" ]; then
  echo Signing app bundle with entitlements
  codesign --force --deep --options runtime --timestamp --entitlements "$SOURCE_ROOT/scripts/entitlements.plist" --sign "$SIGNING_IDENTITY" $BUILD_FOLDER/app/Artemis.app || fail "Signing failed!"
fi

echo Creating DMG
DMG_NAME="Artemis-$VERSION.dmg"

# Create a properly formatted DMG with custom background and icons
if [ "$SIGNING_IDENTITY" != "" ]; then
  echo "Creating signed DMG with custom styling..."
  create-dmg \
    --volname "Artemis" \
    --volicon "$SOURCE_ROOT/app/artemis.icns" \
    --background "$SOURCE_ROOT/scripts/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "Artemis.app" 180 170 \
    --hide-extension "Artemis.app" \
    --app-drop-link 480 170 \
    --no-internet-enable \
    --identity="$SIGNING_IDENTITY" \
    "$INSTALLER_FOLDER/$DMG_NAME" \
    "$BUILD_FOLDER/app/Artemis.app" || {
      echo "create-dmg failed! Trying fallback method..."
      # Fallback to basic DMG creation if fancy DMG fails
      hdiutil create -volname "Artemis" -srcfolder "$BUILD_FOLDER/app/Artemis.app" -ov -format UDZO "$INSTALLER_FOLDER/$DMG_NAME"
      if [ "$?" -ne 0 ]; then
        fail "DMG creation failed even with fallback method!"
      fi
      # Sign the fallback DMG if we have signing identity
      if [ "$SIGNING_IDENTITY" != "" ]; then
        codesign --force --sign "$SIGNING_IDENTITY" "$INSTALLER_FOLDER/$DMG_NAME" || echo "Warning: DMG signing failed but DMG was created"
      fi
    }
else
  echo "Creating unsigned DMG with custom styling..."
  create-dmg \
    --volname "Artemis" \
    --volicon "$SOURCE_ROOT/app/artemis.icns" \
    --background "$SOURCE_ROOT/scripts/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "Artemis.app" 180 170 \
    --hide-extension "Artemis.app" \
    --app-drop-link 480 170 \
    --no-internet-enable \
    "$INSTALLER_FOLDER/$DMG_NAME" \
    "$BUILD_FOLDER/app/Artemis.app" || {
      echo "create-dmg failed! Trying fallback method..."
      # Fallback to basic DMG creation if fancy DMG fails
      hdiutil create -volname "Artemis" -srcfolder "$BUILD_FOLDER/app/Artemis.app" -ov -format UDZO "$INSTALLER_FOLDER/$DMG_NAME"
      if [ "$?" -ne 0 ]; then
        fail "DMG creation failed even with fallback method!"
      fi
    }
fi

if [ "$NOTARY_KEYCHAIN_PROFILE" != "" ]; then
  echo Uploading to App Notary service
  xcrun notarytool submit --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait "$INSTALLER_FOLDER/$DMG_NAME" || fail "Notary submission failed"

  echo Stapling notary ticket to DMG
  xcrun stapler staple -v "$INSTALLER_FOLDER/$DMG_NAME" || fail "Notary ticket stapling failed!"
fi

# Create build info file
cat > $INSTALLER_FOLDER/build_info_macos.txt << EOF
Artemis Desktop macOS Universal Development Build
Version: $VERSION
Architecture: Universal (x86_64 + arm64)
Build Configuration: $BUILD_CONFIG
Built: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Installation Notes:
- This is a universal binary that works on both Intel and Apple Silicon Macs
- If macOS says the app is "damaged", run: xattr -cr Artemis.app
- Or go to System Preferences > Security & Privacy and allow the app
- This is a development build and may trigger Gatekeeper warnings
EOF

echo Build successful
