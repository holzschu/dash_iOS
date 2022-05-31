#! /bin/sh

curl -OL https://github.com/holzschu/ios_system/releases/download/v3.0.1/ios_error.h
curl -OL https://github.com/holzschu/ios_system/releases/download/v3.0.1/ios_system.xcframework.zip

rm -rf ios_system.xcframework 
unzip -q ios_system.xcframework.zip

