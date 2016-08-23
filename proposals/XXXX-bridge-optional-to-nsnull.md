# Bridge `Optional` As Its Payload Or `NSNull`

* Proposal: [SE-NNNN](XXXX-bridge-nsnumber-and-nsvalue.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

`Optional`s can be used as values of the type `Any`, but only bridge as opaque
objects in Objective-C. We should bridge `Optional`s with `some` value by
bridging the wrapped value, and bridge `nil`s to the `NSNull` singleton.

Swift-evolution thread: [TBD](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

[SE-0116](https://github.com/apple/swift-evolution/blob/master/proposals/0116-id-as-any.md)
changed how Objective-C's `id` and untyped collections import into Swift to
use the `Any` type. This makes it much more natural to pass in Swift value
types such as `String` and `Array`, but introduces the opportunity for
optionality mismatches, since an `Any` can contain a wrapped `Optional`
value just like anything else.  Our current behavior, where `Optional` is given
only the default opaque bridging behavior, leads to brittle transitivity
problems with collection subtyping. For example, an array of `Optional` objects
bridges to an `NSArray` of opaque objects, unusable from ObjC:

```swift
class C {}
let objects: [C?] = [C(), nil, C()]
```

The more idiomatic mapping would be to use `NSNull` or some other sentinel
to represent the missing values (since `NSArray` cannot directly store `nil`).
Counterintuitively, this is in fact what you get if you bridge an
array of `Any` with nil elements:

```swift
class C {}
let objects: [Any] = [C(), nil as C?, C()]
```

though with an opaque box taking the place of the standard `NSNull` sentinel.
Since there's a subtype relationship between `T` and `Optional<T>`, it's
also intuitive to expect that the bridging operation be consistent between 
`T` and occupied values of `Optional<T>`.

## Proposed solution

When an `Optional<T>` value is bridged to an Objective-C object, if it contains
`some` value, that value should be bridged; otherwise, `NSNull` or another
sentinel object should be used.

## Detailed design

TODO

- `some` maps to the bridged value
- `none` maps to `NSNull`
- if we don't want to lose information about nested optionals, we'd need
  a unique `SwiftNull` object for every optional type, so that `.some(.none)`
  maps to `NSNull` and `.none` maps to `SwiftNull(T?)`

## Impact on existing code

This change has no static source impact, but changes the dynamic behavior of
the Objective-C bridge. From Objective-C's perspective, `Optionals` that used to
bridge as opaque objects will now come in as semantically meaningful
Objective-C objects. This should be a safe change, since existing code should
not be relying on the behavior of opaque bridged objects. From Swift's
perspective, values should still be able to round-trip from `Optional`
to `Any` to `id` to `Any` and back by dynamic casting.

## Alternatives considered

TODO

- Do nothing
- Attempt to trap or error when Optionals are used as Anys -- would be good
  QoI to warn, but it can't be prevented, and is occasionally desired
