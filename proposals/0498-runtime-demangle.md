# Expose demangle function in Runtime module

* Proposal: [SE-0498](0498-runtime-demangle.md)
* Previous Proposal: [SE-0262](0262-demangle.md)
* Authors: [Konrad'ktoso'Malawski](https://github.com/ktoso), [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Accepted**
* Implementation: [PR #84788](https://github.com/swiftlang/swift/pull/84788)
* Review: ([first pitch](https://forums.swift.org/t/demangle-function/25416/16)) ([second pitch](https://forums.swift.org/t/pitch-expose-demangle-function-in-runtime-module/82605)) ([review](https://forums.swift.org/t/se-0498-expose-demangle-function-in-runtime-module/83032)) ([acceptance](https://forums.swift.org/t/accepted-se-0498-expose-demangle-function-in-runtime-module/84111))

## Introduction

Swift symbols are subject to name mangling. These mangled names then show up in backtraces and other profiling tools. Mangled names may look something like this `$sSS7cStringSSSPys4Int8VG_tcfC` and often end up visible to developers, unless they are demangled before displaying. 

In many situations, it is much preferable to demangle the identifiers before displaying them. For example, the previously shown identifier would can be demangled as `Swift.String.init(cString: Swift.UnsafePointer<Swift.Int8>) -> Swift.String`, which is a nice human-readable format, that a Swift developer can easily understand.

This proposal introduces a new API that allows calling out to the Swift runtime's demangler, without leaving the process.

## Motivation

Currently, many tools that need to display symbol names to developers are forced to create a process and execute the `swift-demangle` tool, or use unofficial runtime APIs to invoke the runtime's demangler.

Neither of these approaches are satisfactionary, because either we are paying a high cost for creating processes, or we're relying on unofficial APIs.

This proposal introduces an official `demangle(_: String) -> String?` function that offers a maintained and safe way to call the Swift demangler from a running Swift application.

## Proposed solution

We propose to introduce two `demangle` functions in the `Runtime` module:

A simple demangle method, returning a `String`:

```swift
/// Given a mangled Swift symbol, demangle it into a human readable format.
///
/// If the provided string is not a valid mangled swift identifier this function will throw.
/// If mangling succeeds the returned string will contain a demangled human-readable representation of the identifier.
///
/// - Parameters:
///   - mangledName: A mangled Swift symbol.
/// - Returns: A human readable demangled Swift symbol.
/// - Throws: When the demangling fails for any reason.
/// - Warning: The demangled output is lossy is not not guaranteed to be stable across Swift versions.
///            Future versions of Swift may choose to print more (or less) information in the demangled format.
public func demangle(_ mangledName: String) throws(DemanglingError) -> String
```

The demangling function supports all valid Swift symbols. Valid Swift 5.0 and later symbols begin with `$s` (preceded by an optional platform-specific prefix).

And an overload which accepts an `UTF8Span` into which the demangled string can be written:

```swift
/// Given a mangled Swift symbol, demangle it into a human readable format into the prepared output span.
///
/// If the provided bytes are not a valid mangled swift name, the output span will be initialized with zero elements.
/// If mangling succeeds the output span will contain the resulting demangled string.
/// A successfully demangled string is _not_ null terminated, and its length is communicated by the `initializedCount`
/// of the output span.
///
/// The demangled output may be _truncated_ if the output span's capacity is insufficient for the
/// demangled output string! You can detect this situation by inspecting the returned ``DemanglingResult``,
/// for the ``DemanglingResult/truncated`` case.
///
/// - Parameters:
///   - mangledName: A mangled Swift symbol.
///   - output: A pre-allocated span to demangle the Swift symbol into.
/// - Throws: When the demangling failed entirely, and the output span will not have been written to.
/// - Warning: The demangled output is lossy is not not guaranteed to be stable across Swift versions.
///            Future versions of Swift may choose to print more (or less) information in the demangled format.
public func demangle(
  _ mangledName: borrowing UTF8Span,
  into output: inout OutputSpan<UTF8.CodeUnit>
) throws(DemanglingError)

/// Error thrown to indicate failure to demangle a Swift symbol.
public enum DemanglingError: Error {
  /// Demangling resulted in truncating the result. The payload value is the
  /// number of bytes necessary for a full demangle.
  case truncated(requiredBufferSize: Int)

  /// The passed Swift mangled symbol was invalid.
  case invalidSymbol
}
```

The span accepting API is necessary for performance sensitive use-cases, which attempt to demangle symbols in process, before displaying or sending them for further processing. In those use-cases it is common to have a known maximum buffer size into which we are willing to write the demangled representation.

The output from this API is an `OutputSpan` of `UTF8.CodeUnit`s, and it may not necessarily be well-formed UTF8, because of the potential of truncation happening between two code units which would render the UTF8 invalid.

If the demangled representation does not fit the preallocated buffer, the demangle method will throw `DemanglingError.truncated(requiredBufferSize: Int)` such that developers can determine by how much the buffer might need to be increased to handle the complete demangling. When `.truncated` is thrown, the `OutputSpan` will contain a _partial result_, of however many Unicode scalars were able to fit into it before truncation occurred. If truncation occurs, the returned string will contain only valid UTF8, i.e. the result will never be truncated in the middle of a Unicode scalar.

Converting the outputSpan to a `String`, which is guarateed to be valid UTF8, follows the below pattern, where creating an `UTF8Span` _will_ perform validation of the UTF8 String contents, and fail if the output wasn't correct. 

```swift
var demangledOutputSpan: OutputSpan<UTF8.CodeUnit> = ...

do {
  try demangle("$sSG", into: &demangledOutputSpan)
  let utf8 = try UTF8Span(validating: demangledOutputSpan.span)
  let demangledString = String(copying: utf8)
  print(demangledString) // Swift.RandomNumberGenerator
} catch DemanglingError.truncated(let requiredBufferSize) {
  // Handle truncation - need a buffer of size requiredBufferSize
} catch {
  // Handle invalid symbol
}
```

As this example shows, the path to constructing a String is therefore safe, and we don't want to perform validation earlier during `demangle`, because you may want to store the exact bytes that were returned for some future processing.

### Demangling format

While the mangled strings are part of Swift ABI and can therefore not really change on platforms with stable ABI, the demangled representation returned by the `demangle` functions is _not guaranteed to be stable in any way_.

The demangled representation may change without any warning, during even patch releases of Swift. The returned strings should be treated mostly as nicer to present to developers human readable representations, and it is not a goal to provide any form of guarantee about the exact shape of these.

## Future directions

### Customizing demangling behavior with options

We intentionally do not offer customization of demangling modes in this initial revision of this API. The Swift demangler does offer various options about how demangling should be performed, however we are not confident enough in selecting a subset of those options to offer as API at this point.

Adding those options will be possible in future revisions, by adding an additional `options: DemanglingOptions` parameter to the demangle functions introduced in this proposal.

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
