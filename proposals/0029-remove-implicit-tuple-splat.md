# Remove implicit tuple splat behavior from function applications

* Proposal: [SE-0029](0029-remove-implicit-tuple-splat.md)
* Author: [Chris Lattner](http://github.com/lattner)
* Review Manager: [Joe Groff](http://github.com/jckarter)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-February/000033.html)
* Implementation: [apple/swift@8e12008](https://github.com/apple/swift/commit/8e12008d2b34a605f8766310f53d5668f3d50955)

## Introduction

Function call expressions (which include several syntactic forms that apply an argument list to something of function type) currently have a dual nature in Swift.  Given something like:

```swift
func foo(a : Int, b : Int) {}
```

You can call it either with the typical syntactic form that passes arguments to each of its parameters:

```swift
foo(42, b : 17)
```

or you can take advantage of a little-known feature to pass an entire argument list as a single value (of tuple type):

```swift
let x = (1, b: 2)
foo(x)
```

This proposal recommends removing the later form, which I affectionately refer to as the "tuple splat" form.  This feature is purely a sugar feature, it does not provide any expressive ability beyond passing the parameters manually.

Swift-evolution thread: [Proposal: Remove implicit tuple splat behavior from function applications](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160125/007856.html)


## Motivation

This behavior is cute, precedented in other functional languages, and has some advantages, but it also has several major disadvantages, which are all related to its syntactic form.

* A call to `foo(x)` looks like a call to an overloaded version of `foo`, both to the compiler and to the human who maintains the code.  This is extremely confusing if you don't know the feature exists.
* There are real ambiguities in the syntax, e.g. involving Any arguments and situations where you want to pass a tuple value as a single parameter.
* The current implementation has a ton of implementation bugs - it doesn't work reliably.
* The current implementation adds complexity to the type checker, slowing it down and adding maintenance burden.
* The current implementation doesn't work the way we would want a tuple splat operation to work.  For example, arguably, you should be able to call foo with:

```swift
func bar() -> (Int, Int) { ... }
foo(bar())
```

... but this is not allowed, since tuple labels are required to line up.  You have to write:

```swift
func bar() -> (Int, b: Int)  { … }
foo(bar())
```


This makes this feature very difficult to use in practice, because you have to `_`'ize a lot of parameters (violating naming conventions), perform manual shuffling (defeating the sugar benefits of the feature), or add parameter labels to the result of functions (which leads to odd tying between callers and callees).


The root problem here is that we use exactly the same syntax for both forms of function application.  If the two forms were differentiated (an option considered in “alternatives considered” below) then some of these problems would be defined away.

From a historical perspective, the tuple splat form of function application dates back to very early Swift design (probably introduced in 2010, but possibly 2011) where all function application was of a single value to a function type.  For a large number of reasons (including inout, default arguments, variadic arguments, labels, etc) we  completely abandoned this model, but never came back to reevaluating the tuple splat behavior.

If we didn’t already have this feature, we would not add it to Swift 3 (at least in its current form).


## Proposed solution

The proposed solution is simple, we should just remove this feature from the Swift 3 compiler.  Ideally we would deprecate it in the Swift 2.2 compiler and remove it in Swift 3.  However, if there isn’t time to get the deprecation into Swift 2.2, the author believes it would be perfectly fine to just remove it in Swift 3 (with a fixit + migration help of course).

One interesting aspect of this feature is that some people we’ve spoken to are very fond of it.  However, when pressed, they admit that they are not actually using it widely in their code, or if they are using it, they are abusing naming conventions (distorting their code) in order to use it.  This doesn’t seem like a positive contribution - this seems like a "clever" feature, not a practical one.

*Note:* a common point of confusion about this proposal is that it does not propose removing the ability to pass tuples as values to functions.  For example, this will still be perfectly valid:

```swift
func f1(a : (Int, Int)) { ... }
let x = (1, 2)
f1(x)
```

as are cases using generics:

```swift
func f2<T>(a : T) -> T { ... }
let x = (1, 2)
f2(x)
```

The only affected case is when a single tuple argument is being expanded by the compiler out into multiple different declared parameters.


## Detailed design

The design is straight-forward.  In the Swift 3 time frame, we continue to parse and type check these expressions as we have so far, but produce an error + fixit hint when it is the tuple splat form.  The migrator would auto-apply the fixit hint as it does for other cases.


## Impact on existing code

Any code that uses this feature will have to move to the traditional form.  In the case of the example above, this means rewriting the code from:

```swift
foo(x)
```

into a form like this:

```swift
foo(x.0, x.b)
```

In the case where "x" is a complex expression, a temporary variable will need to be introduced.  We believe that compiler fixits can handle the simple cases directly and that this extension is not widely used.

## Alternatives considered

The major problem with this feature is that it was not well considered and implemented properly (owing to its very old age, which has just been kept limping along).  As such, the alternative is to actually design a proper feature to support this.  Since the implicitness and syntactic ambiguity with normal function application is the problem, the solution is to introduce an explicit syntactic form to represent this.  For example, something like this could address the problems we have:

```swift
foo(*x)    // NOT a serious syntax proposal
```

However, actually designing this feature would be a non-trivial effort not core to the Swift 3 mission:

* It is a pure-sugar feature, and therefore low priority.
* We don't have an obvious sigil to use.  "prefix-star" should be left unused for now in case we want to use it to refer to memory-related operations in the future.
* Making the tuple splat operation great requires more than just fixing the syntactic ambiguities we have, it would require re-evaluating the semantics of the operation (e.g. in light of parameter labels, varargs and other features).

If there is serious interest in pursuing this as a concept, we should do it as a follow-on proposal to this one.  If a good design emerges, we can evaluate that design based on its merits.


The final alternative is that we could leave the feature in the compiler.  However, that means living with its complexity “forever” or breaking code in the Swift 4 timeframe.  It would be preferable to tackle this breakage in the Swift 3 timeframe, since we know that migration will already be needed then.
