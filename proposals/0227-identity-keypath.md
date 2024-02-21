# Identity key path

* Proposal: [SE-0227](0227-identity-keypath.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.0)**
* Implementation: [apple/swift#18804](https://github.com/apple/swift/pull/18804), [apple/swift#19382](https://github.com/apple/swift/pull/19382)
* Review: [Discussion thread](https://forums.swift.org/t/se-0227-identity-key-path/15830), [Announcement thread](https://forums.swift.org/t/accepted-se-0227-identity-key-path/16278)

## Introduction

Add the ability to reference the identity key path, which refers to the entire
input value it is applied to.

Swift-evolution thread: [Some small keypath extensions: identity and tuple components](https://forums.swift.org/t/some-small-keypath-extensions-identity-and-tuple-components/13729)

## Motivation

Key paths provide a means to refer to part of a value or a path through an
object graph independent of any specific instance. In most places where this
is useful, it is also useful to be able to refer to the entire value.
For instance, one could have a coordinator object that owns a state value and
notifies observers of changes to the state by allowing modification through
key paths:

```swift
class ValueController<T> {
  private var state: T

  private var observers: [(T) -> ()]

  subscript<U>(key: WritableKeyPath<T, U>) {
    get { return state[keyPath: key] }
    set {
      state[keyPath: key] = newValue
      for observer in observers {
        observer(state)
      }
    }
  }
}
```

With such an interface, it'd be useful to be able to update the entire state
object at once.

## Proposed solution

We add a way to refer to the **identity key path**, which refers to the entire
input value a key path applies to.

## Detailed design

Every value in Swift has a special pseudo-property `.self`, which refers to
the entire value:

```swift
var x = 1
x.self = 2
print(x.self) // prints 2
```

By analogy, we could spell the identity key path `\.self`, since it notionally
refers to this `self` member:

```swift
let id = \Int.self

x[keyPath: id] = 3
print(x[keyPath: id]) // prints 3

struct Employee {
  var name: String
  var position: String
}

func updateValue(of vc: ValueController<Employee>) {
  vc[\.self] = Employee(name: "Cassius Green", position: "Power Caller")
}
```

The identity key path is a `WritableKeyPath<T, T>`, since it can be used to
mutate a mutable value, but cannot mutate immutable references. It also
makes sense to give the identity key path special behavior with other
key path APIs:

- Appending an identity key path produces a key path equal to the other
  operand:

    ```swift
    kp.appending(path: \.self) // == kp
    (\.self).appending(path: kp) // == kp
    ```

- Asking for the `offset(of:)` the identity key path produces `0`, since
  reading and writing a `T` at offset zero from an `Unsafe(Mutable)Pointer<T>`
  is of course equivalent to reading the entire value:

    ```
    MemoryLayout<Int>.offset(of: \.self) // == 0
    ```

Also, for compatibility with Cocoa KVC, the identity key path maps to the
`@"self"` KVC key path.

## Source compatibility

This is an additive feature.

## Effect on ABI stability

The Swift standard library required some modifications to correctly handle
identity key paths.

## Alternatives considered

The biggest design question here is the syntax. Some other alternatives
include:

- The special syntax `\.`, a key path with "no components".
- A static property on `KeyPath` and/or `WritableKeyPath`.

