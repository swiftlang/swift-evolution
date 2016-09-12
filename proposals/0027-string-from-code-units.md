# Expose code unit initializers on String

* Proposal: [SE-0027](0027-string-from-code-units.md)
* Author: [Zachary Waldowski](https://github.com/zwaldowski)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-February/000044.html)

## Introduction

Going back and forth from Strings to their byte representations is an important part of solving many problems, including object serialization, binary and text file formats, wire/network interfaces, and cryptography. Swift has such utilities, but currently only exposed through `String.Type.fromCString(_:)` and `String.Type.fromCStringRepairingIllFormedUTF8(_:)`.

See swift-evolution [thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005951.html) and [draft proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006295.html).

## Motivation

In developing a parser, a coworker did the yeoman's work of benchmarking Swift's Unicode types. He swore up and down that `String.Type.fromCString(_:)` ([use](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-fromcstring-swift)) was the fastest way he found. I, stubborn and noobish as I am, was skeptical that a better way couldn't be wrought from Swift's `UnicodeCodecType`s.

After reading through stdlib source and doing my own testing, this is no wives' tale. `fromCString` is essentially the only public-facing user of `String.Type._fromCodeUnitSequence(_:input:)`, which serves the exact role of both efficient and safe initialization-by-buffer-copy. After many attempts, I've concluded that the currently available `String` APIs are deficient, as they provide much worse performance without guaranteeing more Unicode safety.

Of course, `fromCString(_:)` isn't a silver bullet; it forces a UTF-8 encoding with a null sentinel, requiring either a copy of the origin buffer or regressing to the much slower character-by-character append path if a terminator needs to be added. This is the case with formats that specify the length up front, or unstructured payloads that use another terminator). It also prevents the string itself from containing the null character. Finally, the `fromCString(_:)` constructor requires a call to `strlen`, even if that's already been calculated in users' code.

## Proposed solution

I'd like to expose an equivalent to `String.Type._fromCodeUnitSequence(_:input:)` as public API:

```swift
static func decode<Encoding: UnicodeCodecType, Input: CollectionType where Input.Generator.Element == Encoding.CodeUnit>(_: Input, as: Encoding.Type, repairingInvalidCodeUnits: Bool = default) -> (result: String, repairsMade: Bool)?
```

For convenience, the `Bool` flag here is also separated out to a more common-case pair of `String` initializers:

```
init<...>(codeUnits: Input, as: Encoding.Type)
init?<...>(validatingCodeUnits: Input, as: Encoding.Type)
```

Finally, for more direct compatibility with `String.Type.fromCString(_:)` and `String.Type.fromCStringRepairingIllFormedUTF8(_:)`, these constructors are overloaded for pointer-based strings of unknown length:

```swift
init(cString: UnsafePointer<CChar>)
init?(validatingCString: UnsafePointer<CChar>)
```

## Detailed design

See [full implementation](https://github.com/apple/swift/compare/master...zwaldowski:string-from-code-units).

We start by backporting the [Swift 3.0](https://github.com/apple/swift/commit/f4aaece75e97379db6ba0a1fdb1da42c231a1c3b) versions of the `CString` constructors, then making them generic over their input and codec.

This is a fairly straightforward renaming of the internal APIs. The initializer, its labels, and their order were chosen to match other non-cast initializers in the stdlib. "Sequence" was removed, as it was a misnomer. "input" was kept as a generic name in order to allow for future refinements.

These new constructors swap the expectations for the default: `fromCString` could fail on invalid code unit sequences, but `init(cString:)` will unconditionally succeed. This, as developed against Swift 3, should "most probably [be] the right thing".

The backported constructors follow the Swift 3.0 naming guidelines, and presumably won't require any more changes after implementing this proposal.

The new API has overloads that continue to work the old `strlen` way, while allowing users to specify arbitrary code unit sequences through `UnsafeBufferPointer`. Low-level performance benefits like these are extremely important to performance-sensitive code. In the case of reading from buffers of unknown length, keeping copies low is vital.

The use of `String.Type._fromWellFormedCodeUnitSequence(_:input:)` was replaced with the new public API.

## Impact on existing code

`String.Type.fromCString(_:)` and `String.Type.fromCStringRepairingIllFormedUTF8(_:)` are replaced with `String.init(validatingCString:)` and `String.init(cString:)`, respectively. Do note that this is a reversal of the default expectations, as discussed above.

The old methods refer to the new signatures using deprecation attributes, presumably for removal in Swift 3.0.

## Alternatives considered

* Do nothing.

This seems suboptimal. For many use cases, `String` lacking this constructor is a limiting factor on performance for many kinds of pure-Swift implementations.

* A `String.UTF8View` and `String.UTF16View` solution

(See also "Make `String.append(_:)` faster")

Make `String.UTF8View` and `String.UTF16View` mutable (a la `String.UnicodeScalarView`) with amortized O(1) `append(_:)`/`appendContentsOf(_:)`. At least on the `String.UTF16View` side, this would be a simple change lifting the `append(_:)` from `String.UnicodeScalarView`. This would serve advanced use cases well, including supplanting `String.Type._fromWellFormedCodeUnitSequence(_:input:)`.

This might be the better long-term solution from the perspective of API maintenance, but in the meantime this proposal has a fairly low impact.

* A protocol-oriented API.

Some kind of `func decode<Encoding>(_:)` on `SequenceType`. It's not really clear this method would be related to string processing, and would require some kind of bounding (like `where Generator.Element: UnsignedIntegerType`), but that would be introducing a type bound that doesn't exist already.

* Make the `NSString` [bridge faster](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-nsstring-swift).

After reading the bridge code, I don't really know why it's slower. Maybe it's a bug.

* Make `String.append(_:)` [faster](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-unicodescalar-swift).

I don't completely understand the growth strategy of `_StringCore`, but it doesn't seem to exhibit the documented amortized `O(1)`, even when `reserveCapacity(_:)` is used. In the pre-proposal discussion, a user noted that it seems like `reserveCapacity` acts like a no-op.

