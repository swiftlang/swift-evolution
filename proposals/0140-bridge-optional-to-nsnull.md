# Bridge `Optional` As Its Payload Or `NSNull`

* Proposal: [SE-0140](0140-bridge-nsnumber-and-nsvalue.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active Review (September 2...September 8)**

## Introduction

`Optional`s can be used as values of `Any` type. After
[SE-0116](https://github.com/apple/swift-evolution/blob/master/proposals/0116-id-as-any.md),
this means you can pass an `Optional` to an Objective-C method expecting
nonnull `id`:

```objc
// Objective-C
@interface ObjCClass : NSObject
- (void)imported: (id _Nonnull)value;
@end
```

```swift
let s1: String? = nil, s2: String? = "hello"
// works, should warn, currently produces an opaque object type
ObjCClass().imported(s1)
// works, should warn, currently produces an opaque object type
ObjCClass().imported(s2)
```

This is often a mistake, and we should raise a warning
when it occurs, but is occasionally useful. When an `Optional` is intentionally
passed into Objective-C as a nonnull object, we should bridge
`some` value by bridging the wrapped value, and bridge `none`s to a singleton
such as `NSNull`:

```swift
let s1: String? = nil, s2: String? = "hello"
// proposed to bridge to NSNull.null
ObjCClass().imported(s1)
// proposed to bridge to NSString("hello")
ObjCClass().imported(s2)
```

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160822/026561.html)

## Motivation

[SE-0116](https://github.com/apple/swift-evolution/blob/master/proposals/0116-id-as-any.md)
changed how Objective-C's `id` and untyped collections import into Swift to
use the `Any` type. This makes it much more natural to pass Swift value
types such as `String` and `Array` into ObjC. One unfortunate effect is that,
since `Any` in Swift can hold *anything*, it is now possible to pass an 
`Optional` to an Objective-C API that expects a nonnull `id`.
This is not a new issue in Swift--it is possible to use an Optional anywhere
there's unconstrained polymorphism, for example, in string interpolations, or
as the element type of a collection, such as an `Array<T?>`.
Since `Optional` does not currently have any special bridging behavior, it will
currently be bridged to Objective-C as an opaque object, which will be unusable
by most Objective-C API. In Objective-C, Cocoa provides `NSNull` as a
standard, non-`nil` singleton to represent missing values inside collections,
since `NSArray`, `NSDictionary`, and `NSSet` are unable to hold `nil` elements.
If we bridge `Optional`s so that, when they contain `some` value, we bridge
the wrapped value, or use `NSNull` to represent `none`, then we get several
advantages over the current behavior:

- Passing a wrapped `Optional` value into Objective-C will work more
  consistently with how `Optional`s inside `Any`s work in Swift. Swift
  considers `T` to be a subtype of `T?`, so even if an `Any` contains
  an optional, casting to the nonoptional type will succeed if the `Any`
  contains an optional with a value. By analogy in Objective-C, we would want
  an `Optional` passed into ObjC as `id` to be an instance of the unwrapped
  class type, so that `isKindOfClass:` and `respondsToSelector:` queries succeed
  if a valid value is passed in.
- Passing `Optional.none` to Objective-C APIs that idiomatically expect
  `NSNull` will do the right thing. Swift collections such as `[T?]` will
  automatically map to `NSArray`s containing `NSNull` sentinels, their closest
  idiomatic analogue in ObjC.
- Passing `Optional.none` to Objective-C APIs that expect neither `nil` nor
  `NSNull` will fail in more obvious ways, usually with an `NSNull does not
  respond to selector` exception of some kind. `id`-based Objective-C APIs
  fundamentally cannot catch all misuses at compile time, so runtime errors
  on user error are unavoidable.

## Proposed solution

When an `Optional<T>` value is bridged to an Objective-C object, if it contains
`some` value, that value should be bridged; otherwise, `NSNull` or another
sentinel object should be used.

## Detailed design

This can be implemented by having `Optional` conform to the implementation-
internal `_ObjectiveCBridgeable` protocol. One subtlety is with nested
optional types, such as `T??`; these are rare, but when they occur, we would
want to preserve their value in round-trips through the Objective-C bridge, so
we would need to be able to use a different sentinel to distinguish
`.some(.none)` from `.none`. Since there is no idiomatic equivalent in Cocoa
for a nested optional, we can use an opaque singleton object to represent
each level of `none` nesting:

```swift
var x: String???

x = String?.none
x as AnyObject // bridges to NSNull, since it's an unnested `.none`

x = String??.none
x as AnyObject // bridges to _SwiftNull(1), since it's a double-`.none`

x = String???.none
x as AnyObject // bridges to _SwiftNull(2), since it's a triple-`.none`
```

Like default-bridged `_SwiftValue` boxes, these would be `id`-compatible
but otherwise opaque singletons.

## Impact on existing code

This change has no static source impact, but changes the dynamic behavior of
the Objective-C bridge. From Objective-C's perspective, `Optionals` that used to
bridge as opaque objects will now come in as semantically meaningful
Objective-C objects. This should be a safe change, since existing code should
not be relying on the behavior of opaque bridged objects. From Swift's
perspective, values should still be able to round-trip from `Optional`
to `Any` to `id` to `Any` and back by dynamic casting.

## Alternatives considered

We could do nothing, and leave Optionals to bridge by opaque boxing. I think
this is unsatisfactory; feedback from SE-0116 is showing that users expect
to be able to pass wrapped Optional values into ObjC and have the wrapped
values bridge. It also leads to a weird-feeling inconsistency with container
bridging. If you have an array of optionals, such as:

```
class C {}
let a: [C?] = [C(), nil, C()]
```

then `a` will bridge to Objective-C as an `NSArray` of unusable objects.
However, if you instead pass in an array of `Any`:

```
class C {}

let a: [Any] = [C(), nil as C?, C()]
```

then you get a more functional `NSArray` in Objective-C, since the non-`nil`
elements will get carried over, and only the `nil` value becomes an opaque
object. It feels counterintuitive that a *less* type-specific Array would
give better results than the more specific array type.
