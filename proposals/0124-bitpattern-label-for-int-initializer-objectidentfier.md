# `Int.init(ObjectIdentifier)` and `UInt.init(ObjectIdentifier)` should have a `bitPattern:` label

* Proposal: [SE-0124](0124-bitpattern-label-for-int-initializer-objectidentfier.md)
* Author: [Arnold Schwaighofer](https://github.com/aschwaighofer)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-July/000241.html)
* Bug: [SR-2064](https://bugs.swift.org/browse/SR-2064)

## Introduction

`Int.init(ObjectIdentifier)` and `UInt.init(ObjectIdentifier)` should have a
'bitPattern:’ label to make it clear at the use site that we interpret the value
as a bit pattern.

```swift
  public func <(lhs: ObjectIdentifier, rhs: ObjectIdentifier) -> Bool {
    return UInt(bitPattern: lhs) < UInt(bitPattern: rhs)
  }
```

- Swift-evolution thread: [Pitch](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160711/024323.html)
- Swift Bug: [SR-2064](https://bugs.swift.org/browse/SR-2064)
- Branch with change to stdlib: [int_init_objectidentifier_label] (https://github.com/aschwaighofer/swift/tree/int_init_objectidentifier_label)

## Motivation

In Swift we have `ObjectIdentifier` values which uniquely identify a class
instance or metatype. They are implemented as a struct which holds the value of
the reference to the instance or metatype as a raw pointer.

```swift
  /// A unique identifier for a class instance or metatype.
  public struct ObjectIdentifier : Hashable, Comparable {
    internal let _value: Builtin.RawPointer
    ...
  }
```

We have constructors for `Int` and `UInt` that capture this value. These
constructors don’t have an argument label.

```swift
  extension UInt {
    /// Create a `UInt` that captures the full value of `objectID`.
    public init(_ objectID: ObjectIdentifier) {
      self.init(Builtin.ptrtoint_Word(objectID._value))
    }
  }

  extension Int {
    /// Create an `Int` that captures the full value of `objectID`.
    public init(_ objectID: ObjectIdentifier) {
      self.init(bitPattern: UInt(objectID))
    }
  }
```

This proposals suggest adding a label `bitPattern:` to the constructor.

```swift
  extension UInt {
    /// Create a `UInt` that captures the full value of `objectID`.
    public init(bitPattern objectID: ObjectIdentifier) {
      self.init(Builtin.ptrtoint_Word(objectID._value))
    }
  }

  extension Int {
    /// Create an `Int` that captures the full value of `objectID`.
    public init(bitPattern objectID: ObjectIdentifier) {
      self.init(bitPattern: UInt(objectID))
    }
  }
```

Adding a label `bitPattern` to the constructors makes it clear that we interpret
the pointer value as a bit pattern at the use site. It is similar to what we do
in other APIs, for example in `UInt(bitPattern: UnsafePointer<Void>(value)))`.


## Proposed solution

See above.

## Detailed design

We will change the initializers of `Int` and `UInt` as shown above. The compiler
will suggest corrections in existing code because we mark the old API
unavailable.

## Impact on existing code

Existing code will have to add the argument label.

## Alternatives considered

Leave as is. The API will be inconsistent with other APIs such as the
`UInt(bitPattern: UnsafePointer<T>)` API.

