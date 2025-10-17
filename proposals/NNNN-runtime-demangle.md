# Expose demangle function in Runtime module

* Proposal: [SE-NNNN](0496-runtime-demangle.md)
* Authors: [Konrad'ktoso'Malawski](https://github.com/ktoso), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: TODO
* Status: TODO
* Implementation: [PR #84788](https://github.com/swiftlang/swift/pull/84788)
* Review: 
    * Previous [pitch](https://forums.swift.org/t/demangle-function/25416/16)

## Introduction

Swift symbols are subject to name mangling. These mangled names then show up in backtraces and other profiling tools. Mangled names may look something like this `$sSS7cStringSSSPys4Int8VG_tcfC` and often end up visible to developers, unless they are demangled before displaying. 

In manu situations, it is much preferable to demangle the identifiers before displaying them. For example, the previously shown identifier would can be demangled as `Swift.String.init(cString: Swift.UnsafePointer<Swift.Int8>) -> Swift.String`, which is a nice human-readable format, that a Swift developer can easily understand.

This proposal introduces a new API that allows calling out to the Swift runtime's demangler, without leaving the process.

## Motivation

Currently, many tools that need to display symbol names to developers are forced to create a process and execute the `swift-demangle` tool, or use unofficial runtime APIs to invoke the runtime's demangler.

Neither of these approaches are satisfactionary, because either we are paying a high cost for creating processes, or we're relying on unofficial APIs.

This proposal introduces an official `demangle(:String) -> String?` function that offers a maintained and safe way to call the Swift demangled from a running Swift application.

## Proposed solution

We propose to introduce two `demangle` functions in the `Runtime` module:

A simple demangle method, returning an optional `String`:

```swift
public func demangle(_ mangledName: String) -> String?
```

And an overload which accepts a pre-allocated buffer into which the demangled string can be written:

```swift
@discardableResult
public func demangle(
  _ input: String,
  into buffer: UnsafeMutableBufferPointer<Int8>
) -> DemanglingResult

public enum DemanglingResult: Equatable {
  case success
  case failed
  case truncated(Int)
}
```

The buffer accepting API is necessary for performance sensitive use-cases, which attempt to demangle symbols in process, before displaying or sending them for further processing. In those use-cases it is common to have a known maximum buffer size into which we are willing to write the demangled representation.

If the demangled representation does not fit the preallocated buffer, the demangle method will return `truncated(actualSize)` such that developers can determine by how much the buffer might need to be increased to handle the complete demangling.

### Demangling format

While the mangled strings are part of Swift ABI and can therefore not really change on platforms with stable ABI, the demangled representation returned by the `demangle` functions is _not guaranteed to be stable in any way_.

The demangled representation may change without any warning, during even patch releases of Swift. The returned strings should be treated mostly as nicer to present to developers human readable representations, and it is not a goal to provide any form of guarantee about the exact shape of these.

## Source compatibility

This proposal is purely additive.

## ABI compatibility

This proposal is purely additive.

## Implications on adoption

The runtime demangling func becoming an official entry point will help prevent libraries call swift internals.

## Alternatives considered

### Do nothing

Not exposing this demangling capabilities officially, would result in tools authors continuing to use 
unofficial ways to get to this API. 

It also means that further locking down access to `swift_` APIs may be difficult,
as they are crucial and load bearing for some tools (such as *continuous profiling*).
E.g. recent versions of Swift issue the following warning when accessing some of its `swift_` namespaced runtime functions:

> symbol name 'swift_...' is reserved for the Swift runtime and cannot be directly referenced without causing unpredictable behavior; this will become an error

So if we wanted to further lock down such uses, including `swift_demangle`, it would be preferable to offer an official solution instead.

### Expose from Swift module

Previously, this was considered to expose from just the `Swift` module, however the `Runtime`
module is much more aligned with the use and utility of this function. 

Demangling is already used by the `Backtrace` type which is located in the Runtime module,
so the demangling functions should be exposed from the same place.

## Acknowledgments

Thanks to [Alejandro Alonso](https://github.com/Azoy), who did an initial version of this pitch many years ago, and this proposal is heavily based on his initial pitch.