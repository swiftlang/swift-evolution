# Remove bridging conversion behavior from dynamic casts

* Proposal: [SE-0083](0083-remove-bridging-from-dynamic-casts.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Deferred**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000173.html)

## Introduction

Dynamic casts using `as?`, `as!`, and `is` are currently able to dynamically
perform Cocoa bridging conversions, such as from `String` to `NSString` or from
an `ErrorProtocol`-conforming type to `NSError`. This functionality should be
removed to make dynamic cast behavior simpler, more efficient, and
easier to understand. To replace this functionality, initializers should be
added to bridged types, providing an interface for these conversions that's
more consistent with the conventions of the standard library.

Swift-evolution thread: [Reducing the bridging magic in dynamic casts](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/016171.html)

## Motivation

When we introduced Swift, we wanted to provide value types for common
containers, with the safety and state isolation benefits they provide, while
still working well with the reference-oriented world of Cocoa. To that end, we
invested a lot of work into bridging between Swift's value semantics containers
and their analogous Cocoa container classes. This bridging consisted of several
pieces in the language, the compiler, and the runtime:

- *Importer bridging*, importing Objective-C APIs that take and return
  NSString, NSArray, NSDictionary and NSSet so that they take and return
  Swift's analogous value types instead.
- Originally, the language allowed *implicit conversions* in both directions
  between Swift value types and their analogous classes. We've been working on
  phasing the implicit conversions out--we removed the object-to-value implicit
  conversion in Swift 1.2, and propose to remove the other direction in
  [SE-0072](0072-eliminate-implicit-bridging-conversions.md)
  --but the conversions can still be performed by an *explicit coercion*
  `string as NSString`. These required-explicit `as` coercions don't otherwise
  exist in the language, since `as` generally is used to force coercions that
  can also happen implicitly, and value-preserving conversions are more
  idiomatically performed by constructors in the standard library.
- The runtime supports *dynamic bridging casts*. If you have a value that's
  dynamically of a Swift value type, and try to `as?`, `as!`, or `is`-cast it
  to its bridged Cocoa class type, the cast will succeed, and the runtime will
  apply the bridging conversion:

    ```swift
    // An Any that dynamically contains a value "foo": String
    let x: Any = "foo"
    // Cast succeeds and produces the bridged "foo": NSString
    let y = x as! NSString
    ```

Since Swift first came out, Cocoa has done a great job of "Swiftification",
aided by new Objective-C features like nullability and lightweight generics
that have greatly improved the up-front quality of importer-bridged APIs.
This has let us deemphasize and gradually remove the special case implicit
conversions from the language. I think it's time to consider extricating them
from the dynamic type system as well, making it so that `as?`, `as!`, and `is`
casts only concern themselves with typechecks, and transitioning to
using standard initializers and methods for performing bridging conversions.
The dynamic cast behavior has been a source of surprise for many users, and
unfairly privileges bridged value types and classes with nonstandard behavior.

## Proposed solution

I propose the following:

- Dynamic casts `as?`, `as!` and `is` should no longer perform bridging
  conversions between value types and Cocoa classes.
- Coercion syntax `as` should no longer be used to explicitly force certain
  bridging conversions.
- To replace this functionality, we should add initializers to bridged
  value types and classes that perform the value-preserving bridging operations.

## Background

### The Rules of `as[?]`

Our original goal implementing this behavior into the dynamic casting machinery
was to preserve some transitivity identities between implicit conversions and
casts that users could reason about, including:

- `x as! T as! U` === `x as! U`, if `x as! T` succeeds. Casting to a type `U`
  should succeed and give the same result for any derived cast result.
- `x as! T as U` === `x as! U`. If `T` is coercible to `U`, then you should get
  the same result by casting to `T` and coercing to `U` as by casting to
  `U` directly.
- `x as T as! U` === `x as! U`. Likewise, coercing shouldn't affect the result
  of any ensuing dynamic casts.
- `x as T as U` === `x as U`.

