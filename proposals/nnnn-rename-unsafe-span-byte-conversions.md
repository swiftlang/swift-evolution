# Rename some unsafe byte-conversion API of the `Span` family

* Proposal: [SE-NNNN](nnnn-rename-unsafe-span-byte-conversions.md)
* Authors: [Guillaume Lessard](https://github.com/glessard)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: **Awaiting implementation**
* Review: ([pitch](https://forums.swift.org/t/88498))

[SE-0525]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0525-rawspan-safe-loading-api.md
[vision]: https://github.com/swiftlang/swift-evolution/blob/main/visions/memory-safety.md

## Summary of changes

Rename some computed properties and functions that reinterpret memory as bytes, which were marked as `@unsafe` after their initial proposals. The updated names will suggest that their operations aren't hazard-free even when the compiler emits no warnings for unsafe code.

## Motivation

[SE-0525][SE-0525] formalized the parameters for safely interpreting typed memory as bytes, and vice versa. Prior to that proposal, we introduced some API that perform byte conversions, but didn't name them with the appropriate strictness. It is a convention of the Swift project, as stated in the [strict memory safety vision][vision], to clearly name unsafe API with specific words to denote a hazard, such as "unsafe" in `UnsafePointer`, or "unchecked" in `Range.init(uncheckedBounds:)`. A few API from the `Span` family have not met this bar, as their names carry no indication of hazard at all.

[SE-0525][SE-0525] introduced safe counterparts to these API, by overloading them with tighter generic constraints. As a result, code that uses the looser (and unsafe) constraint reads identically to the safe code. Without `-strict-memory-safety`, a user can end up using unsafe code without meaning to.

We believe that, ideally, the API we propose to rename should not have to be marked with `@unsafe`. LLVM's treatment of this situation makes them technically unsafe, and future improvements should remove the memory-safety concerns. Even after the unsafety is removed, we need to convey that the values of the bytes available for reading may not all have been set by the running program.

## Proposed solution

This proposal addresses the naming deficiencies of the earlier API. We introduce new names for these unsafe API, along with deprecations of the original names, deferred to a future language mode.
- `bytes` → `paddedBytes`
- `mutableBytes` → `unsafeMutableBytes`
- `storeBytes(of:toByteOffset:as:)` → `storeBytes(paddedBytes:toByteOffset:as:)`
- `storeBytes(repeating:count:as:)` → `storeBytes(repeatingPaddedBytes:count:as:)`
- `append(_:as:)` → `append(paddedBytes:as:)`
- `append(repeating:count:as:)` → `append(repeatingPaddedBytes:count:as:)`

We are proposing the word "padded" to denote a possible hazard where some of the bytes being read or written may have values that haven't been explicitly set by the running program. Such bytes can lead to potential correctness issues if they are used to drive program state, and it is worth denoting the points at which they could be introduced. It is used for conversions where the safe equivalent only adds a `ConvertibleToBytes` constraint. The word chosen also indicates that this hazard is milder than the memory unsafety denoted by "unsafe".

## Detailed design

The `@unsafe` declarations are renamed as follows (omitting lifetime and inlining attributes for brevity):

```swift
extension Span {
  @unsafe var paddedBytes: RawSpan { get }
}
```

```swift
extension MutableSpan {
  @unsafe var paddedBytes: RawSpan { borrowing get }
}

extension MutableSpan where Element: BitwiseCopyable {
  @unsafe var unsafeMutableBytes: MutableRawSpan { mutating get }
}
```

```swift
extension MutableRawSpan {
  @unsafe mutating func storeBytes<T: BitwiseCopyable>(
    paddedBytes value: T, toByteOffset offset: Int, as type: T.Type
  )

  @unsafe mutating func storeBytes<T: BitwiseCopyable>(
    repeatingPaddedBytes repeatedValue: T, count: Int, as type: T.Type
  )
}
```

`MutableRawSpan` has a third `@unsafe` overload of `storeBytes` which omits bounds-checking (`storeBytes(of:toUncheckedByteOffset:as:)`). We do not propose to rename it, because the bounds-checking unsafety is more serious than the padding hazard, and there is no confusable overload that could overstate safety.

```swift
extension OutputRawSpan {
  @unsafe mutating func append<T: BitwiseCopyable>(
    paddedBytes value: T, as type: T.Type
  )

  @unsafe mutating func append<T: BitwiseCopyable>(
    repeatingPaddedBytes repeatedValue: T, count: Int, as type: T.Type
  )
}
```

Each original name is retained, with a deprecation scheduled for a future Swift language mode. This will discourage IDEs from suggesting the deprecated symbols, while avoiding the immediate appearance of warnings until a new language mode is introduced.

```swift
extension Span where Element: BitwiseCopyable {
  @available(swift, deprecated: 9999, renamed: "paddedBytes")
  @unsafe var bytes: RawSpan { get }
}

extension MutableSpan where Element: BitwiseCopyable {
  @available(swift, deprecated: 9999, renamed: "paddedBytes")
  @unsafe var bytes: RawSpan { borrowing get }

  @available(swift, deprecated: 9999, renamed: "unsafeMutableBytes")
  @unsafe var mutableBytes: MutableRawSpan { mutating get }
}

extension MutableRawSpan {
  @available(swift, deprecated: 9999, renamed: "storeBytes(paddedBytes:toByteOffset:as:)")
  @unsafe mutating func storeBytes<T: BitwiseCopyable>(
    of value: T, toByteOffset offset: Int, as type: T.Type
  )

  @available(swift, deprecated: 9999, renamed: "storeBytes(repeatingPaddedBytes:count:as:)")
  @unsafe mutating func storeBytes<T: BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
}

extension OutputRawSpan {
  @available(swift, deprecated: 9999, renamed: "append(paddedBytes:as:)")
  @unsafe mutating func append<T: BitwiseCopyable>(
    _ value: T, as type: T.Type
  )

  @available(swift, deprecated: 9999, renamed: "append(repeatingPaddedBytes:count:as:)")
  @unsafe mutating func append<T: BitwiseCopyable>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  )
}
```

<details>
<summary>Safe SE-0525 additions</summary>

For reference, here are the safe additions from [SE-0525][SE-0525] that improve on the symbols deprecated above:

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

extension MutableRawSpan {
  mutating func storeBytes<T>(
    of value: T, toByteOffset offset: Int, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  mutating func storeBytes<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable
}

extension OutputRawSpan {
  mutating func append<T>(
    _ value: T, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable

  mutating func append<T>(
    repeating repeatedValue: T, count: Int, as type: T.Type
  ) where T: ConvertibleToBytes & BitwiseCopyable
}
```

</details>

### Deciding which word applies to an API

For an API that reinterprets typed memory as bytes or vice versa, it is useful to state which word applies. When the memory of a type that does not conform to `ConvertibleToBytes` is interpreted as bytes, then some of those bytes may not have been set and the word "padded" applies. When bytes are interpreted as an instance of a type that does not conform to `ConvertibleFromBytes`, then some resulting values may be invalid and the word "unsafe" applies (e.g. `RawSpan.unsafeLoad(fromByteOffset:as:)`).

A single API may carry multiple hazards; its name uses only the strongest applicable word. "unsafe" is stronger than "unchecked", which is stronger than "padded".

## Source compatibility

This change is source-compatible. The new deprecation warnings will appear when compiled under a future language mode.

## ABI compatibility

The affected symbols do not have an ABI and do not require a change in deployment target.

## Implications on adoption

Adopters should migrate to the new names, and the deprecated aliases allow incremental adoption. The long deprecation window is intended to help package authors who support multiple recent Swift versions. By the time the deprecation becomes active and the compiler issues warnings, both names will have been available for multiple releases, and adopting the new name should not force actively supported packages to raise their minimum tools version.

## Future directions

### Change the behaviour of LLVM to make the renamed symbols safe

The behaviour of LLVM which makes reading padding bytes unsafe could be changed. This is a much larger project than simply changing some names in the standard library, but it has a similar time horizon to the full deprecation project. We expect such a change would be complementary to the name change proposed here, and would allow the `@unsafe` attribute to be removed from the renamed symbols.

## Alternatives considered

### Remove the symbols instead of renaming them

This would do more harm than good. These symbols have legitimate use cases that benefit from not requiring the closure-based `withUnsafe*Bytes` spelling. This logic also applies to the idea of deprecating the symbols without renaming them.

### Keep the original names

Doing nothing leaves each of these API spelled the same as their safe counterparts from [SE-0525][SE-0525], and nothing would distinguish them in code that doesn't use `-strict-memory-safety`. Note that this would get worse if LLVM's behaviour is changed and the `@unsafe` attribute dropped, as the only distinction would be gone. We do not want to perpetuate this mistake.

### Use `unsafe` in all the new names

This proposal was originally pitched with `unsafeBytes`, `append(unsafeBytes:as:)` and `append(repeatingUnsafeBytes:count:as:)`. These names apply the project's existing naming convention in the most direct way, but suggest a higher level of unsafety than we would achieve once LLVM's behaviour is changed to remove the memory unsafety.

Ultimately, we expect these operations to not involve memory unsafety at all. However, they do introduce a correctness hazard as the value of some of the bytes may not have been determined by the running program. Names are much harder to change than attributes, and "unsafe" in the name would ultimately overstate the hazard it describes. In the meantime the `@unsafe` attribute will continue to indicate the memory-safety issues, until it can be removed.

### Additionally rename `RawSpan.init(unsafeElements:)`

In [SE-0525][SE-0525], two unsafe initializers (one each for `RawSpan` and for `MutableRawSpan`) were added with the label `unsafeElements`. This label marks the same hazard as we are marking in this proposal with the word "padded". While it would be better to have perfectly consistent naming, these names do not have the same problem as the symbols being deprecated, in that they contain a hazard word ("unsafe") even though it may be stronger than necessary. There is no ambiguity with a safe overload, and as such it is reasonable to keep those names.

### Alternate hazard words

A few alternate labels were suggested in the pitch thread alongside `paddedBytes`, such as `unspecifiedBytes`, `bytesWithArbitraryPadding`, `sparseBytes` and `arbitrarilyPaddedBytes`. We chose `paddedBytes` because it is relatively brief and specific. The words "unspecified" and "sparse" in particular feel like qualifiers for all of the bytes involved.

## Acknowledgments

Thanks to Jeremy Schonfeld, Xiaodi Wu and Doug Gregor for discussing and suggesting alternate labels.
