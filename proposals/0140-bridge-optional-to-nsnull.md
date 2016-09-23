# Warn when `Optional` converts to `Any`, and bridge `Optional` As Its Payload Or `NSNull`

* Proposal: [SE-0140](0140-bridge-optional-to-nsnull.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Implemented (Swift 3.0.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160912/027062.html)

## Introduction

`Optional`s can be used as values of `Any` type. After
[SE-0116](0116-id-as-any.md),
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

[SE-0116](0116-id-as-any.md)
changed how Objective-C's `id` and untyped collections import into Swift to
use the `Any` type. This makes it much more natural to pass Swift value
types such as `String` and `Array` into ObjC. One unfortunate effect is that,
since `Any` in Swift can hold *anything*, it is now possible to pass an 
`Optional` to an Objective-C API that expects a nonnull `id`.
This is not a new issue in Swift--it is possible to use an Optional anywhere
there's unconstrained polymorphism, for example, in string interpolations, or
as the element type of a collection, such as an `Array<T?>`, but bridging
`id` as `Any` makes this problem much more prevalent. Since Cocoa APIs
traffic heavily in Optionals, it's very easy to accidentally take an Optional
result from one API and pass it as `Any` to another API without unwrapping it
first. We can introduce a warning when an `Optional` is implicitly converted to
`Any`.

However, since this is dynamic behavior, it is impossible to prevent
`Optional`s ending up in `Any`s in all cases, nor would it be desirable to
completely prevent it, since it is sometimes useful to keep an `Optional`
inside an `Any`. Containers and other generic types with `Optional` members are
also useful. Because `Optional` does not currently have any special bridging
behavior, it will currently be bridged to Objective-C as an opaque object,
which will be unusable by most Objective-C API. In Objective-C, Cocoa provides
`NSNull` as a standard, non-`nil` singleton to represent missing values inside
collections, since `NSArray`, `NSDictionary`, and `NSSet` are unable to hold
`nil` elements. If we bridge `Optional`s so that, when they contain `some`
value, we bridge the wrapped value, or use `NSNull` to represent `none`, then
we get several advantages over the current behavior:

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

`NSNull` is rare in Cocoa, and perhaps not that much more useful than an
arbitrary sentinel object or opaque box, but is the object most likely to
have a useful meaning to existing ObjC APIs.

## Proposed solution

Converting an `Optional<T>` to an `Any` should raise a warning unless the
conversion is made explicit. When an `Optional<T>` value does end up in an
`Any`, and gets bridged to an Objective-C object, if it contains `some` value,
that value should be bridged; otherwise, `NSNull` or another sentinel object
should be used.

## Detailed design

### Warning when `Optional` is converted to `Any`

When we put an `Optional` into an `Any`, we should warn on the implicit
conversion:

```swift
let x: Int? = 3
let y: Any = x // warning: Optional was put in an Any without being unwrapped

// `print` takes parameters of type Any
print(x) // warning: Optional was passed as an argument of type Any without
         // being unwrapped

// `NSMutableArray` has elements of type `id _Nonnull` in ObjC,
// imported as `Any` in Swift
let a = NSMutableArray()
a.add(x)  // warning: Optional was passed as an argument of type Any without
          // being unwrapped
```

If passing the `Optional` is intentional, the warning can be suppressed by
making the conversion explicit with `as Any`:

```swift
let y: Any = x as Any
print(x as Any)
a.add(x as Any)
```

### Bridging `Optional`s

`Optional` can conform to the implementation-
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

There are unconstrained contexts other than `Any` promotion where `Optional`s
can be used by accident without unwrapping, such as `String.init(describing:)`,
which takes a generic `<T>`. We may want to warn in some of these cases, but
there are subtleties that require deeper consideration. Extending the warning
can be considered in the future.

We could do nothing, and leave Optionals to bridge by opaque boxing. Charles
Srstka argues that passing Optionals into ObjC via `Any` is programmer
error, so should fail early at runtime:

> I’d say my position has three planks on it, and the above is pretty much the first plank: 1) the idea of an array of optionals is a concept that doesn’t really exist in Objective-C, and I do think that passing one to Obj-C ought to be considered a programmer error.
> 
> The other two planks would be:
> 
> 2) Bridging arrays of optionals in this manner could mask the aforementioned programmer error, resulting in unexpected, hard-to-reproduce crashes when an NSNull is accessed as if it were something else, and:

> 3) Objective-C APIs that accept NSNull objects are fairly rare, so the proposed bridging doesn’t really solve a significant problem (and in the cases where it does, using a map to replace nils with NSNulls is not difficult to write).

This point of view is understandable, but is inconsistent with how Swift itself
dynamically treats Optionals inside Anys:

  let a: Int? = 3
  let b = a as Any
  let c = a as! Int // Casts '3' out of the Optional as a non-optional Int

And while it's true that Cocoa uses `NSNull` sparingly, it *is* the standard
sentinel used in the few places where a null-like object is expected, such as
in collections and JSON serialization.
