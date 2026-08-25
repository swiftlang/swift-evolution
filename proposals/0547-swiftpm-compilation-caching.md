# SwiftPM Support for Compilation Caching

* Proposal: [SE-0547](0547-swiftpm-compilation-caching.md)
* Authors: [Owen Voorhees](https://github.com/owenv)
* Review Manager: [Mishal Shah](https://github.com/shahmishal)
* Status: **Active Review (August 25th...September 1st, 2026)**
* Implementation: [PR #10246](https://github.com/swiftlang/swift-package-manager/pull/10246)
* Review: ([pitch](https://forums.swift.org/t/pitch-compilation-caching-support-in-swiftpm/88079)) ([review](https://forums.swift.org/t/se-0547-swiftpm-support-for-compilation-caching/89191))

## Introduction

The Swift and Clang compilers have existing support for leveraging a CAS (Content Addressable Store) to cache compilation outputs and replay them in subsequent builds. This proposal introduces support for configuring compilation caching in SwiftPM on a per-build, per-package, or global basis. 

## Motivation

During many common workflows, the build of a package may repeat a compile task from an older build with identical inputs. For example:
- Locally switching between two different branches, incrementally rebuilding large parts of the package each time
- Building the same code across several git worktrees, each of which starts with an empty build folder
- Repeatedly building the same code in a CI environment which performs a clean build each time it's invoked

Recompiling sources in these cases is wasteful and reduces development velocity. Furthermore, these are all workflows which do not benefit from traditional incremental builds, which rely on timestamp-based invalidation and reusing intermediates in the build directory. Compilation caching is able to accelerate these workflows by quickly replaying the results of a previous compilation after dependency scanning computes a content-based cache key derived from its inputs (sources, compiler command lines, imported modules, etc.). For example, on a 12-core machine a fully cached clean debug build of SwiftPM is 68% faster than one with an empty cache, a similar build of SwiftSyntax is 75% faster, and a build of Vapor is 67% faster.

Effectively leveraging compilation caching often requires configuring parameters like the cache location, size, and eviction policy to support a particular use case, like local builds or remote CI. As the build system driving the compilers, SwiftPM is in the best position to manage this configuration and expose it to the end user.

## Proposed solution

SwiftPM provides three ways to configure compilation caching:

- Global configuration, via `swift package build-cache configure` using the `--global` modifier. This is stored in a `build-cache-config.json` file in SwiftPM's shared configuration directory (`~/Library/org.swift.swiftpm/configuration/` on macOS, `~/.swiftpm/configuration/` on Linux, etc.).
- Package-local configuration via `swift package build-cache configure`. This is stored in a `build-cache-config.json` file in the package's `.swiftpm/configuration/` directory. This file is included in the default `.gitignore` for new packages created using `swift package init`.
- Per-build configuration via command line options.

Each configuration mechanism has higher precedence compared to the previous. Values set at each level are additive. For example, a user may choose to enable caching globally, and then override only the cache path per-package.

## Detailed design

All three mechanisms support configuring:

- Whether caching is enabled or disabled. By default, caching is opt-in. It is set per-build with `--enable-build-caching`/`--disable-build-caching`, or persistently with `swift package build-cache configure --enable-caching`/`--disable-caching`.
- Enablement of prefix mapping, which canonicalizes paths on compiler command lines and allows multiple instances of a package at different file paths to share cached outputs. By default, enabling caching also enables prefix mapping. It is configured per-build with `--enable-build-cache-prefix-mapping`/`--disable-build-cache-prefix-mapping`, or persistently with `swift package build-cache configure --enable-prefix-mapping`/`--disable-prefix-mapping`.
- The path to the build cache. If caching is enabled but no path is specified, the build cache uses a subdirectory of SwiftPM's default global cache directory (~/Library/Caches/org.swift.swiftpm/ on macOS, ~/.cache/org.swift.swiftpm/ on Linux, etc.). It is set per-build with `--build-cache-path`, or persistently with `swift package build-cache configure --path`.
- A size limit, specified either in absolute terms (e.g. 50G) or as a percentage of available disk space (e.g. 10%). At the end of a build, entries will be evicted from the cache if this limit is exceeded. It is set per-build with `--build-cache-size-limit`, or persistently with `swift package build-cache configure --size-limit`. The default size limit is implementation-defined.
- Enablement of diagnostic remarks which emit information about cache hits and misses in the build log. By default, diagnostic remarks are disabled. They are configurable per-build with `--enable-build-cache-diagnostic-remarks`/`--disable-build-cache-diagnostic-remarks`, or persistently with `swift package build-cache configure --enable-diagnostic-remarks`/`--disable-diagnostic-remarks`.
- The path to a plugin implementing the [LLVM CAS Plugin API](https://github.com/swiftlang/llvm-project/tree/next/llvm/include/llvm-c/CAS), and optionally a unix domain socket path for a [gRPC remote caching service](https://github.com/swiftlang/llvm-project/tree/next/llvm/lib/RemoteCachingService/RemoteCacheProto) to provide to the plugin. These options can be used to integrate SwiftPM build caching with a custom local or distributed cache implementation. The plugin path is set per-build with `--build-cache-plugin-path`, or persistently with `swift package build-cache configure --plugin-path`. The remote service path is set per-build with `--build-cache-remote-service-path`, or persistently with `swift package build-cache configure --remote-service-path`. On macOS, SwiftPM will default to using the CAS plugin from an Xcode toolchain if it is available, allowing the user to specify only a remote service path. A plugin is not required to take advantage of compilation caching. If none is available or provided, the LLVM on-disk CAS implementation will be used.

In SwiftPM's user-facing interface, we consistently use the terminology "build cache" instead of "compilation cache". This is intended to future proof these options so that they could evolve naturally in the future to configure CAS-based caching of additional task types.

In addition to `configure`, the `swift package build-cache` command provides the following subcommands:

- `swift package build-cache get-configuration` prints the effective cache configuration for the current package in an implementation-defined human-readable format.
- `swift package build-cache reset-configuration` removes all stored configuration options, returning them to their defaults. Like `configure`, it operates on the package-local configuration by default, or on the global configuration when passed `--global`.
- `swift package build-cache info` reports information about the cache, like its current size, in an implementation-defined human-readable format.
- `swift package build-cache clean` deletes the on-disk build cache for the current package.

## Security

The build cache stores and retrieves compiler outputs from a local (or, via the specified service/plugin, remote) cache. As a result, an adversary with the ability to modify the cache could tamper with compiler outputs and the resulting build artifacts, similar to the capabilities of an adversary with the ability to modify the original source code. Users of build caching in a shared environment like a CI node should keep this in mind when configuring permissions and assessing the risk of adopting the feature.

## Impact on existing packages

None. Compilation caching is an opt in build performance optimization which should not impact outputs. 

## Alternatives considered

### Only expose command line options

We could expose compilation caching purely through command line flags to simplify the design by eliminating the `swift package build-cache configure` command. This would likely work well in CI environments, but would limit the usefulness of caching in local builds, where the per-package and global configurations eliminate a lot of tedious command line boilerplate the user would need to add to each `swift build`, likely via a hand-authored script.

## Acknowledgements

Thanks to [Steven Wu](https://github.com/cachemeifyoucan), [Argyrios Kyrtzidis](https://github.com/akyrtzi), and [Ben Langmuir](https://github.com/benlangmuir) for answering questions and providing feedback on this proposal.
