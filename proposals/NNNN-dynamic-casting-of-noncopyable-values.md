# Dynamic Casting of Noncopyable Values

* Proposal: [SE-NNNN](NNNN-dynamic-casting-of-noncopyable-values.md)
* Authors: [Tim Kientzle](https://github.com/tbkka)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#93155](https://github.com/swiftlang/swift/pull/93155), [swiftlang/swift#93486](https://github.com/swiftlang/swift/pull/93486), [swiftlang/swift#93545](https://github.com/swiftlang/swift/pull/93545), [swiftlang/swift#93612](https://github.com/swiftlang/swift/pull/93612), [swiftlang/swift#93627](https://github.com/swiftlang/swift/pull/93627), [swiftlang/swift#93699](https://github.com/swiftlang/swift/pull/93699), [swiftlang/swift#93702](https://github.com/swiftlang/swift/pull/93702)
* Experimental Feature Flag: `NoncopyableCasting`
* Review: ([pitch](https://forums.swift.org/t/noncopyable-existentials-and-casting/90306))

## Summary of changes

Expands support for noncopyable values:
* Borrowing (non-destructive) `type(of:)`
* Borrowing (non-destructive) `is` type tests
* Casts and cast patterns consume the source value only if the cast succeeds, including in `switch`, `if case`, `if let`, `guard let`, and other related contexts.
* Noncopyable types can be used as source or destination for a cast or pattern match.
* Copyable types behave identically.

## Motivation

Noncopyable values in Swift can currently be put into existentials
but those existentials have very limited support.
In particular, there is no way to reliably cast the value to extract
it from the existential.
Further, workarounds such as unsafe bitcasts are ineffective unless
you can test the type of the value contained in the existential,
but `is` expressions are rejected outright,
and `type(of:)` and `if case is` consume the source, destroying
the original value.

Worse, the current runtime support has significant problems with
noncopyable types in general.
For example, the following code compiles with Swift 6.4 then
traps at runtime because the runtime will attempt to needlessly copy the
noncopyable value:
```
func test(_ x: consuming any P & ~Copyable) -> Int {
  switch x {
  case is NCType:
    // 💥 Swift 6.4: traps at runtime when `x` holds an `NCType`,
    // after warning that this cast "always fails"
    return -1
  default: return 0
  }
}
```

## Proposed solution

We propose to change how casting constructs are compiled whenever
noncopyable types are involved.
This changes the fundamental ownership rules for casting:
Values are borrowed instead of being consumed,
or only consumed along certain paths.
(Our current implementation does sometimes use the new
approach for copyable types, although this has no observable
effect.)

Note: Throughout the following,
we'll use these common types and protocols:
```
// P and Q don't require Copyable
protocol P: ~Copyable {}
protocol Q<T>: ~Copyable { associatedtype T }

// Noncopyable types: NCType and OtherNC conform to P;
// Both conforms to P and Q<Int>
struct NCType: P, ~Copyable { var tag = 7 }
struct OtherNC: P, ~Copyable {}
struct Both: P, Q, ~Copyable { typealias T = Int }
enum NCEnum: ~Copyable { case one(any P & ~Copyable), two }

// Note: `any P` (without `& ~Copyable`) is a Copyable existential
// and can never hold a noncopyable value.
```

With that context,
consider a noncopyable existential `box` defined with one
of the following types:

```
// Simple opaque existential
let box: any ~Copyable
// Noncopyable protocol existential
let box: any P & ~Copyable
// Noncopyable protocol extended existential
let box: any Q<Int> & ~Copyable
```

#### Type Testing

Type testing operations always borrow their argument
(previously they would consume owned arguments):

```
let t = type(of: box)
// `box` still exists after the above expression
// regardless of whether it's Copyable or not
```

The `type(of:)` function is directly implemented by the
compiler and requires no runtime support at all.
In contrast, the `is` operator requires runtime support.
A new runtime entry point supports borrowing type
testing:

```
let a = box is Both
// `box` still exists after the above expression
// regardless of whether the test was true or false
```

#### `if case` and `if let`

Conditional casting structures now only consume their
values when casts succeed.
This means that the source value is still available
in `else` clauses:

```
if case let x as NCType = box {
  // `box` is destroyed in order to construct `x`
} else {
  // `box` still exists at entry to this block
  // `box` destroyed at end of this block
}
// `box` not alive after above
```

```
if let x = box as? NCType {
  // `box` is destroyed in order to construct `x`
} else {
  // `box` still exists at entry to this block
  // `box` destroyed at end of this block
}
// `box` not alive after above
```

```
if let x = x as? NCType {
  // Outer `x` is destroyed to construct inner `x`
} else {
  // Outer `x` still exists at entry to this block
  // Outer `x` destroyed at end of this block
}
// `x` not alive after above
```

In addition to `if case` and `if let`, this new behavior
also applies to similar control constructs based on `guard`,
`while`.

#### Switch statements

Switch statements similarly can avoid consuming the original
value in many cases.

Because conversion casts are still fundamentally consuming
when they do match, borrowing switches can perform type tests
without consuming, but cannot bind the converted result from
a noncopyable source value:

```
switch box { // borrowing by default!
case is NCType:
  // `box` still exists at entry to this block
case is OtherNC:
  // `box` still exists at entry to this block
case let x as Both:
  // 🛑 cannot bind the payload while the value is borrowed
default:
  // `box` still exists at entry to this block
}
// `box` still exists after switch
```

Consuming switches can handle most pattern matching operations.
There are however a few limitations described in "Known Issues" below.

```
switch consume box { // consuming!
case is NCType:
  // `box` not available here
case _ as OtherNC:
  // Similar to above
case let x as Both:
  // Value moved into `x`
case let y as any Q<Int> & ~Copyable:
  // Noncopyable existential target
case let otherBox:
  // Original value available as `otherBox`
  // (See Known Issues for limitations on `default`)
}
// `box` not alive after above
```

## Detailed design

#### Binding the Result Requires Consumption

A cast borrows whenever the converted value is not needed.
This includes `x is T` expressions,
`switch` constructs that only test the type such as `case is NCType:`
or `case _ as NCType:`,
and casts that are statically known to be true or false.

Otherwise, the original value is consumed.
This includes successful `as?`/`as!` and binding patterns.
Values that cannot be consumed, including borrowed parameters,
globals, class properties, or values captured by an escaping closure
will be diagnosed with "cannot consume" errors.

#### Sources and Targets

This proposal supports any combination of copyable or noncopyable
source or target.
(Except metatypes -- see "Future Directions".)
This includes copyable values stored in noncopyable existentials.

#### Diagnostic Changes

The new casting support has expanded the range of diagnostics that
may be seen when attempting to cast noncopyable values.
The following summarizes the new and expanded diagnostics from
the current implementation of the NoncopyableCasting feature:

**New error**: "cannot bind the payload of a non-'Copyable' value with a cast pattern while the value is borrowed"

This is followed by one of the following notes depending on why the value is still borrowed:
* Borrowing switch: "use 'switch consume' to bind the payload by consuming the value"
* Where clause: "a 'where' clause is evaluated before the value is consumed; test the condition in the case body instead"
* Refutable sub-pattern: "match the bound value in the case body instead"

**Availability Messages** include fix-its with `@available` or `if #available`:
* "runtime support for casting out of a non-'Copyable' value is only available in %0 %1 or newer"
* "runtime support for casting a non-'Copyable' existential is only available in %0 %1 or newer"
* "runtime support for casting a non-'Escapable' existential is only available in %0 %1 or newer"

**Existing diagnostics that casts can now produce**:
* "cannot consume non-'Copyable' stored property '%0' of a class / … that is global"
* "non-'Copyable' '%0' cannot be consumed when captured by an escaping closure or borrowed by a non-'Escapable' type"
* "'%0' is borrowed and cannot be consumed"  (consuming forms on a borrowing parameter)
* "cast from 'X' to unrelated type 'Y' always fails" (now including statically impossible noncopyable casts)
* "'is'/'as' test is always true"
* "matching a non-'Copyable' value using a case label that has multiple patterns is not implemented"

**No longer emitted**: "non-'Copyable' types cannot be conditionally cast"

## Source compatibility

This work does not alter the visible behavior of copyable types.

We expect most currently-working code to see no changes from this work.
That follows from the fact that for **non**copyable types,
the majority of the affected patterns fail in Swift 6.4:
some are explicitly rejected,
some crash the compiler,
some crash at runtime, and
some give the wrong answer.
There are a very few potentially source-breaking changes,
although we do not expect these to cause serious problems.

#### Effects on deinitializer scheduling

Because `is` tests no longer consume noncopyable values,
the few examples that did work in Swift 6.4 may see
deinitializers run at a different time:
```
 let x: any P & ~Copyable = NCType()
 if case is NCType = x { // 6.4: `x` consumed here, deinitializer runs
   ...
 }
 // New behavior: `x` not consumed above,
 // so deinitializer will run later
```

#### Patterns that used to incorrectly match now fail

In Swift 6.4, a nested pattern that casts a noncopyable payload to
a Copyable existential, such as
```
if case .some(let v as any P) = o
```
or
```
if case .one(is any P) = e
```
reports a match even though `any P` can never hold the payload.
Such casts will now correctly fail.

#### Some casts now need availability annotations

Many noncopyable casts will now produce availability errors when
targeting an older runtime.
This includes code that did compile in Swift 6.4,
such as the example in the "Motivation" section.
As that section explains, this example does compile under
Swift 6.4 but consistently crashes at runtime whenever
the pattern actually matches.
That same example will now require an availability annotation
to ensure it only executes where the Swift runtime is
sufficiently new.

Here's another pattern that requires an availability
annotation:
```
func unwrap(_ o: consuming (any P & ~Copyable)?) -> Int {
  if case .some(let v as NCType) = o { return v.tag }
  return -1
}
```
This is the only pattern we know that actually worked correctly
with the Swift 6.4
compiler and runtime (despite a spurious warning).
The new implementation requires `@available` or `if #available`
when this code is targeting an older runtime.

## ABI compatibility

This proposal adds a runtime entry point to the Swift runtime.
The `swift_dynamicCastTest` entry point supports non-consuming
type testing needed for `is` and `switch` support of noncopyable
types.
When the deployment target has this new runtime,
the compiler will use this entry point for copyable types as well,
since it avoids copying and destroying the tested value.

We have also changed the existing runtime entry points:
* They now "take" noncopyable payloads from existentials
  (instead of attempting to copy), and
* They fail a cast that attempts to put a noncopyable payload
  into a Copyable existential

## Implications on adoption

Nondestructive `type(of:)` and casts whose result is statically known
do not require any runtime support
and can be back-deployed to any target.

Any of these patterns require new runtime support whenever
_all_ of the following are true:
* Source is noncopyable (including concrete, generic, or existential)
* Target is noncopyable (concrete, generic, or existential) or is a copyable existential
* The result is not statically true or false

When the deployment target lacks the new runtime support,
any such cast is an error unless appropriately guarded with
`@available`
or
`if #available`.

These guards will also be needed within inlinable code
that uses these features.

## Future directions and Known Issues

Apart from various implementation bugs that we will
continue to address,
there are a few restrictions in the current implementation
that would require a more concerted effort to address
and so are deliberately omitted from this proposal.

#### More ergonomic `default` handling

This behavior may surprise people:
```
switch consume box {
case is NCType: ...
case let x as OtherNC: ...
default:
  consumingFunc(box) // 🛑 Error: `box` consumed more than once
}
```

This stems from the current handling of consuming switch
in SE-0432, which requires `box` to be consumed
on entry to the `switch` statement.

The workaround is to use an irrefutable binding to
capture the original value:
```
switch consume box {
case is NCType: ...
case let x as OtherNC: ...
case let innerBox:
  consumingFunc(innerBox)
}
```

#### True Borrowing Casts

In the current design, although an individual cast operation or
pattern match does not consume the value when the conversion fails,
it does consume on success.
This in turn means that the `if let`, `if case`, or `switch` statement
as a whole necessarily consumes the value.
As a result, we cannot support binding patterns in a
default borrowing `switch` statement,
nor can we use binding patterns against borrowed function arguments.

This restriction follows naturally from the fact that Swift's casting
and pattern-match facilities are very general and include many conversions
that necessarily consume their inputs.
However, in specific cases it may be possible to do better.

For example, if you start with an existential `box`,
we might someday be able to support:
```
let box: any P & ~Copyable
if let x = box as? NCType {
  // `x` is borrowed directly from `box`
  // without destroying `box`
} else {
  // `box` is still available
}
// `box` is still available
```
Changes such as these strictly broaden the possible use cases
and can safely be explored in the future.

#### Noncopyable metatypes

Casts whose source or target is the metatype of a noncopyable type
are currently treated by the compiler as unconditionally failing.

#### Other Currently Unsupported Shapes

Each of the following could be supported with additional effort:

* Binding from borrowed sources, including `where` clauses and refutable sub-patterns in borrowing or consuming `switch`
* Multi-pattern `case is A, is B:`
* `if case` with a borrowed noncopyable subject

#### Undesired consumption

Certain `is` patterns still consume.
We consider these bugs and hope to address them in the near future:
* Nested optional sources
* `source is T?` with an optional target type

## Alternatives considered

#### Leaving `is` consuming

We think borrowing is more natural:
consuming `is` prevents any further use of the value
and makes a chain of tests impossible.

#### Diagnosing patterns instead of implementing support

We could have avoided new runtime by having the compiler
diagnose casts that were not supported by the old runtime.
We've essentially done this when targeting platform versions
that do not support the new runtime.
