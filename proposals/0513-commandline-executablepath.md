# API to get the path to the current executable

* Proposal: [SE-0513](0513-commandline-executablepath.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Tony Allevato](https://github.com/allevato)
* Status: **Returned for revision**
* Implementation: [swiftlang/swift#85496](https://github.com/swiftlang/swift/pull/85496)
* Review: ([pitch](https://forums.swift.org/t/pitch-api-to-get-the-path-to-the-current-executable/84137)) ([review](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0513-api-to-get-the-path-to-the-current-executable/85220))

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

I propose adding a new read-only property named `executablePath` to the existing
[`CommandLine`](https://developer.apple.com/documentation/swift/commandline)
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
  public static var executablePath: FilePath? { get }
}
```

The implementation does not attempt to resolve symlinks or other forms of
indirection in the path provided by the underlying OS API call[^linuxRealpath].
This is a pragmatic decision: in the common case, a symlink is not present and
the I/O necessary to try and resolve it is wasted effort. If there _is_ a
symlink, its presence is not necessarily a problem for the calling code. Callers
that need to resolve symlinks in this path can manually call `realpath()`
(`_wfullpath()` on Windows) or equivalent API as needed. Note that, as of today,
`FilePath` does not provide a wrapper interface around `realpath()` (such an
interface is beyond the scope of this proposal, but if one is added in the
future we can update the documentation for `executablePath` accordingly).

If the current executable is moved on disk after it starts, the underlying
system may or may not update the path it reports. This is ultimately a
platform-specific implementation detail and one that we cannot reliably work
around, but neither can developers who implement their own version of this
property. The documentation therefore warns developers of the possibility.

On platforms where this property cannot be implemented (generally because the
underlying operating system does not provide an interface for querying the
executable path), the value of this property is always `nil`.

[^linuxRealpath]: On some platforms (namely Linux) the API itself consists of
  _reading_ a symlink, which we do out of necessity.

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

- **Exposing the property as an instance of `String` instead of `FilePath`.**
  The original version of this proposal did so, but we currently expect that
  `FilePath` will be brought from the swift-system package into the standard
  library with [SE-NNNN](). `FilePath` represents a better interface for path
  strings as it can handle invalid Unicode sequences ("bag-o'-bytes encoding").

- **Exposing the property as a C string rather than as a Swift value.** We
  could provide an interface that produces an `UnsafePointer<CChar>` (or
  `UnsafePointer<CWideChar>` on Windows), a `Span<CChar>`, a
  `ContiguousArray<CChar>`, etc. We could still provide such an interface if
  needed, but it is straightforward to get a platform C string from an instance
  of `FilePath` using [`withPlatformString(_:)`](https://developer.apple.com/documentation/system/filepath/withplatformstring(_:)).

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
