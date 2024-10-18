# Improving `String.Index`'s printed descriptions 

* Proposal: [SE-0445](0445-string-index-printing.md)
* Authors: [Karoy Lorentey](https://github.com/lorentey)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Status: **Implemented (Swift 6.1)**
* Implementation: [apple/swift#75433](https://github.com/swiftlang/swift/pull/75433)
* Review: ([pitch](https://forums.swift.org/t/improving-string-index-s-printed-descriptions/57027)) ([review](https://forums.swift.org/t/se-0445-improving-string-indexs-printed-descriptions/74643)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0445-improving-string-index-s-printed-descriptions/75108))
* Previous Revision: [v1](https://github.com/swiftlang/swift-evolution/blob/682f7c293a3a05bff3e619c3b479bfb68541fb6e/proposals/0445-string-index-printing.md)

## Introduction

This proposal conforms `String.Index` to `CustomDebugStringConvertible`.

## Motivation

String indices represent offsets from the start of the string's underlying storage representation, referencing a particular UTF-8 or UTF-16 code unit, depending on the string's encoding. (Most Swift strings are UTF-8 encoded, but strings bridged over from Objective-C may remain in their original UTF-16 encoded form.)

If you ever tried printing a string index, you probably noticed that the output is gobbledygook:

```swift
let string = "👋🏼 Helló"

print(string.startIndex) // ⟹ Index(_rawBits: 15)
print(string.endIndex) // ⟹ Index(_rawBits: 983047)
print(string.utf16.index(after: string.startIndex)) // ⟹ Index(_rawBits: 16388)
print(string.firstRange(of: "ell")!) // ⟹ Index(_rawBits: 655623)..<Index(_rawBits: 852487)
```

These displays are generated via the default reflection-based string conversion code path, which fails to produce a comprehensible result. Not being able to print string indices in a sensible way is needlessly complicating their use: it obscures what these things are, and it is an endless source of frustration while working with strings in Swift.

## Proposed solution

This proposal supplies the missing `CustomDebugStringConvertible` conformance on `String.Index`, resolving this long-standing issue.

```swift
let string = "👋🏼 Helló"

print(string.startIndex) // ⟹ 0[any]
print(string.endIndex) // ⟹ 15[utf8]
print(string.utf16.index(after: string.startIndex)) // ⟹ 0[utf8]+1
print(string.firstRange(of: "ell")!) // ⟹ 10[utf8]..<13[utf8]
```

The sample output strings shown above are illustrative, not normative. This proposal does not specify the exact format and information content of the string returned by the `debugDescription` implementation on `String.Index`. As is the case with most conformances to `CustomDebugStringConvertible`, the purpose of these descriptions is to expose internal implementation details for debugging purposes. As those implementation details evolve, the descriptions may need to be changed to match them. Such changes are not generally expected to be part of the Swift Evolution process; so we need to keep the content of these descriptions unspecified.

(With that said, the example displays shown above are not newly invented -- they have already proven their usefulness in actual use. They were developed while working on subtle string processing problems in Swift 5.7, and [LLDB has been shipping them as built-in data formatters][lldb] since the Swift 5.8 release.

In the displays shown, string indices succinctly display their storage offset, their expected encoding, and an (optional) transcoded offset value. For example, the output `15[utf8]` indicates that the index is addressing the code unit at offset 15 in a UTF-8 encoded `String` value. The `startIndex` is at offset zero, which works the same with _any_ encoding, so it is displayed as `0[any]`. As of Swift 6.0, on some platforms string instances may store their text in UTF-16, and so indices within such strings use `[utf16]` to specify that their offsets are measured in UTF-16 code units.

The `+1` in `0[utf8]+1` is an offset into a _transcoded_ Unicode scalar; this index addresses the trailing surrogate in the UTF-16 transcoding of the first scalar within the string, which has to be outside the Basic Multilingual Plane (or it wouldn't require surrogates). In our particular case, the code point is U+1F44B WAVING HAND SIGN, encoded in UTF-8 as `F0 9F 91 8B`, and in UTF-16 as `D83D DC4B`. The index is addressing the UTF-16 code unit `DC4B`, which does not actually exist anywhere in the string's storage -- it needs to be computed on every access, by transcoding the UTF-8 data for this scalar, and offsetting into the result.)

[lldb]: https://github.com/swiftlang/llvm-project/pull/5515

All of this is really useful information to see while developing or debugging string algorithms, but it is also deeply specific to the particular implementation of `String` that ships in Swift 6.0; therefore it is inherently unstable, and it may change in any Swift release.)

<!-- ``` -->
<!-- Characters: | 👋🏼                        | " " | H  | e  | l  | l  | ó     | -->
<!-- Scalars:    | 👋          | "\u{1F3FC}" | " " | H  | e  | l  | l  | ó     | -->
<!-- UTF-8:      | f0 9f 91 8b | f0 9f 8f bc | 20  | 48 | 65 | 6c | 6c | c3 b3 | -->
<!-- UTF-16:     | d83d dc4b   | d83c dffc   | 20  | 48 | 65 | 6c | 6c | f3    | -->
<!-- ``` -->

## Detailed design

```
@available(SwiftStdlib 6.1, *)
extension String.Index: CustomDebugStringConvertible {}

extension String.Index {
  @backDeployed(before: SwiftStdlib 6.1)
  public var debugDescription: String {...}
}
```

## Source compatibility

The new conformance changes the result of converting a `String.Index` value to a string. This changes observable behavior: code that attempts to parse the result of `String(describing:)` or `String(reflecting:)` can be mislead by the change of format.

However, the documentation of these interfaces explicitly state that when the input type conforms to none of the standard string conversion protocols, then the result of these operations is unspecified.

Changing the value of an unspecified result is not considered to be a source incompatible change.

## ABI compatibility

The proposal retroactively conforms a previously existing standard type to a previously existing standard protocol. This is technically an ABI breaking change -- on ABI stable platforms, we may have preexisting Swift binaries that assume that `String.Index is CustomDebugStringConvertible` returns `false`, or ones that are implementing this conformance on their own.

We do not expect this to be an issue in practice.

## Implications on adoption

The `String.Index.debugDescription` property is defined to be backdeployable, but the conformance itself is not. (It cannot be.)

Code that runs on ABI stable platforms will not get the nicer displays when running on earlier versions of the Swift Standard Library.

```swift
let str = "🐕 Doggo"
print(str.firstRange(of: "Dog")!)
// older stdlib: Index(_rawBits: 327943)..<Index(_rawBits: 524551)
// newer stdlib: 5[utf8]..<8[utf8]
```

This can be somewhat mitigated by explicitly invoking the `debugDescription` property, but this isn't recommmended as general practice.

```swift
print(str.endIndex.debugDescription) 
// always: 11[utf8]
```

## Future directions

### Additional `CustomStringConvertible` or `CustomDebugStringConvertible` conformances

Other preexisting types in the Standard Library may also usefully gain custom string conversions in the future:

- `Set.Index`, `Dictionary.Index`
- `Slice`, `DefaultIndices`
- `PartialRangeFrom`, `PartialRangeUpTo`, `PartialRangeThrough`
- `CollectionDifference`, `CollectionDifference.Index`
- `FlattenSequence`, `FlattenSequence.Index`
- `LazyPrefixWhileSequence`, `LazyPrefixWhileSequence.Index`
- etc.

### New String API to expose the information in these descriptions

The information exposed in the index descriptions shown above is mostly retrievable through public APIs, but not entirely: perhaps most importantly, there is no way to get the expected encoding of a string index through the stdlib's public API surface. The lack of such an API may encourage interested Swift developers to try retrieving this information by parsing the unstable `debugDescription` string, or by bitcasting indices to peek at the underlying bit patterns -- neither of which would be healthy for the Swift ecosystem overall. It therefore is desirable to eventually expose this information as well, through API additons like the drafts below:

```swift
extension String {
  @frozen enum StorageEncoding {
    case utf8
    case utf16
  }

  /// The storage encoding of this string instance. The encoding view
  /// corresponding to this encoding behaves like a random-access collection.
  /// 
  /// - Complexity: O(1)
  var encoding: StorageEncoding { get }
}

extension String.Index {
  /// The encoding of the string that produced this index, or nil if the 
  /// encoding is not known.
  /// 
  /// - Complexity: O(1)
  var encoding: String.StorageEncoding? { get }

  /// The offset of this position within the UTF-8 storage of the `String`
  /// instance that produced it. `nil` if the offset is not known to be valid
  /// in UTF-8 encoded storage.
  /// 
  /// - Complexity: O(1)
  @available(SwiftStdlib 5.7, *)
  var utf8Offset: Int? { get }

  /// The offset of this position within the UTF-16 storage of the `String`
  /// instance that produced it.  `nil` if the offset is not known to be valid
  /// in UTF-16 encoded storage.
  /// 
  /// - Complexity: O(1)
  @available(SwiftStdlib 5.7, *)
  var utf16Offset: Int? { get }
}
```

One major limitation is that string indices don't necessarily know their expected encoding, so the `encoding` property suggested above has to return an optional. (Indices of ASCII strings and the start index of all strings are the same no matter the encoding, and Swift runtimes prior to 5.7 did not track the encoding of string indices at all.) The `utf8Offset` and `utf16Offset` properties would correct and reinstate the functionality that got removed by [SE-0241] with the deprecation of `encodingOffset`.

[SE-0241]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0241-string-index-explicit-encoding-offset.md

Given that these APIs are quite obscure/subtle, and they pose some interesting design challenges on their own, these additions are deferred to a future proposal. The interface suggested above does not include exposing "transcoded offsets"; I expect the eventual proposal would need to cover those, too.

## Alternatives considered

The original version of this proposal suggested conforming `String.Index` to `CustomStringConvertible`, not `CustomDebugStringConvertible`. The change to the debug-flavored protocol emphasizes that the new descriptions aren't intended to be used outside debugging contexts.


## Acknowledgements

We'd like to express our appreciation to Jordan Rose and Ben Rimmington for scratching at the `CustomStringConvertible` vs `CustomDebugStringConvertible` distinction during the review discussion.
