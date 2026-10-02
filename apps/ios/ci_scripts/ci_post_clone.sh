#!/bin/sh
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

xcodegen --version
xcodegen generate --spec "${CI_PRIMARY_REPOSITORY_PATH}/apps/ios/project.yml"
