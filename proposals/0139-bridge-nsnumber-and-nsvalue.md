# Bridge Numeric Types to `NSNumber` and Cocoa Structs to `NSValue`

* Proposal: [SE-0139](0139-bridge-nsnumber-and-nsvalue.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3.0.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160912/027060.html)

## Introduction

A handful of Swift numeric types are bridged to `NSNumber` when passed
into Objective-C object contexts. We should extend this bridging behavior
to all Swift numeric types. We should also bridge common Cocoa structs such as
`NSRange` by boxing them into `NSValue` objects.

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160822/026560.html)

## Motivation

[SE-0116](0116-id-as-any.md)
changed how Objective-C's `id` and untyped collections import into Swift to
use the `Any` type. This makes it much more natural to pass in Swift value
types such as `String` and `Array`, but introduces the hazard of passing in
types that don't bridge well to Objective-C objects. Particularly problematic
are number types; whereas `Int`, `UInt`, and `Double` will automatically bridge
as `NSNumber`, other-sized numeric types fall back to opaque boxing:

```swift
let i = 17
let plist = ["seventeen": i]
// OK
try! JSONSerialization.data(withJSONObject: plist)

let j: UInt8 = 38
let brokenPlist = ["thirty-eight": j]
// Will throw because `j` didn't bridge to a JSON type
try! JSONSerialization.data(withJSONObject: brokenPlist)
```

We had shied away from enabling this bridging for all numeric types in
the Swift 1.x days, among other reasons because we allowed implicit
bridging conversions in both directions from Swift value types to
`NS` objects and back, which meant that you could slowly and brokenly
convert between any two numeric types transitively via NSNumber if we
allowed this. We killed the implicit conversions completely with
[SE-0072](0072-eliminate-implicit-bridging-conversions.md)
so that is no longer a concern, so expanding the bridging behavior
should no longer be a major problem, since it must now always be
explicitly asked for.

There are also many Cocoa APIs that accept `NSArray` and `NSDictionary`
objects with members that are `NSValue`-boxed structs.
Matt Neuberg highlights Core Animation as an example in
[this bug report](https://bugs.swift.org/browse/SR-2414). With `id`-as-`Any`,
it's natural to expect this to work:

```swift
anim.toValue = CGPoint.zero
```

However, the `CGPoint` value does not box as a meaningful Objective-C object,
so this currently breaks Core Animation at runtime despite compiling
successfully. It would be more idiomatic to bridge these types to `NSValue`.

## Proposed solution

All of Swift's number types should be made to bridge to `NSNumber` when used as
objects in Objective-C:

- `Int8`
- `Int16`
- `Int32`
- `Int64`
- `UInt8`
- `UInt16`
- `UInt32`
- `UInt64`
- `Float`
- `Double`

Cocoa structs with existing `NSValue` factory and property support should
be made to bridge to `NSValue` when used as objects:

- `NSRange`
- `CGPoint`
- `CGVector`
- `CGSize`
- `CGRect`
- `CGAffineTransform`
- `UIEdgeInsets`
- `UIOffset`
- `CATransform3D`
- `CMTime`
- `CMTimeRange`
- `CMTimeMapping`
- `MKCoordinate`
- `MKCoordinateSpan`
- `SCNVector3`
- `SCNVector4`
- `SCNMatrix4`

## Detailed design

Bridged `NSNumber` and `NSValue` objects must be castable back to their
original Swift value types. `NSValue` normally preserves the type information
of its included struct in its `objCType` property. We can check the
`objCType` of an `NSValue` instance when attempting to cast back to a specific
bridged struct type. Note that, although `NSValue` has factory initializers and
accessors for each of the above struct types, the bridging implementation
ought to stick to `NSValue`'s core `valueWithBytes:objCType:` and `getValue:`
API, to avoid potential availability issues with the type-specific methods.

`NSNumber` is a bit trickier, since Cocoa's implementation does not generally
guarantee to remember the exact number type an instance was constructed from.
When we bridge Swift number types to `NSNumber`, though, we use specific
`NSNumber` subclasses to preserve the original Swift type, and in these cases
we can check the exact Swift type in dynamic casts. For NSNumbers from
Cocoa, we can say that casting an `NSNumber` to a Swift
number type succeeds if the value of the `NSNumber` is exactly representable
as the target type. This is imperfect, since it means that an `NSNumber` can
potentially be cast to a different type from the original value.

## Impact on existing code

This change has no static source impact, but changes the dynamic behavior of
the Objective-C bridge. From Objective-C's perspective, values that used to
bridge as opaque objects will now come in as semantically meaningful
Objective-C objects. This should be a safe change, since existing code should
not be relying on the behavior of opaque bridged objects. From Swift's
perspective, values should still be able to round-trip from concrete number
and struct types to `Any` to `id` to `Any` and back by dynamic casting.
The ability to reliably distinguish the exact number type that an `NSNumber`
was constructed from would be lost.

## Alternatives considered

We can of course do nothing and leave the behavior as-is.

`NSValue` also carries factories for `valueWithPointer:` and
`valueWithNonretainedObject:`. Maybe we could bridge
`UnsafePointer` and `Unmanaged` this way, but we probably shouldn't.

Instead of implementing `NSValue` bridging in the overlay, Zach Waldowski
suggests using Objective-C's `__attribute__((objc_boxable))`, which enables
autoboxing of a struct in ObjC with `@(...)` syntax, to also instruct Swift's
Clang importer to synthesize a bridge to `NSValue` automatically for types
annotated with the attribute. However, this attribute hasn't been widely
adopted in Apple SDKs.
