# Opaque result types with limited availability

* Proposal: [SE-0360](0360-opaque-result-types-with-availability.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Implementation: [apple/swift#42072](https://github.com/apple/swift/pull/42072), [apple/swift#42104](https://github.com/apple/swift/pull/42104), and [apple/swift#42167](https://github.com/apple/swift/pull/42167)
* Status: **Active review (May 31...June 14, 2022)**

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

To bridge this usability gap I propose to relax same-type restriction for functions with `if #available` conditions if they meet all of the following conditions.

1. There is at least one universally (unconditionally) available `return` in a function. All universally available `return`s are required to produce the same type.

2. `if #available` is a top-level statement in a function and *is not* preceded by any block that can return.

  ```swift
  func test() -> some Shape {
    if #available(macOS 100, *) { ✅
      return Rectangle()
    }

    return self
  }
  ```
  
  The following is incorrect because `if #available` is preceded by a dynamic condition that returns:
  
  ```swift
  func test() -> some Shape {
    guard let x = <opt-value> else {
      return ...
    }
    
    if #available(macOS 100, *) { ❌
      return Rectangle()
    }

    return self
  }
  ```

  `if #available` appears inside of a loop:

  ```swift
  func test() -> some Shape {
    for ... {
      if #available(macOS 100, *) { ❌
        return Rectangle()
      }
    }
    return self
  }
  ```

3. `if #available` has to terminate with a `return`, and all `return` statements inside of a particular `if #available` condition have to produce the same type, which, at the same time, is allowed be different from top-level `return`(s) or `return`s nested in other conditions regardless of their kind.

  The following `test()` function is well-formed because `if` statement produces the same result in both of its branches and it's statically known that the `if #available` always terminates with a `return`
  
  ```swift
  func test() -> some Shape {
    if #available(macOS 100, *) {
       if cond { ✅
         return Rectangle(...)
       } else {
         return Rectangle(...)
       }
    }
    return self
  }
  ```

  But:

  ```swift
  func test() -> some Shape {
    if #available(macOS 100, *) {
       if cond { ❌
         return Rectangle()
       } else {
         return Square()
       }
    }
    return self
  }
  ```

  is not going to be accepted by the compiler because return types are different: `Rectangle` vs. `Square`.

4. `if #available` *cannot* appear in an `else` branch unless all preceding clauses are `if #available` conditions that meet all of the requirements listed in this section.

  The following example is well-formed because the first `if #available` statement terminates with a `return` and the second one is associated with a valid `if #available` and also terminates with a `return`.

  ```swift
  func test() -> some Shape {
    if #available(macOS 100, *) { ✅
      return Rectangle()
    } else if #available(macOS 99, *) { ✅
      return Square()
    }
    return self
  }
  ```

  But

  ```swift
  func test() -> some Shape {
    if cond {
      ...
    } else if #available(macOS 100, *) { ❌
      return Rectangle()
    }
    return self
  }
  ```

  is not accepted by the compiler because `if #available` associated with a dynamic condition.

## Detailed design

Proposed changes allow to:

* Use multiple different `if #available` conditions to return types based on their availability e.g. from the most to least available.
* Safely fallback to a **single** universally available (meaning no availability restrictions) type if none of the conditions are met.

Note that although it is possible to use multiple availability conditions, mixing conditional availability with dynamic checks (`if`, `guard`, `switch`, `for`) would result in `return`s being considered universally available. The following declarations would still be unsupported:

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

or

```
func asRectangle() -> some Shape {
  if <cond> {
    if #available(macOS 100, *) { ❌
     return Rectangle()
    }
  }

  for ... {
    if #available(macOS 100, *) { ❌
     return Rectangle()
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

