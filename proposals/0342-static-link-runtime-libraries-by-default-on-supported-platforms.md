# Statically link Swift runtime libraries by default on supported platforms

* Proposal: [SE-0342](0342-static-link-runtime-libraries-by-default-on-supported-platforms.md)
* Authors: [neonichu](https://github.com/neonichu) [tomerd](https://github.com/tomerd)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Active Review (February 15...25 2022)**
* Implementation: https://github.com/apple/swift-package-manager/pull/3905
* Initial discussion: [Forum Thread](https://forums.swift.org/t/pre-pitch-statically-linking-the-swift-runtime-libraries-by-default-on-linux)
* Pitch: [Forum Thread](https://forums.swift.org/t/pitch-package-manager-statically-link-swift-runtime-libraries-by-default-on-supported-platforms)

## Introduction

Swift 5.3.1 introduced [statically linking the Swift runtime libraries on Linux](https://forums.swift.org/t/static-linking-on-linux-in-swift-5-3-1/).
With this feature, users can set the `--static-swift-stdlib` flag when invoking  SwiftPM commands (or the long form `-Xswiftc -static-stdlib`) in order to statically link the Swift runtime libraries into the program.

On some platforms, such as Linux, this is often the preferred way to link programs, since the program is easier to deploy to the target server or otherwise share.

This proposal explores making it SwiftPM's default behavior when building executable programs on such platforms.

## Motivation

Darwin based platform ship with the Swift runtime libraries in the _dyld shared cache_.
This allows building smaller Swift programs by dynamically linking the Swift runtime libraries.
The shared cache keeps the cost of loading these libraries low.

Other platforms, such as conventional Linux distributions, do not ship with the Swift runtime libraries.
Hence, a deployment of a program built with Swift (e.g. a web-service or CLI tool) on such platform requires one of three options:

1. Package the application with a "bag of shared objects" (the `libswift*.so` files making up Swift's runtime libraries) alongside the program.
2. Statically link the runtime libraries using the `--static-swift-stdlib` flag described above.
3. Use a "runtime" docker image that contain the _correct version_ of the the runtime libraries (matching the compiler version exactly).

Out of the three options, the most convenient is #2 given that #1 requires manual intervention and/or additional wrapper scripts that use `ldd`, `readelf` or similar tools to deduce the correct list of runtime libraries.
#3 is convenient but version sensitive.
#2 also has cold start performance advantage because there is less dynamic library loading.
However #2 comes at a cost of bigger binaries.

Stepping outside the Swift ecosystem, deployment of statically linked programs is often the preferred way on server centric platforms such as Linux, as it dramatically simplifies deployment of server workloads.
For reference, Go and Rust both chose to statically link programs by default for this reason.

### Policy for system shipping with the Swift runtime libraries

At this time, Darwin based systems are the only ones that ship with the Swift runtime libraries.
In the future, other operating systems may choose to ship with the Swift runtime libraries.
As pointed out by [John_McCall](https://forums.swift.org/u/John_McCall), in such cases the operating system vendors are likely to choose a default that is optimized for their software distribution model.
For example, they may choose to distribute a Swift toolchain defaulting to dynamic linking (against the version of the Swift runtime libraries shipped with that system) to optimize binary size and memory consumption on that system.
To support this, the Swift toolchain build script could include a preset to controls the default linking strategy.

As pointed out by [Joe_Groff](https://forums.swift.org/u/Joe_Groff), even in such cases there is still an argument for defaulting Swift.org distributed Swift toolchains to static linking for distribution, since we want to preserve the freedom to pursue ABI-breaking improvements in top-of-tree for platforms that aren't ABI-constrained. This situation wouldn't be different from other ecosystems: The Python or Ruby that comes with macOS are set up to provide a stable runtime environment compatible with the versions of various Python- and Ruby-based tools and libraries packaged by the distribution, but developers can and do often install their own local Python/Ruby interpreter if they need a language version different from the vendor's, or a package that's incompatible with the vendor's interpreter.

## Proposed solution

Given that at this time Darwin based systems are the only ones that ship with the Swift runtime libraries,
we propose to make statically linking of the Swift runtime libraries SwiftPM's default behavior when building executables in release mode on non-Darwin platforms that support such linking,
with an opt-out way to disable this default behavior.

Building in debug mode will continue to dynamically link the Swift runtime libraries, given that debugging requires the Swift toolchain to be installed and as such the Swift runtime libraries are by definition present.

Note that SwiftPM's default behavior could change over time as its designed to reflect the state and available options of Swift runtime distribution on that platform. In other words, whether or not a SwiftPM defaults to static linking of the Swift runtime libraries is a by-product of the state of Swift runtime distribution on a platform.

Also note this does not mean the resulting program is fully statically linked - only the Swift runtime libraries (stdlib, Foundation, Dispatch, etc) would be statically linked into the program, while external dependencies will continue to be dynamically linked and would remain a concern left to the user when deploying Swift based programs.
Such external dependencies include:
1. Glibc (including `libc.so`, `libm.so`, `libdl.so`, `libutil.so`): On Linux, Swift relies on Glibc to interact with the system and its not possible to fully statically link programs based on Glibc. In practice this is usually not a problem since most/all Linux systems ship with a compatible Glibc.
2. `libstdc++` and `libgcc_s.so`: Swift on Linux also relies on GNU's C++ standard library as well as GCC's runtime library which much like Glibc is usually not a problem because a compatible version is often already installed on the target system.
3. At this time, non-Darwin version of Foundation (aka libCoreFoundation) has two modules that rely on system dependencies (`FoundationXML` on `libxml2` and `FoundationNetworking` on `libcurl`) which cannot be statically linked at this time and require to be installed on the target system.
4. Any system dependencies the program itself brings (e.g. `libsqlite`, `zlib`) would not be statically linked and must be installed on the target system.


## Detailed design

The changes proposed are focused on the behavior of SwiftPM.
We propose to change SwiftPM's default linking of the Swift runtime libraries when building executables as follows:

### Default behavior

* Darwin-based platforms used to support statically linking the Swift runtime libraries in the past (and never supported fully static binaries).
  Today however, the Swift runtime library is shipped with the operating system and can therefore not easily be included statically in the binary.
  Naturally, dynamically linking the Swift runtime libraries will remain the default on Darwin.

* Linux and WASI support static linking and would benefit from it for the reasons highlighted above.
  We propose to change the default on these platforms to statically link the Swift runtime libraries.

* Windows may benefit from statically linking for the reasons highlighted above but it is not technically supported at this time.
  As such the default on Windows will remain dynamically linking the Swift runtime libraries.

* The default behavior on platforms not listed above will remain dynamically linking the Swift runtime libraries.

### Opt-in vs. Opt-out

SwiftPM's `--static-swift-stdlib` CLI flag is designed as an opt-in way to achieve static linking of the Swift runtime libraries.

We propose to deprecate `--static-swift-stdlib` and introduce a new flag `--disable-static-swift-runtime` which is designed as an opt-out from the default behavior described above.

Users that want to force static linking (as with `--static-swift-stdlib`) can use the long form `-Xswiftc -static-stdlib`.

### Example

Consider the following simple program:

```bash
$ swift package init --type executable
Creating executable package: test
Creating Package.swift
Creating README.md
Creating .gitignore
Creating Sources/
Creating Sources/test/main.swift
Creating Tests/
Creating Tests/testTests/
Creating Tests/testTests/testTests.swift

$ cat Sources/test/main.swift
print("Hello, world!")
```
Building the program with default dynamic linking yields the following:

```bash
$ swift build -c release
[3/3] Build complete!

$ ls -la --block-size=K .build/release/test
-rwxr-xr-x 1 root root 17K Dec  3 22:48 .build/release/test*

$ ldd .build/release/test
	linux-vdso.so.1 (0x00007ffc82be4000)
	libswift_Concurrency.so => /usr/lib/swift/linux/libswift_Concurrency.so (0x00007f0f5cfb5000)
	libswiftCore.so => /usr/lib/swift/linux/libswiftCore.so (0x00007f0f5ca55000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0f5c85e000)
	libdispatch.so => /usr/lib/swift/linux/libdispatch.so (0x00007f0f5c7fd000)
	libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007f0f5c7da000)
	libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007f0f5c7d4000)
	libswiftGlibc.so => /usr/lib/swift/linux/libswiftGlibc.so (0x00007f0f5c7be000)
	libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007f0f5c5dc000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f0f5c48d000)
	libgcc_s.so.1 => /lib/x86_64-linux-gnu/libgcc_s.so.1 (0x00007f0f5c472000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f0f5d013000)
	libicui18nswift.so.65 => /usr/lib/swift/linux/libicui18nswift.so.65 (0x00007f0f5c158000)
	libicuucswift.so.65 => /usr/lib/swift/linux/libicuucswift.so.65 (0x00007f0f5bf55000)
	libicudataswift.so.65 => /usr/lib/swift/linux/libicudataswift.so.65 (0x00007f0f5a4a2000)
	librt.so.1 => /lib/x86_64-linux-gnu/librt.so.1 (0x00007f0f5a497000)
	libBlocksRuntime.so => /usr/lib/swift/linux/libBlocksRuntime.so (0x00007f0f5a492000)
```

Building the program with static linking of the Swift runtime libraries yields the following:

```bash
$ swift build -c release --static-swift-stdlib
[3/3] Build complete!

$ ls -la --block-size=K .build/release/test
-rwxr-xr-x 1 root root 35360K Dec  3 22:50 .build/release/test*

$ ldd .build/release/test
	linux-vdso.so.1 (0x00007fffdaafa000)
	libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007fdd521c5000)
	libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007fdd521a2000)
	libstdc++.so.6 => /lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007fdd51fc0000)
	libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007fdd51e71000)
	libgcc_s.so.1 => /lib/x86_64-linux-gnu/libgcc_s.so.1 (0x00007fdd51e56000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fdd51c64000)
	/lib64/ld-linux-x86-64.so.2 (0x00007fdd54211000)
```

These snippets demonstrates the following:
1. Statically linking of the Swift runtime libraries increases the binary size from 17K to ~35M.
2. Statically linking of the Swift runtime libraries reduces the dependencies reported by `ldd` to core Linux libraries.

This jump in binary size may be alarming at first sight, but since the program is not usable without the Swift runtime libraries, the actual size of the deployable unit is similar.

```bash
$ mkdir deps

$ ldd ".build/release/test" | grep swift | awk '{print $3}' | xargs cp -Lv -t ./deps
'/usr/lib/swift/linux/libswift_Concurrency.so' -> './deps/libswift_Concurrency.so'
'/usr/lib/swift/linux/libswiftCore.so' -> './deps/libswiftCore.so'
'/usr/lib/swift/linux/libdispatch.so' -> './deps/libdispatch.so'
'/usr/lib/swift/linux/libswiftGlibc.so' -> './deps/libswiftGlibc.so'
'/usr/lib/swift/linux/libicui18nswift.so.65' -> './deps/libicui18nswift.so.65'
'/usr/lib/swift/linux/libicuucswift.so.65' -> './deps/libicuucswift.so.65'
'/usr/lib/swift/linux/libicudataswift.so.65' -> './deps/libicudataswift.so.65'
'/usr/lib/swift/linux/libBlocksRuntime.so' -> './deps/libBlocksRuntime.so'

$ ls -la --block-size=K deps/
total 42480K
drwxr-xr-x 2 root root     4K Dec  3 22:59 ./
drwxr-xr-x 6 root root     4K Dec  3 22:58 ../
-rw-r--r-- 1 root root    17K Dec  3 22:59 libBlocksRuntime.so
-rw-r--r-- 1 root root   432K Dec  3 22:59 libdispatch.so
-rwxr-xr-x 1 root root 27330K Dec  3 22:59 libicudataswift.so.65*
-rwxr-xr-x 1 root root  4030K Dec  3 22:59 libicui18nswift.so.65*
-rwxr-xr-x 1 root root  2403K Dec  3 22:59 libicuucswift.so.65*
-rwxr-xr-x 1 root root   520K Dec  3 22:59 libswift_Concurrency.so*
-rwxr-xr-x 1 root root  7622K Dec  3 22:59 libswiftCore.so*
-rwxr-xr-x 1 root root   106K Dec  3 22:59 libswiftGlibc.so*
```

## Impact on existing packages

The new behavior will take effect with a new version of SwiftPM, and packages build with that version will be linked accordingly.

* Deployment of applications using "bag of shared objects" technique (#1 above) will continue to work as before (though would be potentially redundant).
* Deployment of applications using explicit static linking (#2 above) will continue to work and emit a warning that its redundant.
* Deployment of applications using docker "runtime" images (#3 above) will continue to work as before (though would be redundant).

## Alternatives considered and future directions

The most obvious question this proposal brings is why not fully statically link the program instead of statically linking only the runtime libraries.
Go is a good example for creating fully statically linked programs, contributing to its success in the server ecosystem at large.
Swift already offers a flag for this linking mode: `-Xswiftc -static-executable`, but in reality Swift's ability to create fully statically linked programs is constrained.
This is mostly because today, Swift on Linux only supports GNU's libc (Glibc) and GNU's C++ standard library which do not support producing fully static binaries.
A future direction could be to look into supporting the `musl libc` and LLVM's `libc++` which should be able to produce fully static binaries.

Further, Swift has good support to interoperate with C libraries installed on the system.
Whilst that is a nice feature, it does make it difficult to create fully statically linked programs because it would be necessary to make sure each and every of these dependencies is available in a fully statically linked form with all the common dependencies being compatible.
For example, it is not possible to link a binary that uses the `musl libc` with libraries that expect to be statically linked with Glibc.
As Swift's ability to create fully statically linked programs improves, we should consider changing the default from `-Xswiftc -static-stdlib` to `-Xswiftc -static-executable`.

A more immediate future direction which would improve programs that need to use of FoundationXML and FoundationNetworking is to replace the system dependencies of these modules with native implementation.
This is outside the scope of this proposal which focuses on SwiftPM's behavior.

Another alternative is to do nothing.
In practice, this proposal does not add new features, it only changes default behavior which is already achievable with the right knowledge of build flags.
That said, we believe that changing the default will make using Swift on non-Darwin platforms easier, saving time and costs to Swift users on such platforms.

The spelling of the new flag `--disable-static-swift-runtime` is open to alternative ideas, e.g. `--disable-static-swift-runtime-libraries`.
