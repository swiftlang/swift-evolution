# Enhancing the Platform Configuration Test Suite for Conditional Compilation Blocks

* Proposal: TBD
* Author: [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal introduces configuration tests to differentiate platform conditions in conditional compilation blocks.

*This proposal was first discussed on-list in the [\[Draft\] Introducing Build Configuration Tests	for Platform Conditions](http://thread.gmane.org/gmane.comp.lang.swift.evolution/12140/focus=12267) thread and then updated and re-pitched in [\[Draft\] Enhancing the Platform Configuration Test	Suite for Conditional Compilation Blocks](http://thread.gmane.org/gmane.comp.lang.swift.evolution/20849).*


## Motivation

Testing for platform conditions is a typical developer task. Although some built-in features like `CFByteOrderGetCurrent` exist, it seems a natural match for Swift to introduce conditional compilation blocks specific to common platform conditions. The tests in this proposal were community sourced from the Swift Evolution mailing list over several months. They represent common conditional compilation tests used in a variety of languages.

Swift currently supports the following conditional compilation tests, which are mostly defined in lib/Basic/LangOptions.cpp.

* The literals `true` and `false`
* The `os()` function that tests for `OSX, iOS, watchOS, tvOS, Linux, Windows, Android, and FreeBSD`
* The `arch()` function that tests for `x86_64, arm, arm64, i386, powerpc64, s390x, and powerpc64le`
* The `swift()` function that tests for specific Swift language releases, e.g. `swift(>=2.2)`

The following conditional compilation test has been accepted in [SE-0075](https://github.com/apple/swift-evolution/blob/master/proposals/0075-import-test.md) but not yet implemented:

* The `canImport()` function tests whether named modules can be imported.

**Note**: *The term "build configuration" [has been subsumed](https://github.com/apple/swift/commit/6272941c5cba9581a5ee93d92a6ee66e28c1bf13) by "conditional compilation block".*

## Detailed Design

This proposal introduces several platform condition tests for use in conditional compilation blocks: endianness, bitwidth, vendor, objc interop, and simulator.

### Endianness

Endianness refers to the byte order used in memory. This proposal exposes endian test conditions, promoting them from private underscored names to public developer-referenceable ones.

```swift
// Set the "_endian" platform condition.
  switch (Target.getArch()) {
  case llvm::Triple::ArchType::arm:
  case llvm::Triple::ArchType::thumb:
    addPlatformConditionValue("_endian", "little");
    break;
  case llvm::Triple::ArchType::aarch64:
    addPlatformConditionValue("_endian", "little");
    break;
  case llvm::Triple::ArchType::ppc64:
    addPlatformConditionValue("_endian", "big");
    break;
  case llvm::Triple::ArchType::ppc64le:
    addPlatformConditionValue("_endian", "little");
    break;
  case llvm::Triple::ArchType::x86:
    addPlatformConditionValue("_endian", "little");
    break;
  case llvm::Triple::ArchType::x86_64:
    addPlatformConditionValue("_endian", "little");
    break;
  case llvm::Triple::ArchType::systemz:
    addPlatformConditionValue("_endian", "big");
    break;
  default:
    llvm_unreachable("undefined architecture endianness");
```

Under this proposal `_endian` is renamed to `endian` and made a public API.

Use:

```swift
#if endian(big) 
    // Big endian code
#endif
```

### Bitwidth

Bitwidth describes the number of bits used to represent a number, typically Int. This proposal introduces a bitwidth test with two options: 32 and 64. 

Use:

```swift
#if bitwidth(64) 
    // 64-bit code
#endif
```

List members briefly discussed whether it was better to measure pointer width or the size of Int. William Dillon suggested renaming bitwidth to either `intwidth` or `intsize`. Brent Royal-Gordon suggests `intbits`. Alternatives include `bits` and `bitsize`. This proposal avoids `wordbits` because of the way, for example, Intel ends up doing “dword”, “qword”, and so forth for backwards compatibility.

### Vendor

A vendor describes the corporate or other originator of a platform. This proposal introduces a test that returns platform vendor, with one option at this time: `Apple`. Apple deployment provides an umbrella case for wide range of coding norms that may not be available on non-Apple platforms. This "family of targets" provides a simpler test than looking for specific modules or listing individual operating systems, both of which provide fragile approaches to this requirement.

This call would be supported in Swift's source-code by the existing private `getVendor()` used in lib/Basic/LangOptions.cpp.

Use:

```swift
#if vendor(Apple) 
    // Code specific to Apple platform deployment
#endif
```

### Interop

Swift's Objective-C compatibility enables developers to build mix-and-match projects with a mixed-language codebase. This proposal introduces a test to determine whether the Objective-C runtime is available for use. This test uses only one option, `objc`, although it could potentially expand to other scenarios, such as jvm, clr, and C++. 

```c++
if (EnableObjCInterop)
    addPlatformConditionValue("_runtime", "_ObjC");
else
    addPlatformConditionValue("_runtime", "_Native")
```

Use:

```swift
#if interop(objc) 
    // Code that depends on Objective-C
#endif
```


### Simulator Conditions

Xcode simulators enable developers to test code on a wide range of platforms without directly using physical devices. A simulator may not offer the full suite of modules available with device deployment or provide device-only hardware hooks like GPS. This proposal introduces a test for simulator platform conditions, enabling developers to omit references to unsupported features. It offers two options: `simulator` and `device`.

```c++
bool swift::tripleIsAnySimulator(const llvm::Triple &triple) {
    return tripleIsiOSSimulator(triple) ||
    tripleIsWatchSimulator(triple) ||
    tripleIsAppleTVSimulator(triple);
}
```

This proposal uses a `targetEnvironment` test as `target` or `platform` are too valuable burn on this test.

Use:

```
#if targetEnvironment(simulator)
    // Code specific to simulator use
#endif
```

This condition test would reduce the fragility and special casing currently in use: 

```swift
#if (arch(i386) || arch(x86_64)) && os(iOS) 
    print("Probably simulator")
#endif
```

## Impact on Existing Code

This proposal is additive and should not affect existing code. Some developers may refactor code as in the case of the simulator/device test.

## Alternatives Considered

Not accepting this proposal