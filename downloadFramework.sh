#! /bin/sh

curl -fOL https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_error.h || exit 1
curl -fOL https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_system.xcframework.zip || exit 1

rm -rf ios_system.xcframework 
unzip -q ios_system.xcframework.zip