The interaction of these identities with the bridging conversions, as well as
with other type system features like implicit nonoptional-to-Optional
conversion, occasionally requires surprising behavior, for instance [the
behavior of `nil` Optional values](https://github.com/apple/swift/pull/1949).
These rules also inform the otherwise-inconsistent use of `as` to perform
explicit bridging conversions, when `as` normally only forces implicit
conversions. By simplifying the scope of dynamic casts, it becomes easier to
preserve these rules without bugs and unfortunate edge cases.

### The Abilities of `as?` Today

In discussing how to change the behavior of dynamic casts, it's worth
enumerating all the things dynamic casts are currently able to do:

1. Check that an object is an instance of a specific class.

    ```swift
    class Base {}; class Derived: Base {}

    func isKindOfDerived(object: Base) -> Bool {
      return object is Derived
    }

    isKindOfDerived(object: Derived()) // true
    isKindOfDerived(object: Base()) // false
    ```

2. Check that an existential contains an instance of a type.

    ```swift
    protocol P {}
    extension Int: P {}
    extension Double: P {}

    func isKindOfInt(value: P) -> Bool {
      return value is Int
    }
    isKindOfInt(value: 0) // true
    isKindOfInt(value: 0.0) // false
    ```

3. Check that a generic value is also an instance of a different type.

    ```swift
    func is<T, U>(value: T, kindOf: U.Type) -> Bool {
      return value is U
    }

    is(value: Derived(), kindOf: Derived.self) // true
    is(value: Derived(), kindOf: Base.self) // true
    is(value: Base(), kindOf: Derived.self) // false
    is(value: 0, kindOf: Int.self) // true
    ```
    
4. Check whether the type of a value conforms to a protocol, and wrap it in
   an existential if so:

    ```swift
    protocol Fooable { func foo() }

    func fooIfYouCanFoo<T>(value: T) {
      if let fooable = value as? Fooable {
        fooable.foo()
      }
    }

    extension Int: Fooable { func foo() { print("foo!") } }

    fooIfYouCanFoo(value: 1) // Prints "foo!"
    fooIfYouCanFoo(value: "bar") // No-op
    ```

5. Check whether a value is `_ObjectiveCBridgeable` to a class, or conversely,
   that an object is `_ObjectiveCBridgeable` to a value type, and perform the
   bridging conversion if so:

    ```swift
    func getAsString<T>(value: T) -> String? {
      return value as? String
    }
    func getAsNSString<T>(value: T) -> NSString? {
      return value as? NSString
    }

    getAsString(value: "string") // produces "string": String
    getAsNSString(value: "string") // produces "string": NSString

    let ns = NSString("nsstring")
    getAsString(value: ns) // produces "nsstring": String
    getAsNSString(value: ns) // produces "nsstring": NSString
    ```

6. Check whether a value conforms to `ErrorProtocol`, and bridge it to
   `NSError` if so:

    ```swift
    enum CommandmentError { case Killed, Stole, GravenImage, CovetedOx }

    func getAsNSError<T>(value: T) -> NSError? {
      return value as? NSError
    }

    getAsNSError(CommandmentError.GravenImage) // produces bridged NSError
    ```
   
    This is what enables the use of `catch let x as NSError` pattern matching
    to catch Swift errors as `NSError` objects today.

7. Check whether an `NSError` object has a domain and code matching a type
   conforming to `_ObjectiveCBridgeableErrorProtocol`, and extracting the
   Swift error if so:

    ```swift
    func getAsNSCocoaError(error: NSError) -> NSCocoaError? {
      return error as? NSCocoaError
    }

    // Returns NSCocoaError.fileNoSuchFileError
    getAsNSCocoaError(error: NSError(domain: NSCocoaErrorDomain,
                                     code: NSFileNoSuchFileError,
                                     userInfo: []))
    ```

8. Drill through `Optional`s. If an `Optional` contains `some` value, it is
   extracted, and the cast is attempted on the contained value; the cast fails
   if the source value is `none` and the result type is not optional:
   
    ```swift
    var x: String? = "optional string"
    getAsNSString(value: x) // produces "optional string": NSString
    x = nil
    getAsNSString(value: x) // fails
    ```
   
    If the result type is also `Optional`, a successful cast is wrapped as
    `some` value of the result Optional type. `nil` source values succeed
    and become `nil` values of the result Optional type:

    ```swift
    func getAsOptionalNSString<T>(value: T) -> NSString?? {
      return value as? NSString?
    }
    
    var x: String? = "optional string"
    getAsOptionalNSString(value: x) // produces "optional string": NSString?
    x = nil
    getAsOptionalNSString(value: x) // produces nil: NSString?
    ```

9. Perform covariant container element checks and conversions for `Array`,
   `Dictionary`, and `Set`.

There are roughly three categories of functionality intertwined here.
(1) through (4) are straightforward dynamic type checks. ([4] is arguably a bit
different from [1] through [3] in that protocol conformances are extrinsic
to a type, whereas [1] through [3] check only the intrinsic type of the
participating value.) (5) through (7) involve Cocoa bridging conversions.
(8) and (9) reflect additional implicit conversions supported by the language
at compile time into the runtime type system.

## Detailed Design

### Changes to dynamic cast behavior

Within the scope of this proposal, I'd like to propose removing behaviors
(5) through (7) from dynamic casting:

- (5) Dynamic casts will no longer check for `_ObjectiveCBridgeable` conformance
  in their source or destination types. `"string" as Any as? NSString` would
  fail.
- (6) Types that conform to `ErrorProtocol` will no longer dynamically cast
  to `NSError`.
- (7) `NSError` instances will no longer dynamically cast to `ErrorProtocol`-
  conforming types.

### Eliminating explicit `as` coercions

With the bridging behavior removed from dynamic casting, we no longer have
the transitivity justification for the special case behavior of `as`
forcing bridging conversions, as in `nsstring as String`. This functionality
should be removed, leaving `as` with only its core behavior of acting as a
type annotation to force implicit conversions.

### Replacement API for bridging conversions

To replace the removed language functionality, we should provide library APIs
that follow the conventions set by the standard library. Bridging conversions
are value-preserving, and the standard library uses unlabeled `init(_:)`
initializers for value-preserving conversions. For nongeneric unconditionally-
bridgeable types, such as `String` and `NSString`, this is straightforward
(assuming we gain the ability to define factory initializers in Swift at
some point):

```swift
extension String {
  init(_ ns: NSString) {
    self = ._unconditionallyBridgeFromObjectiveC(ns)
  }
}

extension NSString {
  // Without a first-class factory init feature, this can be simulated with
  // a protocol extension
  factory init(_ string: String) {
    self = string._bridgeToObjectiveC()
  }
}
```

As an implementation detail, we could add a refinement of
`_ObjectiveCBridgeable` for unconditionally-bridgeable types and implement
these initializer pairs as protocol extensions. Similarly, we can provide
`NSError` with a factory initializer in the Foundation overlay to handle
bridging from `ErrorProtocol`:

```swift
extension NSError {
  factory init(_ error: ErrorProtocol) {
    self = _bridgeErrorProtocolToNSError(error)
  }
}
```

and the inverse bridging of `NSError`s to special `ErrorProtocol` types can
be handled by modifying the internal `_ObjectiveCBridgeableErrorProtocol`
to require an unlabeled failable initializer:

```swift
public protocol _ObjectiveCBridgeableErrorProtocol : ErrorProtocol {
  /// Produce a value of the error type corresponding to the given NSError,
  /// or return nil if it cannot be bridged.
  init?(_ bridgedNSError: NSError)
}
```

For bridged generic containers like `Array`, `Dictionary`, and `Set`,
the bridging conversions have to be failable, since not every element type
is bridgeable, and the Objective-C classes come into Swift as untyped
containers. (That may change if we're able to extend the Objective-C generics
importer support from
[SE-0057](0057-importing-objc-generics.md)
to apply to Cocoa container classes, though bridging support makes that
challenging.)

```swift
extension Array {
  init?(_ ns: NSArray) {
    var result: Array? = nil
    if Array._conditionallyBridgeFromObjectiveC(ns, &result) {
      self = result!
      return
    }
    return nil
  }
}

extension NSArray {
  init?<T>(_ array: Array<T>) {
    if !Array<T>.isBridgedToObjectiveC() {
      return nil
    }
    return array._bridgeToObjectiveC()
  }
}
```

Containers also support special force-bridging behavior, where the elements
of the bridged value container are lazily type-checked and trap on access
if there's a type mismatch. This can still be exposed via a separate labeled
initializer:

```swift
extension Array {
  init(forcedLazyBridging object: NSArray) {
    var result: Array? = nil
    Array._forceBridgeFromObjectiveC(object, &result)
    self = result!
  }
}
```

This seems to me like another improvement over our current behavior, where
`object as! Array<T>` does lazy bridging whereas `object as? Array<T>` does
eager bridging. This has been a common source of surprise, since in most other
cases `x as! T` behaves equivalently to `(x as? T)!`. By changing to
an interface defined within the language in terms of initializers,
`Array<T>(object)!` performs eager bridging as one would normally expect, and
`Array<T>(forcedLazyBridging: object)` explicitly asks for the lazy bridging.

There are common use cases that deserve consideration beyond simple back-and-
forth conversion. In Cocoa code, it's common to work with heterogeneous
containers of objects, which will come into Swift as `[AnyObject]` or
`[NSObject: AnyObject]`. To extract typed data from these containers, it's
useful to convert from `AnyObject` to a bridged value type in one step, like
you can do with `object as? String` today. We can provide a
failable initializer for this purpose:

```swift
extension _ObjectiveCBridgeable {
  init?(bridging object: AnyObject) {
    if let bridgeObject = object as? _ObjectiveCType {
      var result: Self? = nil
      if Self._conditionallyBridgeFromObjectiveC(bridgeObject, &result) {
        self = result!
        return
      }
    }
    return nil
  }
}
```

Dynamic cast bridging of `NSError` is commonly used in the `catch _ as NSError`
formulation, to catch an arbitrary Swift error and handle it as an `NSError`.
This is done frequently because `ErrorProtocol` by itself provides no public
API for presenting errors. The need to explicitly bridge to `NSError` could be 
avoided in most cases by extending `ErrorProtocol` to directly support
`NSError`'s core API in the Foundation overlay:

```swift
extension ErrorProtocol {
  var domain: String { return NSError(self).domain }
  var code: Int { return NSError(self).code }
  var userInfo: [NSObject: AnyObject] { return NSError(self).userInfo }
}
```

## Impact on existing code

Since dynamic behavior is involved, these changes cannot be automatically
migrated with full fidelity. For example, if a value of type `Any` or generic
`T` being cast to `String` or `NSString`, it's impossible for the compiler
to know whether the cast is being made with the intent of inducing the
bridging conversion. However, at least some cases can be recognized
by the compiler and migrated. For example, any cast from a value that's
statically of a value type to a class would now always fail, as would
a cast from an object to a value type, so these cases can be warned about
and fixits to use the new initializers can be offered. We can also recognize
code that uses the `catch <pattern> as NSError` idiom and migrate away the
`as NSError` cast if we make it unnecessary by extending `ErrorProtocol`.

## Alternatives considered

### Removing special-case `Optional` and container handling from dynamic casts

As discussed [above](#theabilitiesofastoday), in addition to dynamic
type checks and bridging conversions, dynamic casting also has special-case
behavior for (8) drilling through `Optional`s and (9) performing covariant
`Array`, `Dictionary`, and `Set` conversions. This dynamic behavior matches
the special implicit conversions supported statically in the language, but
has also been a source of complexity and confusion. We could consider
separating this functionality out of the runtime dynamic casting machinery too,
but we should do so in tandem with discussions of removing or tightening the
corresponding implicit conversion behavior for optionals and covariant
containers as well.

### Replacing dynamic cast syntax with normal functions or methods

If one wanted to get really reductionist, they could ask whether `as?` and
related operations really need special syntax at all; they could in theory
be fully expressed as global functions, or as extension methods on
`Any`/`AnyObject` if we allowed such things.
