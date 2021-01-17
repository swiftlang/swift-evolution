# Adding `isMultiple` to `BinaryInteger`

* Proposal: [SE-0225](0225-binaryinteger-iseven-isodd-ismultiple.md)
* Authors: [Robert MacEachern](https://github.com/robmaceachern), [Micah Hansonbrook](https://github.com/SiliconUnicorn)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 5)** (with modifications, see Implementation Notes)
* Implementation: [apple/swift#18689](https://github.com/apple/swift/pull/18689)
* Review: [Discussion thread](https://forums.swift.org/t/se-0225-adding-iseven-isodd-ismultiple-to-binaryinteger/15382), [Announcement thread](https://forums.swift.org/t/accepted-with-modifications-se-0225-adding-iseven-isodd-ismultiple-to-binaryinteger/15689)

Note: the title of this proposal has been modified to reflect what was accepted.  The original title was "Adding `isEven`, `isOdd`, and `isMultiple` to `BinaryInteger`".

## Introduction

This proposal adds `var isEven: Bool`, `var isOdd: Bool`, and `func isMultiple(of other: Self) -> Bool` to the `BinaryInteger` protocol. `isEven` and `isOdd` are convenience properties for querying the [parity](https://en.wikipedia.org/wiki/Parity_(mathematics)) of the integer and `isMultiple` is a more general function to determine whether an integer is a multiple of another integer.

Swift-evolution thread: [Even and Odd Integers](https://forums.swift.org/t/even-and-odd-integers/11774)

## Motivation

It is sometimes necessary to know whether or not an integer is a multiple of another. The most common case is testing if a value is a multiple of 2 (even and oddness).

**Commonality:** Testing if a value is a multiple of another shows up in a surprising number of contexts including UI code, algorithm implementations (often in the form of assertions), tests, benchmarks, documentation and tutorial/educational code.

Currently, the most common way to test if a value is a multiple is by using the remainder operator (`%`) checking for a remainder of zero: `12 % 2 == 0 // returns true. 12 is a multiple of 2`. Similarly, testing that a value is _not_ a multiple of another is done by checking for a remainder other than zero: `13 % 2 != 0 // returns true. 13 is not a multiple of 2`.

Alternatively, it is also possible to use the bitwise AND operator (`&`) to check the even/oddness of a value: `12 & 1 == 0 // returns true`.

Some examples of testing multiples in code (see more in appendix):

```swift
// UITableView alternating row colour
cell.contentView.backgroundColor = indexPath.row % 2 == 0 ? .gray : .white

// Codable.swift.gyb in apple/swift
guard count % 2 == 0 else { throw DecodingError.dataCorrupted(...) }

// Bool.swift in apple/swift
public static func random<T: RandomNumberGenerator>(using generator: inout T) -> Bool {
    return (generator.next() >> 17) & 1 == 0
}

// KeyPath.swift in apple/swift
_sanityCheck(bytes > 0 && bytes % 4 == 0, "capacity must be multiple of 4 bytes")

// ReversedCollection Index.base documentation https://developer.apple.com/documentation/swift/reversedcollection/index/2965437-base
guard let i = reversedNumbers.firstIndex(where: { $0 % 2 == 0 })
```

Determining whether a value is even or odd is a common question across programming languages, at least based on these Stack Overflow questions:
[c - How do I check if an integer is even or odd?](https://stackoverflow.com/questions/160930/how-do-i-check-if-an-integer-is-even-or-odd) 300,000+ views
[java - Check whether number is even or odd](https://stackoverflow.com/questions/7342237/check-whether-number-is-even-or-odd) 350,000+ views
[Check if a number is odd or even in python](https://stackoverflow.com/questions/21837208/check-if-a-number-is-odd-or-even-in-python) 140,000+ views

Convenience properties or functions equivalent to `isEven` and `isOdd` are available in the standard libraries of many other programming languages, including: [Ruby](https://ruby-doc.org/core-2.2.2/Integer.html#method-i-odd-3F), [Haskell](http://hackage.haskell.org/package/base-4.11.1.0/docs/Prelude.html#v:even), [Clojure](https://clojuredocs.org/clojure.core/odd_q), and according to [RosettaCode](https://www.rosettacode.org/wiki/Even_or_odd): Julia, Racket, Scheme, Smalltalk, Common Lisp.

**Readability:** This proposal significantly improves readability, as expressions read like straightforward English sentences. There is no need to mentally parse and understand non-obvious operator precedence rules (`%` has higher precedence than `==`).

The `isEven` and `isOdd` properties are also fewer characters wide than the remainder approach (maximum 7 characters for `.isEven` vs 9 for ` % 2 == 0`) which saves horizontal space while being clearer in intent.

```swift
// UITableView alternating row colour
cell.contentView.backgroundColor = indexPath.row.isEven ? .gray : .white

// Codable.swift.gyb in apple/swift
guard count.isEven else { throw DecodingError.dataCorrupted(...) }

// Bool.swift in apple/swift
public static func random<T: RandomNumberGenerator>(using generator: inout T) -> Bool {
    return (generator.next() >> 17).isEven
}

// KeyPath.swift in apple/swift
_sanityCheck(bytes > 0 && bytes.isMultiple(of: 4), "capacity must be multiple of 4 bytes")
```

**Discoverability:** IDEs will be able to suggest `isEven`, `isOdd`, and `isMultiple` as part of autocomplete on integer types which will aid discoverability. It will also be familiar to users coming from languages that also support functionality similar to `isEven` and `isOdd`.

**Trivially composable:** It would be relatively easy to reproduce the proposed functionality in user code but there would be benefits to having a standard implementation. It may not be obvious to some users exactly which protocol these properties belong on (`Int`?, `SignedInteger`?, `FixedWidthInteger`?, `BinaryInteger`?). This inconsistency can be seen in a [popular Swift utility library](https://github.com/SwifterSwift/SwifterSwift/blob/9eb6259faf6689a161825cc91cccec0c82edea8d/Sources/Extensions/SwiftStdlib/SignedIntegerExtensions.swift#L28) which defines `isEven` and `isOdd` on `SignedInteger` which results in the properties being inaccessible for unsigned integers.

Testing the parity of integers is also relatively common in sample code and educational usage. In this context, it’s usually not appropriate for an author to introduce this functionality (unless they are teaching extensions!) in order to avoid distracting from the main task at hand (e.g. filter, map, etc). It may also be the same situation for authoring test code: it'd be used if it existed but it's not worth the overhead of defining it manually.

This functionality will also eliminate the need to use the remainder operator or bitwise AND when querying the divisibility of an integer.

**Correctness:** It isn't [uncommon](https://github.com/apple/swift/blob/4a43ee83e701145d69141adca311497c082b7170/stdlib/public/core/RangeReplaceableCollection.swift#L1090) to see tests for oddness written as `value % 2 == 1` in Swift, but this is incorrect for negative odd values. The semantics of the `%` operator vary between programming languages, such as Ruby and Python, which can be surprising.

```
// Swift:
7 % 2 == 1 // true
-7 % 2 == 1 // false. -7 % 2 evaluates to -1

// Ruby and Python
7 % 2 == 1 // true
-7 % 2 == 1 // true
```

The `%` operator will also trap when the righthand side is zero. The proposed solution does not.

There is also a minor correctness risk in misinterpreting something like `value % 2 == 0`, particularly when used in a more complex statement, when compared to `value.isEven`, e.g. `bytes > 0 && bytes % 4 == 0`.

**Performance:** It's _possible_ that `isMultiple` could be implemented in a more performant way than `% divisor == 0` for more complex types, such as a BigInteger/BigNum type.

The addition of `isEven` and `isOdd` likely won’t have a major positive impact on performance but it should not introduce any additional overhead thanks to `@_transparent`.

## Proposed solution

Add two computed properties, `isEven` and `isOdd`, and a function `isMultiple` to the `BinaryInteger` protocol.

```swift
// Integers.swift.gyb
// On protocol BinaryInteger

    @_transparent
    public var isEven: Bool { return _lowWord % 2 == 0 }

    @_transparent
    public var isOdd: Bool { return !isEven }

    func isMultiple(of other: Self) -> Bool
```

## Detailed design

N/A

## Source compatibility

This is strictly additive.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

### `isDivisible` instead of `isMultiple`

The original discussions during the pitch phase where related to an `isDivisible(by:)` alternative to `isMultiple`. [Issues](https://forums.swift.org/t/even-and-odd-integers/11774/83) related to divisibility and division by zero were discussed and `isMultiple` was proposed as a solution that 1) avoids trapping on zero, and 2) avoids confusion where a value that is _divisible_ by zero would not be _dividable_ in Swift. e.g.

```
let y = 0
if 10.isDivisible(by: y) {
	let val = 10 / y // traps
}
```

### Only `isEven/isOdd` or only `isMultiple`.

During the pitch phase there were discussions about including only one of `isEven/isOdd` or `isMultiple` in the proposal.

On the one hand there were concerns that `isEven/isOdd` would not provide enough utility to justify inclusion into the standard library and that `isMultiple` was preferable as it was more general. `isEven/isOdd` are also trivial inverses of each other which Swift, as a rule, doesn't include in the standard library.

On the other hand there was some unscientific analysis that indicated that even/oddness accounted for 60-80% of the operations in which the result of the remainder operator was compared against zero. This lent some support to including `isEven/isOdd` over `isMultiple`. There is also more precedence in other languages for including `isEven/isOdd` over `isMultiple`.

The authors decided that both were worthy of including in the proposal. Odd and even numbers have had special [shorthand labels](http://mathforum.org/library/drmath/view/65413.html) for thousands of years and are used frequently enough to justify the small additional weight `isEven/isOdd` would add to the standard library. `isMultiple` will greatly improve clarity and readability for arbitrary divisibility checks and also avoid potentially surprising `%` operator semantics with negative values.

## Implementation Notes

Only `isMultiple(of:)` was approved during review, so the final implementation does not include `isEven` or `isOdd`. Two default implementations are provided in the standard library; one on `BinaryInteger` and one on `FixedWidthInteger & SignedInteger`. For concrete signed and unsigned fixed-size integers, like the standard library types, these two implementations should be nearly optimal.

For some user-defined types, especially bignum types, you may want to implement your own conformance for this function. Specifically, if your type does not have bounded min and max values, you should be able to do the divisibility check directly on the values rather than on the magnitudes, which may be more efficient.

## Appendix

### Other example uses in code (and beyond)

* `% 2 == 0` appears 63 times in the [Apple/Swift](https://github.com/apple/swift) repository.
* [Initializing a cryptographic cipher](https://github.com/krzyzanowskim/CryptoSwift/blob/31efdd85ceb4190ee358a0516c6e82d8fd7b9377/Sources/CryptoSwift/Rabbit.swift#L89)
* Colouring a checker/chess board and [determining piece colour](https://github.com/nvzqz/Sage/blob/dec5edd97ba45d46bf94bc2e264d3ce2be6404ad/Sources/Piece.swift#L276)
* Multiple occurrences in cpp Boost library. [Example: handleResizingVertex45](https://www.boost.org/doc/libs/1_62_0/boost/polygon/polygon_45_set_data.hpp)
* Alternating bar colours in a chart
* [VoronoiFilter implementation](https://github.com/BradLarson/GPUImage/blob/167b0389bc6e9dc4bb0121550f91d8d5d6412c53/framework/Source/GPUImageJFAVoronoiFilter.m#L428) and [PoissonBlendFilter](https://github.com/BradLarson/GPUImage/blob/167b0389bc6e9dc4bb0121550f91d8d5d6412c53/framework/Source/GPUImagePoissonBlendFilter.m#L142)
* [Image blurring library](https://github.com/nicklockwood/FXBlurView/blob/9530adfc62fa682d0d8b3f612d3bb3af7a60ab7e/FXBlurView/FXBlurView.m#L58)
* UPC check digit calculation [(spec)](http://www.gs1.org/how-calculate-check-digit-manually) (values in odd digit indices are multiplied by 3)
* [Precondition check in sqlite function](https://github.com/sqlcipher/sqlcipher/blob/c6f709fca81c910ba133aaf6330c28e01ccfe5f8/src/crypto_impl.c#L1296)
* [Alternating UITableView cell background style](https://github.com/alloy/HockeySDK-CocoaPods/blob/978f3f072d206cfa35f4789d3a5b3abb31b9df11/Pods/HockeySDK/Classes/BITFeedbackListViewController.m#L502). NSTableView [has built in support](https://developer.apple.com/documentation/appkit/nstableview/1533967-usesalternatingrowbackgroundcolo?language=objc) for this.
* [Barcode reading](https://github.com/TheLevelUp/ZXingObjC/blob/d952cc02beb948ab49832661528c5e3e4953885e/ZXingObjC/oned/rss/expanded/ZXRSSExpandedReader.m#L449)
* [CSS row and column styling](https://www.w3.org/Style/Examples/007/evenodd.en.html) with `nth-child(even)` and `nth-child(odd)` (h/t @beccadax)
* Various test code

Some _really_ real-world examples:
* [Printing even or odd pages only](https://i.stack.imgur.com/TE4Xn.png)
* New [Hearthstone even/odd cards](https://blizzardwatch.com/2018/03/16/hearthstones-new-even-odd-cards-going-shake-meta/)
* A variety of [even-odd rationing](https://en.m.wikipedia.org/wiki/Odd–even_rationing) rules: [parking rules](https://www.icgov.org/city-government/departments-and-divisions/transportation-services/parking/oddeven-parking), [water usage restrictions](https://vancouver.ca/home-property-development/understanding-watering-restrictions.aspx), [driving restrictions](https://auto.ndtv.com/news/odd-even-in-delhi-5-things-you-need-to-know-1773720)
