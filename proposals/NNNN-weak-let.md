# Feature name

* Proposal: [SE-NNNN](NNNN-weak-let.md)
* Authors: [Mykola Pokhylets](https://github.com/nickolas-pohilets)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift#80440](https://github.com/swiftlang/swift/pull/80440)
* Upcoming Feature Flag: `WeakLet`
* Review: ([discussion](https://forums.swift.org/t/weak-captures-in-sendable-sending-closures/78498))

## Introduction

Currently Swift requires weak stored variables to be mutable.
This restriction is rather artificial, and causes friction with sendability checking.

## Motivation

Currently swift classes with weak stored properties cannot be `Sendable`,
because weak properties have to be mutable, and mutable properties are 
not allowed in `Sendable` classes.

Similarly, closures with `weak` captures cannot be `@Sendable`,
because such captures are implicitly made mutable.

Usually developers are not aware of this implicit mutability and have no intention to modify the captured variable.
Implicit mutability of weak captures is inconsistent with `unowned` or default captures.

Wrapping weak reference into a single-field struct, allows stored properties and captures to be immutable.

```swift
final class C: Sendable {}

struct WeakRef {
    weak var ref: C?
}

final class User: Sendable {
    weak let ref1: C? // error: 'weak' must be a mutable variable, because it may change at runtime
    let ref2: WeakRef // ok
}

func makeClosure() -> @Sendable () -> Void {
    let c = C()
    return { [weak c] in
        c?.foo() // error: reference to captured var 'c' in concurrently-executing code
        c = nil // nobody does this
    }
    return { [c = WeakRef(ref: c)] in 
        c.ref?.foo() // ok
    }
}
```

Existence of this workaround shows that ban on `weak let` variables is artificial, and can be lifted.

Note that resetting weak references on object destruction is different from regular variable modification.
Resetting on destruction is implemented in a thread-safe manner, and can safely coexist with concurrent reads or writes.
But regular writing to a variable requires exclusive access to that memory location. 

## Proposed solution

Allow `weak let` declarations for local variables and stored properties.

Proposal maintains status quo regarding use of `weak` on function arguments and computed properties:
* there is no valid syntax to indicate that function argument is a weak reference;
* `weak` on computed properties is allowed, but has not effect.

Weak captures are immutable under this proposal. If mutable capture is desired,
mutable variable need to be explicit declared and captured.

```swift
func makeClosure() -> @Sendable () -> Void {
    let c = C()
    // Closure is @Sendable
    return { [weak c] in
        c?.foo()
        c = nil // error: cannot assign to value: 'c' is an immutable capture
    }

    weak var explicitlyMutable: C? = c
    // Closure cannot be @Sendable anymore
    return {
        explicitlyMutable?.foo()
        explicitlyMutable = nil // but assigned is ok
    }
}
```

## Source compatibility

Allowing `weak let` bindings is a source-compatible change
that makes previously invalid code valid.

Treating weak captures as immutable is a source-breaking change.
Any code that attempts to write to the capture will stop compiling.
The overall amount of such code is expected to be small.

## ABI compatibility

This is an ABI-compatible change.

## Implications on adoption

This feature can be freely adopted and un-adopted in source
code with no deployment constraints and without affecting source or ABI
compatibility.
