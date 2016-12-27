# Change (Dispatch)Data.`withUnsafeBytes` to use `UnsafeRawBufferPointer`

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Karl Wagner](https://github.com/karwa)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

The standard library's `Array` and `ContiguousArray` types expose the method `withUnsafeBytes`, which allows you to view their contents as a contiguous collection of raw bytes.

The core libraries Foundation and Dispatch contain types which wrap some allocated data, but their `withUnsafeBytes` method only allows you to view the contents as a single pointer bound to a given type.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161226/029783.html)

## Motivation

The current situation makes it awkward to write generic code. Personally, I use the following extension in my projects to sort the naming confusion out:

```swift
protocol ContiguousByteCollection {
  func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T
}

// stdlib types are fine.
extension Array: ContiguousByteCollection {}
extension ArraySlice: ContiguousByteCollection {}
extension ContiguousArray: ContiguousByteCollection {}

// corelibs types give us a pointer<T>, should be: { pointer<char>, count }
#if canImport(Dispatch)
  import Dispatch

  extension DispatchData : ContiguousByteCollection {
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
      return try withUnsafeBytes { try body(UnsafeRawBufferPointer(start: $0, count: count)) }
    }
  }
#endif

#if canImport(Foundation)
  import Foundation

  extension Data : ContiguousByteCollection {
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
      return try withUnsafeBytes { try body(UnsafeRawBufferPointer(start: $0, count: count)) }
    }
  }
#endif
```

Conceptually, the corelibs types _are_ untyped regions of memory, and it would make sense for them to adopt the `UnsafeRawBufferPointer` model.

## Proposed solution

The proposed solution would be to deprecate the current methods on (Dispatch)Data (with 2 generic parameters), and replace them with methods with identical signatures to Array (with 1 generic parameter).

```swift
public func withUnsafeBytes<ResultType, ContentType>(_ body: (UnsafePointer<ContentType>) throws -> ResultType) rethrows -> ResultType
```
Will be deprecated, and replaced with:
```swift
public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
```

## Source compatibility

Source-breaking. Users binding a (Dispatch)Data to an `UnsafePointer<T>` would instead have to call:
```swift
buffer.baseAddress!.assumingMemoryBound(to: T.self)
```
Which is a bit more to type, although maybe the deprecation of the old function could provide this replacement as a fix-it.


## Effect on API resilience

Source-breaking change to corelibs APIs.

## Alternatives considered

- A different method on `Data` and `DispatchData`, providing an `UnsafeRawBufferPointer`? There would still be a naming discrepency between the stdlib and corelibs types
