# Standardize function type argument syntax to require parentheses

* Proposal: [SE-0066](0066-standardize-function-type-syntax.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000138.html)
* Implementation: [apple/swift@3d2b5bc](https://github.com/apple/swift/commit/3d2b5bcc5350e1dea2ed8a0a95cd12ff5c760f24)

## Introduction

Function types in Swift use parentheses around their parameter list (aligning
with the function declaration syntax, as well as the syntax used to call a
function).  However, in the degenerate case of a single non-variadic, unlabeled
argument with no attributes, Swift allows the parentheses to be omitted.  For
example, these types:

```swift
(Int) -> Float
(String) -> Int
(T) -> U
(Int) -> (Float) -> String
```

May be written as:

```swift
Int -> Float
String -> Int
T -> U
Int -> Float -> String
```

While this saves some parentheses, it introduces some minor problems, is not
consistent with other parts of the Swift grammar, reduces consistency within
function types themselves, and offers no additional expressive capability (this
is just syntactic sugar).  This proposal suggests that we simply eliminate the
special case and require parentheses on all argument lists for function types.

Swift-evolution thread: [\[pitch\] Eliminate the "T1 -> T2" syntax, require "(T1) -> T2"](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160411/014986.html)

## Motivation

Allowing this sugar introduces ambiguities in the language that require special
rules to disambiguate.  For example:

```swift
() -> Int           // Takes zero arguments, or takes one zero-argument parameter?
(Int, Float) -> Int // Takes two arguments, or takes one two-argument tuple?
```

This syntactic sugar reduces consistency with other parts of the language, since
declarations always require parentheses, and calls requires parentheses as well.
For example:

```swift
func f(a : Int) { ... } // ok
func f a : Int { ... }  // my eyes!
```

Finally, while it is straight-forward to remove this in Swift 3 (given the other
migration that will be necessary to move Swift 2 code to Swift 3), removing this
after Swift 3 will be much harder since we won't want to break code then.  It is
now or never.

## History

The original rationale aligned with the fact that we wanted to treat all
functions as taking a single parameter (which was often of tuple type) and
producing a single value (which was sometimes a tuple, in the case of void and
multiple return values).  However, we’ve long since moved on from that early
design point: there are a number of things that you can only do in a parameter
list now (varargs, default args, internal vs API labels, etc), we removed
implicit tuple splat, and the compiler has long ago stopped modeling function 
parameters this way.

## Proposed solution

Parentheses will be required in function types. Examples:

```swift
Int -> Int           // error
(Int) -> Int         // function from Int to Int
((Int)) -> Int       // also function from Int to Int

Int, Int -> Int      // error
(Int, Int) -> Int    // function from Int and Int to Int
((Int, Int)) -> Int  // function from tuple (Int, Int) to Int

let f: () -> Int     // function with no parameters
let g: (()) -> Int   // function taking a single () parameter
let h: ((())) -> Int // function taking a single () parameter

f();   g(()); h(())  // correct
f(()); g();   h()    // errors
```

### Function type grammar

Parentheses will become a part of function type grammar:

*function-type* → `(` *function-type-parameters*<sub>opt</sub> `)` *throws-annotation*<sub>opt</sub> `->` *type*

*function-type-parameters* → *function-type-parameter* `,` *function-type-parameters*

*function-type-parameters* → *function-type-parameter* `...`<sub>opt</sub>

*function-type-parameter* → *attributes*<sub>opt</sub> `inout`<sub>opt</sub> *type*

*throws-annotation* → *throws* | *rethrows*

## Impact on existing code

The migrator will automatically add parentheses to existing code when moving
from Swift 2 to Swift 3.

## Related questions

This proposal is very simple and well scoped, but in discussion, several
follow-on questions have asked about what precedent this sets - if we change 
this, then what else would align to it.  While we cannot predict the future of
where the Swift community will want to go, this section states the opinion of 
the author on these topics.

### Should function return types be parenthesized?

In my opinion, no.  Unlike arguments, there is no precedent already in Swift
that leads to the result type of functions being parenthesized (e.g. in
declarations).  The result of a function also does not have any of the magic and
complexity of parameter lists: it really is just a type.

Finally, in terms of ergonomics, the return type of a function is very commonly
written in code - almost every function and method has one.  In contrast, 
function types are very rarely written - typically only when writing higher
order functions.

### Should we require parentheses in closure expression parameter lists?

In my opinion, no.  Swift currently supports a number of syntactic shortcuts in
closure parameter lists, which are important for expressiveness of simple
functional algorithms.  For example, very few people write out this long-form
expression to sort an array of integers backward:

```swift
y = x.sorted { (lhs : Int, rhs : Int) -> Bool in rhs < lhs }
```

Many people use:

```swift
y = x.sorted { lhs, rhs in rhs < lhs }
```

Or they use the even shorter form of `{ $1 < $0 }`.

Some folks have asked
whether it would make sense to start requiring the parentheses around the
parameter lists for consistency with function types.  However, note that this is
structurally a different kind of syntactic sugar: you are allowed to elide the
parens even when you have multiple arguments, you are allowed to omit the return
type, you are allowed to omit the types, and you're even allowed to omit the
parameter list in its entirety.  Short of a complete rethink of closure syntax
(something that I'm not suggesting - I'm personally very happy with our 
closure syntax!), requiring parentheses here would not improve the language in an
apparent way.

### Common objection

The most common objection to this proposal cites a reduction in clarity for 
higher order functions that take one parameter.  Consider a (simplified)
implementation of `map` for example, written with the parentheses:

```swift
extension LazySequenceProtocol {
  /// Returns a `LazyMapSequence` over this `Sequence`.  The elements of
  /// the result are computed lazily, each time they are read, by
  /// calling `transform` function on a base element.
  func map<U>(_ transform: (Elements.Iterator.Element) -> U) -> LazyMapSequence<Self.Elements, U>
}
```

The author is unconvinced by the claims that requiring parentheses on the
`transform` parameter unacceptably reduce readability.  Consider:

 * Many higher order functions are generic, which mean that they often take
   long names like `Element` (where the parens do not add much clutter), or
   an excessively short name (e.g. `T`) where the parentheses add structure.

 * The claims of "parentheses blindness" are a possible issue, but they help
   offset the similar issue of "arrow blindness", as demonstrated by the
   example above.

Further, the declaration of a higher order functions is very rare (use of one is
much more common, and is unaffected by this proposal), so it is not worth
deploying sugar to syntax optimize.  If Swift 1 required parentheses on
function types, we would almost certainly reject a proposal to syntax optimize
them away.
