#!/bin/sh

VERSIONS_FILE="Tuist/ProjectDescriptionHelpers/Project+Version.swift"

echo "// This file is auto-generated. Any changes will be lost.\n" > $VERSIONS_FILE
echo "import ProjectDescription\n" >> $VERSIONS_FILE
echo "public extension Project {" >> $VERSIONS_FILE

GIT_COMMITS_COUNT=$(git rev-list --count HEAD)
echo "    /// Current project build number based on git commits count." >> $VERSIONS_FILE
echo "    static let currentBuildNumber: String = \"${GIT_COMMITS_COUNT}\"" >> $VERSIONS_FILE
echo "" >> $VERSIONS_FILE

GIT_LAST_VERSION_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")

CURRENT_MAJOR_VERSION=$(echo $GIT_LAST_VERSION_TAG | cut -d '.' -f 1)
CURRENT_MINOR_VERSION=$(echo $GIT_LAST_VERSION_TAG | cut -d '.' -f 2)
CURRENT_PATCH_VERSION=$(echo $GIT_LAST_VERSION_TAG | cut -d '.' -f 3)

CURRENT_PATCH_VERSION=$((CURRENT_PATCH_VERSION + 1))

echo "    /// Current project version based on the latest git tag." >> $VERSIONS_FILE
echo "    static let currentVersion: String = \"${CURRENT_MAJOR_VERSION}.${CURRENT_MINOR_VERSION}.${CURRENT_PATCH_VERSION}\"" >> $VERSIONS_FILE
echo "}" >> $VERSIONS_FILE
