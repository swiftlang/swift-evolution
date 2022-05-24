# [Pitch] Opaque result types with limited availability

* Proposal: [SE-NNNN](NNNN-opaque-result-types-with-availability.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: TBD
* Implementation: [apple/swift#42072](https://github.com/apple/swift/pull/42072), [apple/swift#42104](https://github.com/apple/swift/pull/42104), and [apple/swift#42167](https://github.com/apple/swift/pull/42167)
* Status: **Awaiting discussion**

## Introduction

Since their introduction in [SE-0244](https://github.com/apple/swift-evolution/blob/main/proposals/0244-opaque-result-types.md), opaque result types have become a powerful tool of type-level abstraction that allows library authors to hide implementation details of their APIs.

Under the rules described in SE-0244 - a function returning an opaque result type *must return a value of the same concrete type `T`* from each `return` statement, and `T` must meet all of the constraints stated on the opaque type. 

The same-type `return` requirement is unnecessarily strict when it comes to availability conditions. SE-0244 states that it should be possible to change the underlying type in the future version of the library, but that would only work with pre-existing types. In other words, the same-type condition does not have to apply across executions of the same program, the same way that `Hashable` must produce the same output for the same value during program execution, but may produce a different value in the next execution. `#available` is special because it's a checkable form of that: dynamic availability will not change while the program is running, but may be different the next time the program runs.

Current model and implementation limits usefulness of opaque result types as an abstraction mechanism, because it prevents frameworks from introducing new types and using them as underlying types in existing APIs. To bridge this usability gap, I propose to relax same-type restriction for `return`s inside of availability conditions.

Swift-evolution thread: [
[Pitch] Opaque result types with limited availability](https://forums.swift.org/t/pitch-opaque-result-types-with-limited-availability/57286)

## Motivation

To illustrate the problematic interaction between opaque result types and availability conditions, let's consider a framework that already has a `Shape` protocol and a `Square` type that conforms to the `Shape` protocol. 

```
protocol Shape {
  func draw(to: Surface)
}

struct Square : Shape {
  ...
}
```

In a new version of the framework, the library authors decided to introduce a new shape - `Rectangle` with limited availability:

```
@available(macOS 100, *)
struct Rectangle : Shape {
  ...
}
```

Since a `Rectangle` is generalization of a `Square` it makes sense to allow transforming a `Square` into a `Rectangle` but that currently requires extension with limited availability:

```
@available(macOS 100, *)
extension Square {
  func asRectangle() -> some Shape {
     return Rectangle(...)
  }
}
```

The fact that the new method has to be declared in availability context to return `Rectangle` limits its usefulness because all uses of `asRectangle` would have be encapsulated into `if #available` blocks.

If `asRectangle` already existed in the original version of the framework, it wouldn’t be possible to use a new type at all without declaring `if #available` block in its body:

```
struct Square {
  func asRectangle() -> some Shape {
     if #available(macOS 100, *) {
        return Rectangle(...)
     }
     
     return self
  }
}
```

But doing so is not allowed because all of the `return` statements in the body of the `asRectangle` function have to return the same concrete type:

```
 error: function declares an opaque return type 'some Shape', but the return statements in its body do not have matching underlying types
  func asRectangle() -> some Shape {
       ^                ~~~~~~~~~~
note: return statement has underlying type 'Rectangle'
      return Rectangle()
             ^
note: return statement has underlying type 'Square'
    return Square()
           ^
```

This is a dead-end for the library author although SE-0244 states that it should be possible to change underlying result type in the future version of the library/framework but that assumes that the type already exists so it could be used in all `return` statements.

## Proposed solution

To bridge this usability gap I propose to relax same-type restriction for `return`s inside of availability conditions as follows:

A function returning an opaque result type is allowed to return values of different concrete types from conditionally available `if #available`  branches without any other dynamic conditions, if and only if, all universally available `return` statements in its body return a value of the same concrete type `T`. All returned values regardless of their location must meet all of the constraints stated on the opaque type.

## Detailed design

Proposed changes allow to:

* Use multiple different `if #available` conditions to return types based on their availability e.g. from the most to least available.
* Safely fallback to a **single** universally available type if none of the conditions are met.

Note that although it is possible to use multiple availability conditions, mixing conditional availability with dynamic checks would result in `return`s being considered universally available. The following declarations would still be unsupported:

```
func asRectangle() -> some Shape { 
  if <cond>, #available(macOS 100, *) { ❌
     return Rectangle()
  }
  return self
}
```

or

```
func asRectangle() -> some Shape {
  if #available(macOS 100, *) {
     if cond { ❌
       return Rectangle()
     } else {
       return self
     }
  }
  return self
}
```

In both of this examples `self` and `Rectangle` would have to be same concrete type which is consistent with existing behavior.

This semantic adjustment fits well into the existing model because it makes sure that there is always a single underlying type per platform and universally.

## Source compatibility

Proposed changes do not break source compatibility and allow previously incorrect code to compile.

## Effect on ABI stability

No ABI impact since this is an additive change.

## Effect on API resilience

All of the resilience rules associated with opaque result types are preserved.

## Alternatives considered

* Only alternative is to change the API patterns used in the library, e.g. by exposing the underlying result type and overloading the method.

