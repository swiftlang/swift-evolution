# API to get the path to the current executable

* Proposal: [SE-0513](0513-commandline-executablepath.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Active review (February 18–March 4, 2026)**
* Implementation: [swiftlang/swift#85496](https://github.com/swiftlang/swift/pull/85496)
* Review: ([pitch](https://forums.swift.org/t/pitch-api-to-get-the-path-to-the-current-executable/84137)) ([review](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800))

## Introduction

This proposal adds to the Swift standard library an interface for reading the
path to the currently-executing binary. This value is useful to developers who
need to spawn additional processes or who need to present information about the
current program to the user.

## Motivation

There is no portable way (e.g. a C standard library function or POSIX
specification) to get the path to the current executable. Historically,
developers have to write their own platform-specific implementation to get this
value or have reached for `argv[0]` thinking it contains said path. We can do
better and provide a common interface for this functionality across the
platforms that Swift supports.

> [!NOTE]
> Regarding `argv[0]`: `argv[0]` is not required by POSIX nor any revision of
> the C language standard to contain the path to the executable. From §5.1.2.3.2
> of the C23 standard (entitled "Program startup"):
>
> > If the value of `argc` is greater than zero, the string pointed to by
> > `argv[0]` represents the program name; `argv[0][0]` shall be the null
> > character if the program name is not available from the host environment.
>
> In practice, `argv[0]` is controlled by the parent process and may contain a
> relative or partial path or even an unrelated string.

Swift, like most modern languages, provides access to information about the
program's environment such as its command-line arguments (including `argv[0]`).
Those arguments are read by the Swift runtime in a platform-specific manner.
We should take a similar approach to read the executable path and provide it to
developers if needed.

There are a number of modules in the Swift toolchain and its ecosystem that
would benefit from a way to get the executable path, including:

- Foundation
- Swift Argument Parser
- Swift Testing
- swift-subprocess

## Proposed solution

I propose adding a new read-only string property named `executablePath` to the
existing [`CommandLine`](https://developer.apple.com/documentation/swift/commandline)
type in the standard library.

### Precedent in other languages

While C and C++ (without Boost) do not provide an equivalent API, other modern
languages do:

| Language | Equivalent API |
|-|-|
| C++ (with Boost) | [`boost::dll::program_location()`](https://www.boost.org/doc/libs/latest/doc/html/doxygen/shared_library_reference/runtime__symbol__info_8hpp_1ad4f62eae484acfa53de57045fd18dde7.html) |
| D | [`std.file.thisExePath()`](https://dlang.org/library/std/file/this_exe_path.html) |
| Go | [`os.Executable()`](https://pkg.go.dev/os#Executable) |
| Haskell | [`System.Environment.getExecutablePath`](https://hackage-content.haskell.org/package/base-4.22.0.0/docs/System-Environment.html) |
| Rust | [`std::env::current_exe()`](https://doc.rust-lang.org/std/env/fn.current_exe.html) |
| Zig | [`std.fs.selfExePath()`](https://ziglang.org/documentation/0.15.2/std/#std.fs.selfExePath) |

## Detailed design

The following new API is added to the standard library:

```swift
extension CommandLine {
  /// The path to the current executable.
  ///
  /// The value of this property may not be canonical. If you need the canonical
  /// path to the current executable, you can pass the value of this property to
  /// `realpath()` (`_wfullpath()` on Windows) or use `URL` to standardize the
  /// path.
  ///
  /// If the path to the current executable could not be determined, the value
  /// of this property is `nil`.
  ///
  /// - Important: On some systems, it is possible to move an executable file on
  ///   disk while it is running. If the current executable file is moved, the
  ///   value of this property is not updated to its new path.
#if hasFeature(Embedded) || os(WASI)
  @available(*, unavailable)
#endif
  public static var executablePath: String? { get }
}
```

The implementation does not attempt to resolve symlinks or other forms of
indirection in the path provided by the underlying OS API call[^linuxRealpath].
This is a pragmatic decision: in the common case, a symlink is not present and
the I/O necessary to try and resolve it is wasted effort. If there _is_ a
symlink, its presence is not necessarily a problem for the calling code. Callers
that need to resolve symlinks in this path can manually call `realpath()`
(`_wfullpath()` on Windows) or equivalent API as needed.

If the current executable is moved on disk after it starts, the underlying
system may or may not update the path it reports. This is ultimately a
platform-specific implementation detail and one that we cannot reliably work
around, but neither can developers who implement their own version of this
property. The documentation therefore warns developers of the possibility.

This property is explicitly unavailable in Embedded Swift and WASI: if in the
future we can reliably get a value for this property in Embedded Swift or on
WASI, we ought to be able to lift these constraints.

[^linuxRealpath]: On some platforms (namely Linux) the API itself consists of
  resolving a symlink, and we _do_ resolve that symlink out of necessity.

## Source compatibility

This change is additive. Developers (if any) who have already added an
`executablePath` property to `CommandLine` may need to rename that property or
replace it with this one.

## ABI compatibility

This proposal is purely an extension of the standard library which
can be implemented without any ABI support.

On Darwin, the property can be back-deployed because it is implemented atop
existing API provided by the operating system.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.

## Future directions

N/A

## Alternatives considered

- Doing nothing.

- **Using the implementation and interfaces in Foundation (e.g.
  [`Bundle.executableURL`](https://developer.apple.com/documentation/foundation/bundle/executableurl)).**
  Foundation is commonly imported by Swift packages and projects, but it is
  fairly "high up" in the stack. Some components _cannot_ link to it (such as
  the standard library) or have significant constraints when linking to it (such
  as Swift Testing).

- **Providing API in the swift-system package.** swift-system's [`FilePath`](https://developer.apple.com/documentation/System/FilePath)
  type is appealing here, of course. But swift-system is non-portable by design,
  and the goal here is to provide a portable (or mostly-portable) API that can
  be used in cross-platform code.

- **Exposing the property as a C string rather than as a Swift string.** We
  could provide an interface that produces an `UnsafePointer<CChar>` (or
  `UnsafePointer<CWideChar>` on Windows), a `Span<CChar>`, a
  `ContiguousArray<CChar>`, etc. We could still provide such an interface if
  needed, but paths are generally treated as strings in Swift code and in the
  common case a developer who is handed an `UnsafePointer<CChar>` is going to
  immediately pass it to `String.init(cString:)` anyway.

- **Making the property's type non-optional.** The initial version of this
  proposal presented a non-optional property that aborted if the path was
  unavailable. This makes it difficult for developers to recover from a
  low-level failure, but a failure to get the executable path does not
  necessarily imply a fatal error in the program.

- **Making the property's getter throwing.** The failure modes for this property
  are all edge cases. Throwing an error is a bit too "heavyweight" for the API's
  expected use cases. It is unlikely the program or the user could recover from
  a thrown error in a way that would allow the API to succeed the next time it
  is called, so callers would probably end up ignoring errors with `try?` or
  similar.

- **Making the property available (always equalling `nil`) on WASI.** The
  property's value is optional on platforms where it is supported for reasons
  described earlier in this section. On WASI, there is no real concept of an
  "executable" within the WebAssembly virtual machine. If a developer is using
  this API and ports their code to WASI, and there is no compile-time indication
  that the property is non-functional, that developer may be misled into
  thinking the code works correctly. A better option is to mark the API
  unavailable so that a developer who is using it will be forced to stop and
  think about appropriate alternatives.

- **Making the property available under Embedded Swift.** Under Embedded Swift,
  the Swift runtime has limited ability to call platform-specific API because
  there's no real guarantee there is even a "platform" _per se_. Embedded Swift
  can be used with full desktop-class operating systems, but it can also be used
  on true embedded systems where the CPU directly executes instructions loaded
  from RAM or ROM and there isn't even a file system in which to place an
  executable. As with WASI, it is better to mark the API unavailable so that a
  developer is forced to think about why they are trying to use it under
  Embedded Swift and whether it's appropriate to use in the first place.
