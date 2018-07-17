# Adding `isEven` and `isOdd` properties to `BinaryInteger`

* Proposal: [SE-NNNN](NNNN-binaryinteger-iseven-isodd.md)
* Authors: [Robert MacEachern](https://robmaceachern.com), [SiliconUnicorn](https://forums.swift.org/u/siliconunicorn/summary)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

We propose adding `var isEven: Bool` and `var isOdd: Bool` to `BinaryInteger`. These are convenience properties for querying the [parity](https://en.wikipedia.org/wiki/Parity_(mathematics)) of the integer.

Swift-evolution thread: [Even and Odd Integers](https://forums.swift.org/t/even-and-odd-integers/11774)

## Motivation

It is sometimes useful to know the evenness or oddness (parity) of an integer and switch the behaviour based on the result. The most typical way to do this is using `value % 2 == 0` to determine if `value` is even, or `value % 2 != 0` to determine if `value` is odd.

```swift
// Gray background for even rows, white for odd.
view.backgroundColor = indexPath.row % 2 == 0 ? .gray : .white

// Enable button if we have odd number of photos
buttonSave.isEnabled = photos.count % 2 != 0
```

It is also possible to use the bitwise AND operator (`value & 1 == 0`) which will inevitably lead to discussions about which one is faster and attempts at profiling them, etc, etc.

There are a few more specific motivations for this proposal:

### Commonality

The need to determine the parity of an integer isn’t restricted to a limited problem domain.

### Readability

This proposal significantly improves readability.  There is no need to understand operator precedence rules (`%` has higher precedence than `==`) which are non-obvious.

The properties are also fewer characters wide than the modulus approach (maximum 7 characters for `.isEven` vs 9 for ` % 2 == 0`) which saves horizontal space while being clearer in intent.
```swift
view.backgroundColor = indexPath.row % 2 == 0 ? .gray : .white
view.backgroundColor = indexPath.row.isEven ? .gray : .white

buttonSave.isEnabled = photos.count % 2 != 0
buttonSave.isEnabled = photos.count.isOdd
```

### Discoverability

Determining whether a value is even or odd is a common question across programming languages, at least based on these Stack Overflow questions:
[c - How do I check if an integer is even or odd?](https://stackoverflow.com/questions/160930/how-do-i-check-if-an-integer-is-even-or-odd) 300,000+ views
[java - Check whether number is even or odd](https://stackoverflow.com/questions/7342237/check-whether-number-is-even-or-odd) 350,000+ views
[Check if a number is odd or even in python](https://stackoverflow.com/questions/21837208/check-if-a-number-is-odd-or-even-in-python) 140,000+ views

IDEs will be able to suggest `.isEven` and `.isOdd` as part of autocomplete which will aid discoverability.

### Consistency

It would be relatively easy to reproduce the properties in user code but there would be benefits to having a standard implementation. It may not be obvious to some users exactly which protocol these properties belong on (`Int`?, `SignedInteger`?, `FixedWidthInteger`?, `BinaryInteger`?). This inconsistency can be seen in a [popular Swift utility library](https://github.com/SwifterSwift/SwifterSwift/blob/master/Sources/Extensions/SwiftStdlib/SignedIntegerExtensions.swift#L28) which defines these properties on `SignedInteger` which results in the properties being inaccessible for unsigned integers.

These properties will also eliminate the need to use modulus 2 and bitwise AND 1 to determine parity.

Adding `isEven` and `isOdd` is also consistent with the `.isEmpty` utility property, which is a convenience for `.count == 0`.
```swift
if array.count == 0 { ... }
if array.isEmpty { ... }

if value % 2 == 0 { ... }
if value.isEven { ... }
```

### Correctness

There is a minor correctness risk in misinterpreting something like `value % 2 == 0`, particularly when used in a more complex statement, when compared to `value.isEven`.

### Performance

This proposal likely won’t have a major positive impact on performance but it should not introduce any additional overhead thanks to  `@inlineable`.

## Proposed solution

Add two computed properties, `isEven` and `isOdd`, to `BinaryInteger`

```swift
extension BinaryInteger {
    @inlinable
    /// A Boolean value indicating whether this value is even.
    ///
    /// An integer is even if it is evenly divisible by two.
    public var isEven: Bool {
        return self % 2 == 0
    }

    @inlinable
    /// A Boolean value indicating whether this value is odd.
    ///
    /// An integer is odd if it is not evenly divisible by two.
    public var isOdd: Bool {
        return self % 2 != 0
    }
}
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

`divisible(by:)`
