# Rename some unsafe byte conversion API of the `Span` family

* Proposal: [SE-NNNN](nnnn-rename-unsafe-span-byte-conversions.md)
* Authors: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: **Unimplemented**
* Previous Proposals: [SE-0447](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md), [SE-0456](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md), [SE-0467](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0467-MutableSpan.md), [SE-0485](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0485-outputspan.md), [SE-0525]
* Review: ([pitch](https://forums.swift.org/t/88498))

[SE-0525]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0525-rawspan-safe-loading-api.md

## Introduction

We propose the renaming of some computed properties and functions that were marked as `@unsafe` after their initial proposal. These `Span`-family API involve reinterpreting memory as bytes, and were found to be unsafe when audited after their introduction. The updated names will reflect that their operations are unsafe in standard-mode source code, where the compiler emits no warnings for unsafe code.

## Motivation

[SE-0525] formalized the parameters for safely interpreting typed memory as bytes, and vice-versa. Prior to that proposal, we had introduced some API that perform byte conversions, but did not name them as strictly as they should have been. It is the policy of the Swift project to clearly name unsafe API with specific words, such as "unsafe" in `UnsafePointer`, or "unchecked" in `UTF8Span.init(unchecked:)`. A few API from the `Span` family have not met this bar.

[SE-0525] introduced safe counterparts to these API, by overloading them with tighter generic constraints. As a result, code that uses the looser (and unsafe) constraint reads identically to the safe code when strict memory safety is not active. A user can find themselves using unsafe code without meaning to do so.

## Proposed solution

This proposal addresses the naming deficiencies of the earlier API. We introduce new names for them, along with long-term deprecations for the original names.
- `bytes` → `unsafeBytes`
- `mutableBytes` → `unsafeMutableBytes`
- `append(_:as:)` → `append(unsafeBytes:as:)`
- `append(repeating:count:as:)` → `append(repeatingUnsafeBytes:count:as:)`

The deprecations are scheduled for a future Swift language mode. This will discourage IDEs from suggesting the deprecated symbols, while avoiding the immediate appearance of warnings until a new language mode is introduced.

## Detailed design

The `@unsafe` declarations are renamed as follows:

```swift
extension Span {
  @unsafe public var unsafeBytes: RawSpan { get }
}
```

```swift
extension MutableSpan {
  @unsafe public var unsafeBytes: RawSpan { get }
}

extension MutableSpan where Element: BitwiseCopyable {
  @unsafe public var unsafeMutableBytes: MutableRawSpan { mutating get }
}
```

```swift
extension OutputRawSpan {
  @unsafe public mutating func append<T: BitwiseCopyable>(
    unsafeBytes value: T, as type: T.Type
  )

  @unsafe public mutating func append<T: BitwiseCopyable>(
    repeatingUnsafeBytes repeatedValue: T, count: Int, as type: T.Type
  )
}
```

Each original name is retained, with a deprecation scheduled for a future Swift language mode. This will discourage IDEs from suggesting the deprecated symbols, while avoiding the immediate appearance of warnings until a new language mode is introduced.
```swift
extension Span where Element: BitwiseCopyable {
  @available(swift, deprecated: 7, renamed: "unsafeBytes")
  @unsafe public var bytes: RawSpan { get }
}

extension MutableSpan where Element: BitwiseCopyable {
  @available(swift, deprecated: 7, renamed: "unsafeBytes")
  @unsafe public var bytes: RawSpan { get }

  @available(swift, deprecated: 7, renamed: "unsafeMutableBytes")
  @unsafe public var mutableBytes: MutableRawSpan { mutating get }
}

extension OutputRawSpan {
  @available(swift, deprecated: 7, renamed: "append(unsafeBytes:as:)")
  @unsafe public mutating func append<T: BitwiseCopyable>(
    _ value: T, as type: T.Type
  )

  @available(swift, deprecated: 7, renamed: "append(repeatingUnsafeBytes:count:as:)")
  @unsafe public mutating func append<T: BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
}
```

<details>
<summary>Safe [SE-0525] additions</summary>

For reference, here are the safe additions from [SE-0525] that improve on the symbols deprecated above:

```swift
extension Span where Element: ConvertibleToBytes {
  var bytes: RawSpan { get }
}

extension MutableSpan where Element: ConvertibleToBytes {
  var bytes: RawSpan { get }
}

extension MutableSpan where Element: FullyInhabited {
  var mutableBytes: MutableRawSpan { mutating get }
}

extension OutputRawSpan {
  public mutating func append<T>(
    _ value: T, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  public mutating func append<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable
}
```

</details>

## Source compatibility

This change is source-compatible. The new deprecation warnings will appear when compiled under a future language mode.

## ABI compatibility

The affected symbols do not have an ABI.

## Implications on adoption

Adopters should migrate to the new names, and the deprecated aliases allow incremental adoption. The long deprecation window is intended to help package authors who support multiple recent Swift versions. By the time the deprecation becomes active and the compiler issues warnings, a sufficient number of Swift versions will feature both names, and updating would not cause issues for actively supported packages.

## Alternatives considered

### Remove the symbols instead of renaming them
This would do more harm than good. These symbols have legitimate use cases that benefit from not requiring the closure-based `withUnsafe*Bytes` spelling. Renaming them improves them.

### Change the behaviour of LLVM to make the original symbols safe
The behaviour of LLVM which makes reading padding bytes unsafe could be changed. This is a much larger project than simply changing some names in the standard library, but it has a similar time horizon to the full deprecation project proposed here.

### Keep the original names
If the behaviour of LLVM is unchanged, keeping the original names fails to signal unsafety in code that doesn't use the `-strict-memory-safety` mode. We wouldn't want to perpetuate this mistake.
