# Allow `reduce` to produce noncopyable results 

* Proposal: [SE-0515](0515-noncopyable-reduce.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Active review (February 25...March 10, 2026)**
* Implementation: [swiftlang/swift#85716](https://github.com/swiftlang/swift/pull/85716)
* Review: ([pitch](https://forums.swift.org/t/pitch-allow-reduce-to-produce-noncopyable-results/84073)) ([review](https://forums.swift.org/t/se-0515-allow-reduce-to-produce-noncopyable-results/84997))

## Introduction

A proposal to alter `Sequence.reduce(_:_:)` to:
- allow noncopyable initial values and results; and
- consume rather than borrow the initial value, even when it is copyable.

## Motivation

Noncopyable types were introduced in [SE-0390](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md)
and provide a powerful mechanism for controlling the semantics
and performance of types.

While a `Sequence` cannot (yet) hold noncopyable types, `reduce` has
an accumulation argument that is independent of the sequence,
and it is simple to implement `reduce` without relying on the
ability to copy that value so long as the initial value is consumed
rather than borrowed (and so can be mutated).

## Proposed solution

Replace the current implementations of `reduce` with the following:

```swift
extension Sequence {
  public func reduce<Result: ~Copyable>(
    _ initialResult: consuming Result,
    _ nextPartialResult:
      (_ partialResult: consuming Result, Element) throws -> Result
  ) rethrows -> Result

  public func reduce<Result: ~Copyable>(
    into initialResult: consuming Result,
    _ updateAccumulatingResult:
      (_ partialResult: inout Result, Element) throws -> ()
  ) rethrows -> Result
}
```

## Detailed design

The current implementation of `reduce` takes its parameter borrowed:

```swift
func reduce<Result>(
  _ initialResult: Result,
  _ nextPartialResult:
    (_ partialResult: Result, Element) throws -> Result
) rethrows -> Result {
  var accumulator = initialResult
  for element in self {
    accumulator = try nextPartialResult(accumulator, element)
  }
  return accumulator
}
```

The borrow is implicit in this case, because this is the default
for non-initializer arguments.

Note that the very first step is always to create a mutable copy of
`initialResult`, which is then continuously updated with the next
partial result, and then returned.

This pattern of code strongly suggests that the right default
calling convention for `initial` is `consuming`. If the value is
copyable, the copy will instead be made by the caller _unless_ the 
optimizer can see it is the last use of the value at the call site, 
in which case the copy can be eliminated altogether. This outcome
is very common with `reduce`, here the "initial value" is often
created purely for the purpose of the reduction.

Similarly, for each call to `nextPartialResult`, if the `partialResult`
value is consumed and then returned, the same value will be used
over and over again, instead of being implicitly borrowed, copied,
and then returned.

If we generalize `reduce` to work with noncopyable values too, 
it is then _mandatory_ for the initial value to be consumed, because 
that `var accumulator = initialResult` will no longer compile.

The new version of `reduce` can therefore be written as:

```swift
public func reduce<Result: ~Copyable>(
  _ initialResult: consuming Result,
  _ nextPartialResult:
    (_ partialResult: consuming Result, Element) throws -> Result
) rethrows -> Result {
  for element in self {
    initialResult = try nextPartialResult(initialResult, element)
  }
  return initialResult
}
```

Note, there is no longer a need to copy the `initialResult` value
since it is taken `consuming` (i.e. owned not borrowed).

At this point, `reduce(_:_:)` and `reduce(into:_:)` become almost
the same function, and the motivation for `reduce(into:_:)` is
reduced – which one to use is mostly an ergonomic choice.

Note that this only eliminates one out of the three causes
of the classic "world's slowest map" footgun: 

```swift
array.reduce([]) { $0 + [$1] }
```

is still accidentally quadratic, because `+` borrows its 
arguments and return a new array with all the elements
copied into it (and `[$1]` still allocates a new array buffer just
to throw it away).[^1] But with the new reduce you could now write:

```swift
array.reduce([]) { $0.append($1); return $0 }
```

and get the same performance as the slightly more ergonomic:

```swift
array.reduce(into: []) { $0.append($1) }
```

`reduce(into:_:)` already takes its argument consuming, so the only
change here is the addition of `Result: ~Copyable`.

[^1]: Note, all these inefficiencies can be eliminated by an optimizer
performing heroics. However, these heroic optimizations tend to break
down in the face of slightly more complicated examples, leading to
performance cliffs.

## Source compatibility

Altering the calling convention of a copyable parameter is not source
breaking. The compiler will automatically adapt the code to the new
convention.

Generalizing a generic function to work with noncopyable types is
also not source breaking, so long as the semantics can be preserved
(which they can in this case).

## ABI compatibility

Altering the calling convention of a parameter is ABI-breaking. On
ABI-stable platforms the old entry point will need to be preserved,
but will not need to be publicly callable. Recompilation with an
updated standard library will switch to the new version. Since
this is just a new function, the change can be back-deployed.

## Future directions

`reduce` could also be updated to work with `~Escapable` values.
This would require lifetime annotations on both the function and
the closure parameter – and the latter is not yet supported in Swift.
