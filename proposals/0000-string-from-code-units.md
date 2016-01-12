# Expose code unit initializers on String

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-string-from-code-units.md)
* Author: [Zachary Waldowski](https://github.com/zwaldowski)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Going back and forth from Strings to their byte representations is an important part of solving many problems, including object serialization, binary and text file formats, wire/network interfaces, and cryptography. Swift has such utilities, currently only exposed through `String.Type.fromCString(_:)`.

See swift-evolution [thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005951.html).

## Motivation

In developing a parser, a coworker did the yeoman's work of benchmarking Swift's Unicode types. He swore up and down that `String.Type.fromCString(_:)` ([use](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-fromcstring-swift)) was the fastest way he found. I, stubborn and noobish as I am, was skeptical that a better way couldn't be wrought from Swift's `UnicodeCodecType`s.

After reading through stdlib source and doing my own testing, this is no wives' tale. `fromCString` is essentially the only public-facing user of `String.Type._fromCodeUnitSequence(_:input:)`, which serves the exact role of both efficient and safe initialization-by-buffer-copy. After many attempts, I've concluded that the currently available `String` APIs are deficient, as they provide much worse performance without guaranteeing more Unicode safety.

Of course, `fromCString(_:)` isn't a silver bullet; it has to have a null sentinel, and forces a UTF-8 encoding. This requires either a copy of the origin buffer if a terminator needs to be added or the much slower character-by-character append path, as is the case with formats that specify the length up front, or unstructured payloads that use unescaped double quotes as the terminator. It also prevents the string itself from containing the null character. Finally, the `fromCString(_:)` constructor requires a call to `strlen`, even if that's already been calculated in client

# Proposed solution

I'd like to expose `String.Type._fromCodeUnitSequence(_:input:)` as public API:

```swift
init?<Input: CollectionType, Encoding: UnicodeCodecType where Encoding.CodeUnit == Input.Generator.Element>(codeUnits input: Input, encoding: Encoding.Type)
```

And, for consistency with `String.Type.fromCStringRepairingIllFormedUTF8(_:)`,
exposing `String.Type._fromCodeUnitSequenceWithRepair(_:input:)`:

```swift
static func fromCodeUnitsWithRepair<Input: CollectionType, Encoding: UnicodeCodecType where Encoding.CodeUnit == Input.Generator.Element>(input: Input, encoding: Encoding.Type)
```

## Detailed design

See [full implementation](https://github.com/apple/swift/compare/master...zwaldowski:string-from-code-units).

This is a fairly straightforward renaming of the internal APIs.

The initializer, its labels, and their order were chosen to match other non-cast initializers in the stdlib. "Sequence" was removed, as it was a misnomer. "input" was kept as a generic name in order to allow for future refinements.

The static initializer made the same changes, but was otherwise kept as a factory function due to its multiple return values.

`String.Type._fromWellFormedCodeUnitSequence(_:input:)` was kept as-is for internal use. I assume it wouldn't be good to expose publicly because, for lack of a better phrase, we only "trust" the stdlib to accurately know the wellformedness of their code units. Since it is a simple call through, its use could be elided throughout the stdlib.

The new exposure can continue to work the old way through the use of `strlen`, while also allowing users to specify arbitrary code unit sequences through `UnsafeBufferPointer`.

Low-level performance benefits like these are extremely important to performance-sensitive code. In the case of reading from buffers of unknown length, keeping copies low is vital.

## Impact on existing code

This is an additive change to the API.

## Alternatives considered

* Do nothing.

This seems suboptimal. For many use cases, `String` lacking this constructor is
a limiting factor on performance for many kinds of pure-Swift implementations.

* Adapt `fromCString(_:)`.

Seems to be the tack taken in [Swift 3](https://github.com/apple/swift/commit/f4aaece75e97379db6ba0a1fdb1da42c231a1c3b) thus far. That's less API surface area, and with internal clients using the same public API. That would constitute an API change, though.

* A protocol-oriented API.

Some kind of `func decode<Encoding>(_:)` on `SequenceType`. It's not really clear this method would be related to string processing, and would require some kind of bounding (like `where Generator.Element: UnsignedIntegerType`), but that would be introducing a type bound that doesn't exist already.

* Make the `NSString` [bridge faster](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-nsstring-swift).

After reading the bridge code, I don't really know why it's slower. Maybe it's a bug.

* Make `String.append(_:)` [faster](https://gist.github.com/zwaldowski/5f1a1011ea368e1c833e#file-unicodescalar-swift).

I don't completely understand the growth strategy of `_StringCore`, but it doesn't seem to exhibit the documented amortized `O(1)`, even when `reserveCapacity(_:)` is used. In the pre-proposal discussion, a user noted that it seems like `reserveCapacity` acts like a no-op.

