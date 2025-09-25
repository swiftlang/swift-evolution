# Binary Static Library Dependencies

* Proposal: [SE-0482](0482-swiftpm-static-library-binary-target-non-apple-platforms.md)
* Authors: [Daniel Grumberg](https://github.com/daniel-grumberg), [Max Desiatov](https://github.com/MaxDesiatov), [Franz Busch](https://github.com/FranzBusch)
* Review Manager: [Kuba Mracek](https://github.com/kubamracek)
* Status: **Implemented (Swift 6.2)**
* Implementation: [swiftlang/swift-package-manager#8639](https://github.com/swiftlang/swift-package-manager/pull/8639) [swiftlang/swift-package-manager#8741](https://github.com/swiftlang/swift-package-manager/pull/8741)
* Review: ([discussion](https://forums.swift.org/t/se-0482-binary-static-library-dependencies/79634)) ([pitch](https://forums.swift.org/t/pitch-swiftpm-support-for-binary-static-library-dependencies/78619)) ([acceptance](https://forums.swift.org/t/accepted-se-0482-binary-static-library-dependencies/80042))
* Bugs: [Swift Package Manger Issue](https://github.com/swiftlang/swift-package-manager/issues/7035)

## Introduction

Swift continues to grow as a cross-platform language supporting a wide variety of use cases from [programming embedded device](https://www.swift.org/blog/embedded-swift-examples/) to [server-side development](https://www.swift.org/documentation/server/) across a multitude of [operating systems](https://www.swift.org/documentation/articles/static-linux-getting-started.html).
However, currently SwiftPM supports linking against binary dependencies on Apple platforms only.
This proposal aims to make it possible to provide static library dependencies exposing a C interface on non-Apple platforms that depend only on the standard C library.
The scope of this proposal is C libraries only, distributing Swift libraries has additional challenges (see [Future directions](#future-directions).

## Motivation

The Swift Package Manager’s [`binaryTarget` type](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md) lets packages vend libraries that either cannot be built in Swift Package Manager for technical reasons,
or for which the source code cannot be published for legal or other reasons.

In the current version of SwiftPM, binary targets support the following:

* Libraries in an Xcode-oriented format called XCFramework, and only for Apple platforms, introduced in [SE-0272](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md).
* Executables through the use of artifact bundles introduced in [SE-0305](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md).

We aim here to bring a subset of the XCFramework capabilities to non-Apple platforms in a safe way.

While this proposal is specifically focused on binary static library dependencies without unexpected unresolved external symbols on non-Apple platforms,
it tries to do so in a way that will not prevent broader future support for static libraries and dynamically linked libraries.

## Proposed solution

This proposal extends artifact bundles introduced by [SE-0305](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md) to include a new kind of artifact type to represent a binary library dependency: `staticLibrary`.
The artifact manifest would encode the following information for each variant:

* The static library to pass to the linker.
  On Apple and Linux platforms, this would be `.a` files and on Windows it would be a `.lib` file.
* Enough information to be able to use the library's API in the packages source code, 
  i.e., headers and module maps for libraries exporting a C-based interface.

Additionally, we propose the addition of an auditing tool that can validate the library artifact is safe to use across the Linux-based platforms supported by the Swift project.
Such a tool would ensure that people do not accidentally distribute artifacts that require dependencies that are not met on the various deployment platforms.
However when an artifact isn't widely consumed and all dependent packages are known,
artifact vendors can provide artifacts with dependencies on other C libraries provided that each client target depends explicitly on all required dependencies of the artifact.

## Detailed design

This section describes the changes to artifact bundle manifests in detail, the semantic impact of the changes on SwiftPM's build infrastructure, and describes the operation of the auditing tool.

### Artifact Manifest Semantics

The artifact manifest JSON format for a static library is described below:

```json
{
    "schemaVersion": "1.0",
    "artifacts": {
        "<identifier>": {
            "version": "<version number>",
            "type": "staticLibrary",
            "variants": [
                {
                    "path": "<relative-path-to-library-file>",
                    "supportedTriples": ["<triple1>", ... ],
                    "staticLibraryMetadata": {
                        "headerPaths": ["<relative-path-to-header-directory-1>, ...],
                        "moduleMapPath": "<path-to-module-map>"
                    }
                },
                ...
            ]
        },
        ...
    }
}

```

The additions are:

* The `staticLibrary` artifact `type` that indicates this binary artifact is not an executable but rather a static library to link against.
* The `headerPaths` field specifies directory paths relative to the root of the artifact bundle that contain the header interfaces to the static library.
  These are forwarded along to the swift compiler (or the C compiler) using the usual search path arguments.
* The optional `moduleMapPath` field specifies the path relative to the root of the artifact bundle that contains a custom module map to use if the header paths do not contain the module definitions or to provide custom overrides.
  This field is required if the library's API is to be imported into Swift code.

As with executable binary artifacts, the `path` field represents the relative path to the binary from the root of the artifact bundle,
and the `supportedTriples` field provides information about the target triples supported by this variant.

An example artifact might look like:

```json
{
    "schemaVersion": "1.0",
    "artifacts": {
        "example": {
            "type": "staticLibrary",
            "version": "1.0.0",
            "variants": [
                {
                    "path": "libExample.a",
                    "supportedTriples": ["aarch64-unknown-linux-gnu"],
                    "staticLibraryMetadata": {
                          "headerPaths": ["include"],
                          "moduleMapPath": "include/example.modulemap"
                    }
                }
            ]
        }
    }
}
```

### Auditing tool

Without proper auditing it would be very easy to provide binary static library artifacts that call into unresolved external symbols that are not available on the runtime platform, e.g., due to missing linkage to a system dynamic library.

We propose the introduction of a new tool that can validate the "safety" of a binary library artifact across the platforms it supports and the corresponding runtime environment.

In this proposal we restrict ourselves to static libraries that do not have any external dependencies beyond the C standard library and runtime.
To achieve this we need to be able to detect validate this property across the three object file formats used in static libraries on our supported platforms: [Mach-O](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/CodeFootprint/Articles/MachOOverview.html#//apple_ref/doc/uid/20001860-BAJGJEJC) on Apple platforms, [ELF](https://refspecs.linuxfoundation.org/elf/elf.pdf) on Linux-based platforms, and [COFF](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format) on Windows.
All three formats express references to external symbols as _relocations_ which reside in a single section of each object file.

We propose adding the `llvm-objdump` to the toolchain to provide the capability to inspect relocations across all three supported object file formats. The tool would use `llvm-objdump` every object file in the static library and construct a complete list of symbols defined and referenced across the entire library.
Additionally, the tool would construct a simple C compiler invocation to derive to generate a default linker invocation.
This would be used to derive the libraries linked by default in a C program, these libraries would then be scanned to contribute to the list of defined symbols.
The tool would then check that the referenced symbols list is a subset of the set of defined symbols and emit an error otherwise.

This would be sufficient to guarantee that all symbols from the static library would be available at runtime for statically linked executables or for ones running on the build host. 
To ensure maximum runtime compatibility we would also provide a Linux-based Docker image that uses the oldest supported `glibc` for a given Swift version.
As `glibc` is backwards compatible, a container running the audit on a given static library would ensure that the version of `glibc` on any runtime platform would be compatible with the binary artifact.
This strategy as been successfully employed in the Python community with [`manylinux`](https://peps.python.org/pep-0513/).

## Security

This proposal brings the security implications outlined in [SE-0272](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md#security) to non-Apple platforms, 
namely that a malicious attacker having access to both the server hosting the artifact and the git repository that vends the Package Manifest could provide a malicious library. 
Users should exercise caution when onboarding binary dependencies.

## Impact on existing packages

No current package should be affected by this change since this is only an additive change in enabling SwiftPM to use binary target library dependencies on non-Apple platforms.

## Future directions

### Support Swift static libraries

To do this we would extend the static library binary artifact manifest to provide a `.swiftinterface` file that can be consumed by the Swift compiler to import the Swift APIs.
Additionally we would extend the auditing tool to validate the usage of Swift standard library and runtime symbols, e.g., from `libSwiftCore`.

### Extend binary compatibility guarantees

This proposal limits itself to providing facilities for binary compatibility only with the C standard library and runtime.
In the future we could provide a system to allow binary artifact distributors to specify additional linkage dependencies for their binary artifacts.
These would be used to customize the operation of the audit tool and perform automatic linking of them in any client target that depends on the binary artifact, in the same way [CMake](https://cmake.org/cmake/help/v4.0/prop_tgt/INTERFACE_LINK_LIBRARIES.html) propagates link dependencies transitively.

### Add support for dynamically linked dependencies

On Windows dynamic linking requires an _import library_ which is a small static library that contains stubs for symbols exported by the dynamic library.
These stubs are roughly equivalent to a PLT entry in an ELF executable, but are generated during the build of the dynamic library and must be provided to clients of the library for linking purposes.
Similarly on Linux and Apple platforms binary artifact maintainers may wish to provide a dynamic library stub to improve link performance.
To support these use cases the library binary artifact manifest schema could be extended to provide facilities to provide both a link-time and runtime dependency.
