# Move @noescape and @autoclosure to be type attributes

* Proposal: [SE-0049](0049-noescape-autoclosure-type-attrs.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000099.html)
* Bug: [SR-1235](https://bugs.swift.org/browse/SR-1235)

## Introduction

This proposal suggests moving the existing `@noescape` and `@autoclosure`
attributes from being declaration attributes on a parameter to being type
attributes.  This improves consistency and reduces redundancy within the
language, e.g. aligning with [SE-0031](0031-adjusting-inout-declarations.md), 
which moved `inout`, making declaration and type syntax more consistent. 

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012292.html)

## Motivation

[Chris Eidhof](https://github.com/chriseidhof) 
noticed an emergent result of removing our currying syntax: it
broke some useful code using `@noescape`, because we only allowed it on
parameter declarations, not on general things-of-function-type.  This meant that
manually curried code like this:

```swift
func curriedFlatMap<A, B>(x: [A]) -> (@noescape A -> [B]) -> [B] {
  return { f in
    x.flatMap(f)
  }
}
```

Was rejected.  Fixing this was 
[straight-forward](https://github.com/apple/swift/commit/c3c6beac72bc0368030f06d52c46b6444fc48dbd),
but required `@noescape` being allowed on arbitrary function types.  Now that we
have that, these two declarations are equivalent:

```swift
func f(@noescape fn : () -> ()) {}  // declaration attribute
func f(fn : @noescape () -> ()) {}  // type attribute.
```

Further evaluation of the situation found that `@autoclosure` (while less
pressing) has the exact same problem.  That said, it is currently in a worse
place than `@noescape` because you cannot actually spell the type of a function
that involves it.   Consider an autoclosure-taking function like this:

```swift
func f2(@autoclosure a : () -> ()) {}
```

You can use it as you'd expect, e.g.:

```swift
f2(print("hello”))
```

Of course, `f2` is a first class value, so you can assign it:

```swift
let x = f2
x(print("hello"))
```

This works, because `x` has type `(@autoclosure () -> ()) -> ()`.  You can see
this if you force a type error:

```swift
let y : Int = x // error: cannot convert value of type '(@autoclosure () -> ()) -> ()' to specified type 'Int'
```

However, you can’t write this out explicitly:

```swift
let x2 : (@autoclosure () -> ()) -> () = f2
// error: attribute can only be applied to declarations, not types
```

This is unfortunate because it is an arbitrary inconsistency in the language, 
and seems silly that you can use type inference but not manual specification for
the declaration of `x2`.


## Proposed Solution

The solution solution is straight-forward: disallow `@noescape` and 
`@autoclosure` on declarations, and instead require them on the types.  This
means that only the type-attribute syntax is supported:

```swift
func f(fn : @noescape () -> ()) {}     // type attribute.
func f2(a : @autoclosure () -> ()) {}  // type attribute.
```

This aligns with the syntax used for types, since the type of `f` is 
`(_: @noescape () -> ()) -> ()`, and the type of `f2` is 
`(_ : @autoclosure () -> ()) -> ()`.  This fixes the problem with `x2`, and
eliminates the redundancy between the `@noescape` forms.

## Impact on existing code

This breaks existing code that uses these in the old position, so it would be
great to roll this out with the other disruptive changes happening in Swift 3.
The Swift 3 migrator should move these over, and has the information it needs to
do a perfect migration in this case.

For the compiler behavior, given that Swift 2.2 code will be source incompatible
with Swift 3 code in general, it seems best to make these a hard error in the
final Swift 3 release.  It would make sense to have a deprecation warning period
for swift.org projects like corelibs and swiftpm, and other open source users
tracking the public releases.

