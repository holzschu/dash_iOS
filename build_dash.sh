#! /bin/sh

OSX_SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
IOS_SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDKROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)

make distclean
./configure CC=clang CXX=clang++ \
	CC_FOR_BUILD="clang -isysroot ${OSX_SDKROOT} -DJOBS=0" \
	CFLAGS="-arch arm64 -miphoneos-version-min=14.0 -isysroot ${IOS_SDKROOT} -DJOBS=0 -fembed-bitcode -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	CPPFLAGS="-arch arm64 -miphoneos-version-min=14.0 -isysroot ${IOS_SDKROOT} -DJOBS=0 -fembed-bitcode -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	CXXFLAGS="-arch arm64 -miphoneos-version-min=14.0 -isysroot ${IOS_SDKROOT} -DJOBS=0 -fembed-bitcode -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	LDFLAGS="-arch arm64 -miphoneos-version-min=14.0 -isysroot ${IOS_SDKROOT} -DJOBS=0 -fembed-bitcode -dynamiclib -F ${PWD}/ios_system.xcframework/ios-arm64 -framework ios_system" \
	--build=x86_64-apple-darwin --host=armv8-apple-darwin cross_compiling=yes --with-libedit 
make -j4 --quiet

for binary in dash dashA dashB dashC dashD dashE
do 
  FRAMEWORK_DIR=build/Release-iphoneos/$binary.framework
  rm -rf ${FRAMEWORK_DIR}
  mkdir -p ${FRAMEWORK_DIR}
  mkdir -p ${FRAMEWORK_DIR}/Headers
  cp src/dash ${FRAMEWORK_DIR}/$binary
  cp basic_Info.plist ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleExecutable -string $binary ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleName -string $binary ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleIdentifier -string Nicolas-Holzschuch.$binary  ${FRAMEWORK_DIR}/Info.plist
  install_name_tool -id @rpath/$binary.framework/$binary   ${FRAMEWORK_DIR}/$binary
done

make distclean
./configure CC=clang CXX=clang++ \
	CC_FOR_BUILD="clang -isysroot ${OSX_SDKROOT} -DJOBS=0" \
	CFLAGS="-arch x86_64 -miphonesimulator-version-min=14.0 -isysroot ${SIM_SDKROOT} -fembed-bitcode -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	CPPFLAGS="-arch x86_64 -miphonesimulator-version-min=14.0 -isysroot ${SIM_SDKROOT} -fembed-bitcode -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	CXXFLAGS="-arch x86_64 -miphonesimulator-version-min=14.0 -isysroot ${SIM_SDKROOT} -fembed-bitcode -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -I${PWD}" \
	LDFLAGS="-arch x86_64 -miphonesimulator-version-min=14.0 -isysroot ${SIM_SDKROOT} -fembed-bitcode -dynamiclib -F ${PWD}/ios_system.xcframework/ios-arm64_x86_64-simulator -framework ios_system" \
	--build=x86_64-apple-darwin --host=x86_64-apple-darwin cross_compiling=yes --with-libedit
make -j4 --quiet

for binary in dash dashA dashB dashC dashD dashE
do 
  FRAMEWORK_DIR=build/Release-iphonesimulator/$binary.framework
  rm -rf ${FRAMEWORK_DIR}
  mkdir -p ${FRAMEWORK_DIR}
  mkdir -p ${FRAMEWORK_DIR}/Headers
  cp src/dash ${FRAMEWORK_DIR}/$binary
  cp basic_Info_Simulator.plist ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleExecutable -string $binary ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleName -string $binary ${FRAMEWORK_DIR}/Info.plist
  plutil -replace CFBundleIdentifier -string Nicolas-Holzschuch.$binary  ${FRAMEWORK_DIR}/Info.plist
  install_name_tool -id @rpath/$binary.framework/$binary   ${FRAMEWORK_DIR}/$binary
done

# then, merge them into XCframeworks:
for framework in dash dashA dashB dashC dashD dashE
do
   rm -rf $framework.xcframework
   xcodebuild -create-xcframework -framework build/Release-iphoneos/$framework.framework -framework build/Release-iphonesimulator/$framework.framework -output $framework.xcframework
done
