#!/usr/bin/env bash

set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
test -f MacPhoneInput.xcodeproj/project.pbxproj
