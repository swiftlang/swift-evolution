# Indiana π bill, take 2

* Proposal: [SE-NNNN](NNNN-indiana-pi-bill.md)
* Authors: [Stephen Canon](https://github.com/stephentyrone)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: https://github.com/swiftlang/swift/pull/92206
* Review: [(pitch)](https://forums.swift.org/t/pitch-round-to-nearest/89497)

## Summary of changes
Change the definition of the property `pi` on `FloatingPoint`, so that it is
no longer required to be rounded toward zero. Update `Float.pi` to match the
new definition.

## Motivation
About 130 years ago, the Indiana state legislature briefly entertained a bill
(bill 246 of the 1897 sitting of the Indiana General Assembly) that would have
incidentally legislated the value of π. I figure it's time to try again.

When we designed the [`FloatingPoint` protocols][se-0067] for Swift, IEEE 754
provided no guidance as to how π should be rounded. There are two plausibly
defensible choices: the closest representable value, or the closest 
representable value that is strictly less than π (rounding toward zero).
We opted for the second choice.

However, the IEEE 754 working group now has consensus that implementations
should return the best approximation they can, rather than force rounding to
a less accurate value to try to preserve some invariant. Accordingly we will
adjust the definition of `FloatingPoint.pi` to match this guidance.

## Detailed design

In the documentation for `FloatingPoint.pi`, strike this sentence:
```
/// This value is rounded toward zero to keep user computations with angles
/// from inadvertently ending up in the wrong quadrant.
```
and change the definition of `Float.pi` from `0x1.921fb4p1` to `0x1.921fb6p1`
(the representable value just larger than π).

## Source compatibility

N/A

## ABI compatibility

It is likely that some software out there does depend on this specific value
in some surprising way. In such cases, it may be necessary to use 
`0x1.921fb4p1` instead of `Float.pi`. We do not expect such cases to be 
common, and the ability to more easily get the same results as programs 
written in other languages will outweigh any transient hassles.

## Future directions

N/A

## Alternatives considered

N/A

## Acknowledgments

Thanks to the IEEE 754 working group for detailed discussion of the issue.

[se-0067]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0067-floating-point-protocols.md
