# Conventionalizing `stride` semantics

* Proposal: [SE-0051](0051-stride-semantics.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: N/A
* Status: **Withdrawn**

Swift offers two stride functions, `stride(to:, by:)` and `stride(through:, by:)`. This proposal introduces a third style and renames the existing `to` and `through` styles.

This proposal was discussed on-list in the ["\[Discussion\] stride behavior and a little bit of a call-back to digital numbers"](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011194.html) thread.

## Motivation

`Strideable`'s function names do not semantically match the progressions they generate. Values produced by `through` do not pass through an end point; they stop at or before that fence. For example, `1.stride(through: 10, by: 8)` returns the progress (1, 9), not (1, 9, 17).  Similarly, its `to` function values reaches its end point. `1.stride(to:4, by:1)` returns 1, 2, and 3. It never makes it *to* 4:

* The current Swift definition of `to` returns values in *[`start`, `end`)* and will never reach `end`. In other words, you will never get *to* `end`.
* The current Swift definition of `through` returns values in *[`start`, `end`]*. It may never reach `end` and certainly never goes *through* that value.
 
Some definitions with the help of the _New Oxford American Dictionary_

* Moving `to` a value expresses "a point reached at the end of a range".
* To pass `through` a value, you should move beyond "the position or location of something beyond or at the far end of (an opening or an obstacle)". 
* To move `towards` a value is to get "close or closer" or "getting closer to achieving (a goal)".

## Current Art
A `Strideable to` sequence returns the sequence of values (`self`, `self + stride`, `self + stride + stride`, ... *last*) where *last* is the last value in
the progression that is less than `end`.

A `Strideable through` sequence currently returns the sequence of values (`self`, `self + stride`, `self + tride + stride`, ... *last*) where *last* is the last value in the progression less than or equal to `end`. There is no guarantee that `end` is an element of the sequence.

The name of the calling function `through` suggests the progression will pass *through* the end point before stopping. It does not. The name `to` suggests a progression will *attempt to arrive* at an end point. It does not.

## Detail Design

When striding `to` or `through` a number, the behavior does not match the meaning of the word. Swift should provide three stride styles not two.

* Style 1: *[start, end) by interval*<br />This style is currently called `to`. I propose to rename it `towards` as each value works towards `end`. The final value in the progression is less than `end`. Other suggested names include `approaching`, `movingTowards`, `advancedTowards`.

* Style 2: *[start, end] by interval*<br />This style is currently called `through`. I propose to rename it `to`. The progression concludes with a value that is less than or equal to `end`. Swift provides no guarantee that `end` is an element of the sequence. Other suggested names include `movingTo`, `advancingTo`.

* Style 3: *[start, >=end] by interval*<br />I propose to introduce a new style called `through`. The final value is guaranteed to pass through `end`, either by finishing on `end` or past `end`. The final value is strictly less than `end` + `interval`. Other suggested names include `beyond`, `past`.

#### Canonical Use Cases

Canonical use-cases for all three styles:

**Style 1: towards** This style mimics `a..<b` but allows non-unit and negative progressions<br />
> *1 towards 5 by 1: [1, 2, 3, 4]* 

Style 1 ensures that the range of the from and to values fully includes the range of the progression: [from...through] subsumes [first..<last]. Example, standard index references, either progressing in iterative units or by leaps, without
introducing array bounds errors.

**Style 2: to** This style mimics `a...b` but allows non-unit and negative progressions<br />
> *1 to 5 by 1: [1, 2, 3, 4, 5]*<br />
> *1 to 10 by 8: [1, 9]*

Style 2 ensures that the range of the from and to values fully includes the range of the progression: [from...through] subsumes [first...last]. Example: a simple inclusive count, or a range-limited sequence.

**Style 3: through** This style introduces `a..>=b`, `a..=>b`, or `a...>b` and allows non-unit and negative progressions<br />
> *1 through 10 by 8: [1, 9, 17]*

Style 3 ensures that the range of the progression fully includes the range of the from and to values:
[first...last] subsumes [from...through]. Example: mapping out a graph axis, where the extent must
be greater to or correspond to the underlying sequence.

#### Implementing Style 3

A Style 3 implementation works as follows:

```swift

/// A `Strideable through` sequence currently returns the sequence of values 
/// (`self`, `self + stride`, `self + stride + stride`, ... *last*) where *last* 
/// is the first value in the progression **greater than or equal to** `end`. 
/// There is no guarantee that `end` is an element of the sequence.

    /// Advance to the next element and return it, or `nil` if no next
    /// element exists.
    public mutating func next() -> Element? {
        if done {
            return nil
        }
        if stride > 0 ? current >= end : current <= end {
            done = true
            return current
        }
        let result = current
        current = current.advancedBy(stride)
        return result
    }
}
```

This solution is minimally disruptive to developers, respectful to existing code bases, and introduces a more complete semantic set of progressions that better matches progression names to developer expectations. (For example, "this argument says it goes *through* a value but it never even reaches that value".)

Upon adopting this change, out-of-sync strides now pass through end values:

```
// Unit stride
print(Array(1.stride(through: 10, by: 1))) 
// prints [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], no change

// Old out-of-sync stride
print(Array(1.stride(through: 10, by: 8)))
// prints [1, 9]

// New out-of-sync stride
print(Array(1.stride(through: 10, by: 8)))
// prints[1, 9, 17]
```

There are no functional changes existing stride implementations. Only their names change.

```
print(Array(1.stride(towards: 10, by: 8))) // was `to`
// prints [1, 9]

print(Array(1.stride(to: 10, by: 8))) // was `through`
// prints [1, 9]
```

Although floating point arithmetic presents a separate and orthogonal challenge, its behavior changes if this proposal is implemented under the current generic system. For example, `through` now includes a value at (or at least close to) 2.0 instead of stopping at 1.9 due to accumulated floating point errors.

```
// Old
print(Array(1.0.stride(through: 2.0, by: 0.1)))
// prints [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9]

// New
print(Array(1.0.stride(through: 2.0, by: 0.1)))
// prints [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]

// Old, does not pass through 1.9
print(Array(1.0.stride(through: 1.9, by: 0.25)))
// prints [1.0, 1.25, 1.5, 1.75]

// New, passes through 1.9
print(Array(1.0.stride(through: 1.9, by: 0.25)))
// prints [1.0, 1.25, 1.5, 1.75, 2.0]
```

### Impact on Existing Code

Renaming two stride functions and adding a third does not change or break existing code. The Swift 3 migrator can easily update the names for the two existing styles. That said, the migrator will not find in-place workarounds like a `through: 2.01` epsilon adjustment to correct for floating-point fences. By adding `FIXME:` notes wherever `through:` is found and renamed to `to:`, the migrator could warn against continued use without a full inspection and could offer links to information about the semantic changes.

## Alternatives Considered

The only alternative at this time is "no change" to existing semantics.
