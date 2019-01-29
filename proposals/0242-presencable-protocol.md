# Presencable Protocol

* Proposal: [SE-0242](0242-presencable-protocol.md)
* Authors: [Dmytro Pylypenko](https://github.com/dimpiax)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

`Presencable` and `Emptiable` protocols for extending types functionality.

It gives the properties `presence` and `isEmpty` accordingly, where
`presence` of value retrieves itself in case when `isEmpty` is false,
otherwise `nil`.

Swift-evolution thread: [Presence. [value.isEmpty ? nil : value]](https://forums.swift.org/t/presence-value-isempty-nil-value/14869)

## Motivation

A lot of cases when there is no need to work with object which is empty,
and nowadays we have to write:
```swift
func retrieve() -> [Array] {
  // implementation
}

// 1
let array = retrieve()
guard !array.isEmpty else { return }

// 2
func action() {
  ...
  return array.isEmpty : nil : array
}
```

## Proposed solution

Create protocols `Emptiable`, `Presencable` and extend `Collection`.

Instead we can use property `presence` and be sure that we get value only if it's not being empty.
```swift
func retrieve() -> [Array] {
  // implementation
}

// 1
guard let array = retrieve().presence else { return }

// 2
func action() {
  ...
  return array.presence
}
```

## Detailed design

For solution implementation, we need to declare two protocols `Emptiable` and `Presencable`.
```swift
protocol Emptiable {
  var isEmpty: Bool { get }
}

protocol Presencable: Emptiable {
  var presence: Self? { get }
}

extension Presencable {
  var presence: Self? {
    return isEmpty ? nil : self
  }
}
```

For types that implement `Collection` protocol, it's enough to implement it with protocol `Presencable`. In this case, all types that implement `Collection` will have property `presence`.

```swift
public protocol Collection : Sequence, Presencable {
  // declaration
}

let arr = [1, 3]
arr.dropFirst(2).presence // nil
arr.presence // arr
```

For types that are not implement `Collection`, directly reference to `Presencable` protocol is needed.
```swift
struct Foo: Presencable {
  let collection: Set<Int>

  var isEmpty: Bool {
    return collection.isEmpty
  }

  init(_ values: Int...) {
    collection = Set(values)
  }
}

Foo(1, 2, 3).presence // Foo
Foo().presence // nil
```

## Source compatibility

This is a purely additive change, and so has no impact.

## Effect on ABI stability

This is a purely additive change, and so has no impact.

## Effect on API resilience

This is a purely additive change, and so has no impact.

## Alternatives considered

In other case we can extend `Collection` protocol directly, but without additional protocol layers that are helpful and can be widely reused, as for custom types.

```swift
extension Collection {
  var presence: Self? {
    return isEmpty ? nil : self
  }
}
```
