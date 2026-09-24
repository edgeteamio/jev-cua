# Source this to build with the Xcode toolchain invoked directly. The `swift`/`xcrun` shims in
# /usr/bin refuse to run until the Xcode license is accepted, and the Command Line Tools'
# SwiftPM manifest library is internally inconsistent on this Mac (module interfaces newer
# than the dylib), so neither shim path works. The toolchain binaries themselves are fine.
XC=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR="$XC"
export SDKROOT="$XC/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
export TOOLCHAIN_BIN="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin"
SWIFT="$TOOLCHAIN_BIN/swift"
# Test bundles load XCTest and Testing from the platform, which the shim would normally supply.
export DYLD_FRAMEWORK_PATH="$XC/Platforms/MacOSX.platform/Developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$XC/Platforms/MacOSX.platform/Developer/usr/lib"
