# Remove C-style for-loops with conditions and incrementers

* Proposal: [SE-0007](0007-remove-c-style-for-loops.md)
* Author: [Erica Sadun](https://github.com/erica)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2015-December/000001.html)
* Bugs: [SR-226](https://bugs.swift.org/browse/SR-226), [SR-227](https://bugs.swift.org/browse/SR-227)

## Introduction

The C-style `for-loop` appears to be a mechanical carry-over from C rather than a
genuinely Swift-specific construct. It is rarely used and not very Swift-like. 

More Swift-typical construction is already available with `for-in`
statements and `stride`. Removing for loops would simplify the language and starve the
most common use-points for `--` and `++`, which are already due to be eliminated from the
language.

The value of this construct is limited and I believe its removal should be seriously considered.

This proposal was discussed on the Swift Evolution list in the [C-style For Loops](https://lists.swift.org/pipermail/swift-evolution/2015-December/000053.html) thread and reviewed in the [\[Review\] Remove C-style for-loops with conditions	and incrementers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/000913.html) thread.

## Advantages of For Loops

Swift design supported a shallow learning curve using familiar constants and control
structures. The `for-loop` mimics C and limits the effort needed to master this control flow.

## Disadvantages of For Loops

1. Both `for-in` and `stride` provide equivalent behavior using Swift-coherent approaches 
   without being tied to legacy terminology. 
1. There is a distinct expressive disadvantage in using `for-loops` compared to `for-in` 
   in succinctness
1. `for-loop` implementations do not lend themselves to use with collections and other core Swift types.
1. The `for-loop` encourages use of unary incrementors and decrementors, which will be
   soon removed from the language.
1. The semi-colon delimited declaration offers a steep learning curve from users arriving
   from non C-like languages
1. If the `for-loop` did not exist, I doubt it would be considered for inclusion in Swift 3.

## Proposed Approach

I suggest that the for-loop be deprecated in Swift 2.x and removed entirely in Swift 3, with coverage removed from the Swift Programming Language to match the revisions in the current 2.2 update.

## Alternatives considered

Not removing `for-loop` from Swift, losing the opportunity to streamline the language
and discard an unneeded control flow item.

## Impact on existing code

A search of the Apple Swift codebase suggests this feature is rarely used. Community members of the Swift-Evolution mail list confirm that it does not feature in many pro-level apps and can be worked around for those few times when `for-loop`s do pop up. For example:

```swift
char *blk_xor(char *dst, const char *src, size_t len)
{
 const char *sp = src;
 for (char *dp = dst; sp - src < len; sp++, dp++)
   *dp ^= *sp;
 return dst;
}
```

versus


```swift
func blk_xor(dst: UnsafeMutablePointer<CChar>, src:
UnsafePointer<CChar>, len: Int) -> UnsafeMutablePointer<CChar> {
   for i in 0..<len {
       dst[i] ^= src[i]
   }
   return dst
}
```

A search of github's Swift gists suggests the approach is used primarily by those new to the language with minimal language skills and is abandoned as language mastery is achieved.

For example:

```swift
for var i = 0 ; i < 10 ; i++ {
    print(i)
}
```

and 

```swift
var array = [10,20,30,40,50]
for(var i=0 ; i < array.count ;i++){
    println("array[i] \(array[i])")
}
```

## Community Responses
* "I am certainly open to considering dropping the C-style for loop.  IMO, it is a rarely used feature of Swift that doesn’t carry its weight.  Many of the reasons to remove them align with the rationale for removing -- and ++. " -- Chris Lattner, clattner@apple.com
* "My intuition *completely* agrees that Swift no longer needs C-style for loops. We have richer, better-structured looping and functional algorithms. That said, one bit of data I’d like to see is how often C-style for loops are actually used in Swift. It’s something a quick crawl through Swift sources on GitHub could establish. If the feature feels anachronistic and is rarely used, it’s a good candidate for removal." -- Douglas Gregnor, dgregor@apple.com
* "Every time I’ve used a C-style for loop in Swift it was because I forgot that .indices existed. If it’s removed, a fixme pointing that direction might be useful." -- David Smith, david_smith@apple.com
* "For what it's worth we don't have a single C style for loop in the Lyft codebase." -- Keith Smiley, keithbsmiley@gmail.com
* "Just checked; ditto Khan Academy." -- Andy Matsuchak, andy@andymatuschak.org
* "We’ve developed a number of Swift apps for various clients over the past year and have not needed C style for loops either." -- Eric Chamberlain, eric.chamberlain@arctouch.com
* "Every time I've tried to use a C-style for loop, I've ended up switching to a while loop because my iteration variable ended up having the wrong type (e.g. having an optional type when the value must be non-optional for the body to execute). The Postmates codebase contains no instances of C-style for loops in Swift." -- Kevin Ballard, kevin@sb.org
* "I found a couple of cases of them in my codebase, but they were trivially transformed into “proper” Swift-style for loops that look better anyway. If it were a vote, I’d vote for eliminating C-style." -- Sean Heber, sean@fifthace.com

