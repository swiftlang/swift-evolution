# Demangle Function

* Proposal: [SE-0262](0262-demangle.md)
* Author: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Withdrawn**
* Implementation: [apple/swift#25314](https://github.com/apple/swift/pull/25314)
* Decision Notes: [Returned for revision](https://forums.swift.org/t/returned-for-revision-se-0262-demangle-function/28186)
* Superseding Proposal: [SE-0498: Runtime demangle function](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0498-runtime-demangle.md)

## Introduction

Introduce a new standard library function, `demangle`, that takes a mangled Swift symbol, like `$sSS7cStringSSSPys4Int8VG_tcfC`, and output the human readable Swift symbol, like `Swift.String.init(cString: Swift.UnsafePointer<Swift.Int8>) -> Swift.String`.

Swift-evolution thread: [Demangle Function](https://forums.swift.org/t/demangle-function/25416)

## Motivation

Currently in Swift, if a user is given an unreadable mangled symbol, they're most likely to use the `swift-demangle` tool to get the demangled version. However, this is a little awkward when you want to demangle a symbol in-process in Swift. One could create a new `Process` from Foundation and set it up to launch a new process within the process to use `swift-demangle`, but the standard library can do better and easier. 

## Proposed solution

The standard library will add the following 3 new functions.

```swift
// Given a mangled Swift symbol, return the demangled symbol.
public func demangle(_ input: String) -> String?

// Given a mangled Swift symbol in a buffer and a preallocated buffer,
// write the demangled symbol into the buffer.
public func demangle(
  _ mangledNameBuffer: UnsafeBufferPointer<Int8>,
  into buffer: UnsafeMutableBufferPointer<Int8>
) -> DemangleResult

// Given a mangled Swift symbol and a preallocated buffer,
// write the demangle symbol into the buffer.
public func demangle(
  _ input: String,
  into buffer: UnsafeMutableBufferPointer<Int8>
) -> DemangleResult
```

as well as the following enum to indicate success or the different forms of failure:

```swift
public enum DemangleResult: Equatable {
  // The demangle was successful
  case success
  
  // The result was truncated. Payload contains the number of bytes
  // required for the complete demangle.
  case truncated(Int)
  
  // The given Swift symbol was invalid.
  case invalidSymbol
}
```

Examples:

```swift
print(demangle("$s8Demangle3FooV")!) // Demangle.Foo

// Demangle.Foo is 13 characters + 1 null terminator
let buffer = UnsafeMutableBufferPointer<Int8>.allocate(capacity: 14)
defer { buffer.deallocate() }

let result = demangle("$s8Demangle3BarV", into: buffer)

guard result == .success else {
  // Handle failure here
  switch result {
  case let .truncated(required):
    print("We need \(required - buffer.count) more bytes!")
  case .invalidSymbol:
    print("I was given a faulty symbol?!")
  default:
    break
  }
  
  return
}

print(String(cString: buffer.baseAddress!)) // Demangle.Foo
```

## Detailed design

If one were to pass a string that wasn't a valid Swift mangled symbol, like `abc123`, then the `(String) -> String?` would simply return nil to indicate failure. With the `(String, into: UnsafeMutableBufferPointer<Int8>) -> DemangleResult` version and the buffer input version, we wouldn't write the passed string into the buffer if it were invalid.

This proposal includes a trivial `(String) -> String?` version of the function, as well as a version that takes a buffer. In addition to the invalid input error case, the buffer variants can also fail due to truncation. This occurs when the output buffer doesn't have enough allocated space for the entire demangled result. In this case, we return `.truncated(Int)` where the payload is equal to the total number of bytes required for the entire demangled result. We're still able to demangle a truncated version of the symbol into the buffer, but not the whole symbol if the buffer is smaller than needed. E.g.

```swift
// Swift.Int requires 10 bytes = 9 characters + 1 null terminator
// Give this 9 to exercise truncation
let buffer = UnsafeMutableBufferPointer<Int8>.allocate(capacity: 9)
defer { buffer.deallocate() }

if case let .truncated(required) = demangle("$sSi", into: buffer) {
  print(required) // 10 (this is the amount needed for the full Swift.Int)
  let difference = required - buffer.count
  print(difference) // 1 (we only need 1 more byte in addition to the 9 we already allocated)
}

print(String(cString: buffer.baseAddress!)) // Swift.In (notice the missing T)
```

This implementation relies on the Swift runtime function `swift_demangle` which accepts symbols that start with `_T`, `_T0`, `$S`, and `$s`.

## Source compatibility

These are completely new standard library functions, thus source compatibility is unaffected.

## Effect on ABI stability

These are completely new standard library functions, thus ABI compatibility is unaffected.

## Effect on API resilience

These are completely new standard library functions, thus API resilience is unaffected.

## Alternatives considered

We could choose to only provide one of the proposed functions, but each of these brings unique purposes. The trivial take a string and return a string version is a very simplistic version in cases where maybe you're not worried about allocating new memory, and the buffer variants where you don't want to alloc new memory and want to pass in some memory you've already allocated.

## Future Directions

The `swift_demangle` runtime function has an extra `flags` parameter, but currently it is not being used for anything. In the future if that function ever supports any flags, it would make sense to introduce new overloads or something similar to expose those flags to the standard library as well. E.g.

```swift
public func demangle(_ input: String, flags: DemangleFlags) -> String?

public func demangle(
  _ mangledNameBuffer: UnsafeBufferPointer<Int8>,
  into buffer: UnsafeMutableBufferPointer<Int8>,
  flags: DemangleFlags
) -> DemangleResult

public func demangle(
  _ input: String,
  into buffer: UnsafeMutableBufferPointer<Int8>,
  flags: DemangleFlags
) -> DemangleResult
```

where `DemangleFlags` could be an enum, `OptionSet`, `[DemangleFlag]`, etc.
