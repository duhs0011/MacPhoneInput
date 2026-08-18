#!/usr/bin/env bash

set -euo pipefail

PROJECT="MacPhoneInput.xcodeproj"
SCHEME="MacPhoneInput"
DERIVED_DATA=".build/DerivedData"

xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
