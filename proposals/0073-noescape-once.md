# Marking closures as executing exactly once

* Proposal: [SE-0073](0073-noescape-once.md)
* Authors: [Félix Cloutier](https://github.com/zneak), [Gwendal Roué](https://github.com/groue)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000147.html)

## Introduction

This proposal introduces an optional `once` argument to the `@noescape`
attribute. The `@noescape(once)` attribute enforces that the closure does not
escape, and that it is run exactly once on any code path returning from the
function. For clients, it allows the compiler to relax initialization
requirements and close the gap between closure and "inline code" a little bit.

Swift-evolution thread: [Guaranteed closure execution](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160125/008167.html)

## Motivation

In Swift, multiple functions execute a closure to temporarily grant code
special guarantees. For instance, the standard library's `withUnsafePointer`
affords the closure with a pointer to an object's representation, and the
`autoreleasepool` function wraps a closure with code that creates (and later
destroys) an autorelease pool.

Currently, if you want to initialize a variable inside such a closure, you need
to make it mutable and initially assign it a dummy value, because the compiler
can't prove that the function will execute the closure exactly once. For
instance:

```swift
var x: Int = 0 // `var` declaration, with some irrelevant value
f { x = 1 }
print(x)
```

## Proposed solution

By adding the `@noescape(once)` attribute to the closure parameter, we tell the
compiler that the function will be executed exactly once on any code path that
leaves the function's scope:

```swift
func f(closure: @noescape(once) () -> ()) {
    closure()
}
```

With this information, the compiler can now realize that the `x` variable will
be written to exactly once. It can now be marked as a `let` variable:

```swift
let x: Int  // Not initialized
f { x = 1 }
print(x)    // Guaranteed to be initialized
```

This new form is safer and cleaner.

`@noescape(once)` can also be seen as a natural extension to [SE-0061](0061-autoreleasepool-signature.md) in that we go from:

```swift
// Current Swift:
var x: Int = 0 // `var` declaration, with some irrelevant value
autoreleasepool {
    x = 1
}
	
// Should SE-0061 be accepted:
let x = autoreleasepool {
    return 1
}
	
// Should this proposal be accepted:
let x: Int
let y: String
autoreleasepool {
    x = 1
    y = "foo"
}
```


## Detailed design

In addition to the regular advantages and constraints applied to `@noescape`
parameters, `@noescape(once)` parameters must be called exactly once on any code
path where the function returns. Specifically:

* it **must** either be called or passed as a `@noescape(once)` parameter to
	another function on any code path that returns normally;
* it **must not** be executed on any path that throws;
* there is no requirement for paths that lead to a function that does not return;
* passing it to another function that accepts a `@noescape(once)` closure of the
	same type is allowed and counts as executing it.

A `@noescape(once)` closure may only read from variables that were initialized
before it was formed. For instance, in an example with two `@noescape(once)`
closures, the compiler cannot assume that one closure runs before the other.

```swift
func f(a: @noescape(once) () -> (), b: @noescape(once) () -> ()) { /* snip */ }
	
	
let x: Int
f(a: {x = 1}, b: {print(x)}) // invalid: x has not been initialized
```

A `@noescape(once)` closure may only be passed as a parameter to another
function that accepts a `@noescape(once)` closure. In that case, it counts as
having been called.

A `@noescape(once)` closure may initialize `let` or
`var` variables from its parent scope as if it was executed at the call site.

Since [SE-0049](0049-noescape-autoclosure-type-attrs.md),
`@noescape` is a type attribute. The `@noescape(once)` modifier marks the
closure type as noescape.

## Impact on existing code

This feature is purely additive. Existing code will continue to work as
expected.

## Alternatives considered

## Not requiring exactly one execution

Assuming that the main goal of this proposal is to relax initialization
requirements, a unique invocation of the closure is not stricly required.
However the requirement of unique invocation makes the proposal simpler to
understand.

### A `@once` parameter

It was mentioned in the discussion that the "once" behavior and `@noescape` look
orthogonal, and the "once" behavior could be useful on closures that escape.
However, it is only possible to verify that a closure has been executed exactly
once if it does not escape. Because of this, "once" and `@noescape` are better
left together.

### Calling on paths that throw

It must either be guaranteed that the closure will be executed, or that it will
not be executed, on a path that throws. It appears best to guarantee that it
will not, since this allows the function to bail out without calling the closure
in the event that it can't provide the guarantee that it's trying to get. For
instance:

```swift
do {
	let foo: Int
	try withLock(someLock, timeout: 0.5) {
		foo = sharedThing.foo
	}
} catch {
	print("couldn't acquire lock fast enough")
}
```

A function like this would be awkward to express if the closure had to test
a parameter to tell if the lock was acquired or not.

## Future directions

As soon as a method does not provide the `@noescape(once)` guarantee, it
prevents all functions that call it from providing it (see detailed design
above).

The value of this proposal will thus be hampered until methods and functions in
the standard and core libraries that can provide this guarantee adopt
`@noescape(once)`.

This includes (full list to be done):

- `autoreleasepool`
- `withUnsafeBufferPointer`
- `dispatch_sync` et al.

Those modifications to standard and core libraries will however be part of
future proposals.

## Rationale

On [May 11, 2016](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000147.html), the core team decided to **Reject** this proposal for Swift 3.

The feedback on the proposal was generally positive both from the community and
core team.  That said, it is being rejected for Swift 3 two reasons:

1) The surface level syntax of @noescape needs to be reconsidered.  At the minimum, we need to rename @noescape to @nonescaping for consistency with our previously agreed attribute naming scheme. However, it is also work discussing whether @nonescaping should be the default: if so, the attribute should actually become @escaping, and the functionality proposed in SE-0073 would be named @once.

2) Separate from the surface level issues, the implementation underlying this work has some significant challenges that are doable but would require major engineering work.  Specifically, the definite initialization pass needs to “codegen” booleans in some cases for conditional initialization/overwrite cases, and these state values would have to be added to closure capture lists.  This would require enough engineering work that it seems unlikely that it would happen in the Swift 3 timeframe, and beyond that this could theoretically be subsumed into a more general system that allowed control-flow-like functions to have closures that break/continue/throw/return out of their enclosing function, or a general macro system.

Overall, everyone desires the ability to produce more control-flow like functions, but Swift 3 isn’t in a place where it can make sense to tackle this work.
