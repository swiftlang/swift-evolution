# `weak let`

* Proposal: [SE-0481](0481-weak-let.md)
* Authors: [Mykola Pokhylets](https://github.com/nickolas-pohilets)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Accepted**
* Implementation: [swiftlang/swift#80440](https://github.com/swiftlang/swift/pull/80440)
* Upcoming Feature Flag: `ImmutableWeakCaptures`
* Review: ([discussion](https://forums.swift.org/t/weak-captures-in-sendable-sending-closures/78498)) ([pitch](https://forums.swift.org/t/pitch-weak-let/79271)) ([review](https://forums.swift.org/t/se-0481-weak-let/79603)) ([acceptance](https://forums.swift.org/t/accepted-se-0481-weak-let/79895))

[SE-0302]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md

## Introduction

Swift provides weak object references using the `weak` modifier on variables and stored properties. Weak references become `nil` when the object is destroyed, causing the value of the variable to seem to change. Swift has therefore always required `weak` references to be declared with the `var` keyword rather than `let`. However, that causes unnecessary friction with [sendability checking][SE-0302]: because weak references must be mutable, classes and closures with such references are unsafe to share between concurrent contexts. This proposal lifts that restriction and allows `weak` to be combined with `let`.

## Motivation

Currently, Swift classes with weak stored properties cannot be `Sendable`, because weak properties have to be mutable, and mutable properties are not allowed in `Sendable` classes:

```swift
final class C: Sendable {}

final class VarUser: Sendable {
    weak var ref1: C? // error: stored property 'ref1' of 'Sendable'-conforming class 'VarUser' is mutable
}
```

Similarly, closures with explicit `weak` captures cannot be `@Sendable`, because such captures are implicitly *made* mutable, and `@Sendable` closures cannot capture mutable variables. This is surprising to most programmers, because every other kind of explicit capture is immutable. It is extremely rare for Swift code to directly mutate a `weak` capture.

```swift
func makeClosure() -> @Sendable () -> Void {
    let c = C()
    return { [weak c] in
        c?.foo() // error: reference to captured var 'c' in concurrently-executing code

        c = nil // allowed, but surprising and very rare
    }
}
```

In both cases, allowing the weak reference to be immutable would solve the problem, but this is not currently allowed:

```swift
final class LetUser: Sendable {
    weak let ref1: C? // error: 'weak' must be a mutable variable, because it may change at runtime
}
```

The restriction that weak references have to be mutable is based on the idea that the reference is mutated when the referenced object is destroyed. Since it's mutated, it must be kept in mutable storage, and hence the storage must be declared with `var`. This way of thinking about weak references is problematic, however; it does not work very well to explain the behavior of weak references that are components of other values, such as `struct`s. For example, a return value is normally an immutable value, but a `struct` return value can contain a weak reference that may become `nil` at any point.

In fact, wrapping weak references in a single-property `struct` is a viable workaround to the `var` restriction in both properties and captures:

```swift
struct WeakRef {
    weak var ref: C?
}

final class WeakStructUser: Sendable {
    let ref: WeakRef // ok
}

func makeClosure() -> @Sendable () -> Void {
    let c = C()
    return { [c = WeakRef(ref: c)] in 
        c.ref?.foo() // ok
    }
}
```

The existence of this simple workaround is itself an argument that the prohibition of `weak let` is not enforcing some fundamentally important rule.

It is true that the value of a `weak` variable can be observed to change when the referenced object is destroyed. However, this does not have to be thought of as a mutation of the variable. A different way of thinking about it is that the variable continues to hold the same weak reference to the object, but that the program is simply not allowed to observe the object through that weak reference after the object is destroyed. This better explains the behavior of weak references in `struct`s: it's not that the destruction of the object changes the `struct` value, it's that the weak reference that's part of the `struct` value will now return `nil` if you try to observe it.

Note that all of this relies on the fact that the thread-safety of observing a weak reference is fundamentally different from the thread-safety of assigning `nil` into a `weak var`. Swift's weak references are thread-safe against concurrent destruction: well-ordered reads and writes to a `weak var` or `weak let` will always behave correctly even if the referenced object is concurrently destroyed. But they are not *atomic* in the sense that writing to a `weak var` will behave correctly if another context is concurrently reading or writing to that same `var`. In this sense, a `weak var` is like any other `var`: mutations need to be well-ordered with all other accesses. 

## Proposed solution

`weak` can now be freely combined with `let` in any position that `weak var` would be allowed.
Similar to `weak var`, `weak let` declarations also must be of `Optional` type.

This proposal maintains the status quo regarding `weak` on function arguments and computed properties:
* There is no valid syntax to indicate that function argument is a weak reference.
* `weak` on computed properties is allowed, but has no effect.

An explicit `weak` capture is now immutable under this proposal, like any other explicit capture. If the programmer really needs a mutable capture, they must capture a separate `weak var`:

```swift
func makeClosure() -> @Sendable () -> Void {
    let c = C()
    // Closure is @Sendable
    return { [weak c] in
        c?.foo()
        c = nil // error: cannot assign to value: 'c' is an immutable capture
    }
}

func makeNonSendableClosure() -> () -> Void {
    let c = C()
    weak var explicitlyMutable: C? = c
    // Closure cannot be @Sendable anymore
    return {
        explicitlyMutable?.foo()
        explicitlyMutable = nil // ok
    }
}
```

## Source compatibility

Allowing `weak let` bindings is an additive change that makes previously invalid code valid. It is therefore perfectly source-compatible.

Treating weak captures as immutable is a source-breaking change. Any code that attempts to write to the capture will stop compiling.
The overall amount of such code is expected to be small.

Since the captures of a closure are opaque and cannot be observed outside of the closure, changing the mutability of weak captures has no impact on clients of the closure.

## ABI compatibility

There is no ABI impact of this change.

## Implications on adoption

This feature can be freely adopted and un-adopted in source code with no deployment constraints and without affecting source or ABI compatibility.
