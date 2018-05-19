#!/bin/bash

carthage bootstrap --platform macOS
mkdir -p build
xcodebuild -configuration Release clean build SYMROOT=build
echo Build output:
(cd build/Release; pwd)
