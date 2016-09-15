# Allow Swift types to provide custom Objective-C representations

* Proposal: [SE-0058](0058-objectivecbridgeable.md)
* Authors: [Russ Bishop](https://github.com/russbishop), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Deferred**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000095.html)

## Introduction

Provide an `ObjectiveCBridgeable` protocol that allows a Swift type to control how it is represented in Objective-C by converting into and back from an entirely separate `@objc` type. This frees library authors to create truly native Swift APIs while still supporting Objective-C.

Swift-evolution thread: [\[Idea\] ObjectiveCBridgeable](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011032.html)


## Motivation

There is currently no good way to define a Swift-y API that makes use of generics, enums with associated values, structs, protocols with associated types, and other Swift features while still exposing that API to Objective-C.

This is especially prevelent in a mixed codebase. Often an API must be dumbed-down or Swift features eschewed because rewriting the entire codebase is impractical and Objective-C code must be able to call the new Swift code. This results in a situation where new code or refactored code adopts an Objective-C compatible API which is compromised, less type safe, and isn't as nice to work with as a truly native Swift API.

The cascading effect is even worse because when the last vestiges of Objective-C have been swept away, you're left with a mountain of Swift code that essentially looks like a direct port of Objective-C code and doesn't take advantage of any of Swift's modern features. 

For framework and library authors it presents an awful choice:

1. Write mountains of glue code to convert between Swift and Objective-C versions of your types.
2. Write your shiny new framework in Swift, but in an Objective-C style using only `@objc` types.
3. Write your shiny new framework in Objective-C.

Choice #1 is not practical in the real world with ship dates, resulting in most teams choosing #2 or #3. 



## Proposed Solution

Today you can adopt the private protocol `_ObjectiveCBridgeable` and when a bridged collection (like `Array` &lt;--&gt; `NSArray`) is passed between Swift and Objective-C, Swift will automatically call the appropriate functions to  control the way the type bridges. This allows a Swift type to have a completely different representation in Objective-C.

The solution proposed is to expose a new protocol `ObjectiveCBridgeable` and have the compiler generate the appropriate Objective-C bridging thunks for any function or property of an `@objc` type, not just for values inside collections. 


### ObjectiveCBridgeable Protocol

```swift
/// A type adopting `ObjectiveCBridgeable` will be exposed
/// to Objective-C as the type `ObjectiveCType` (or one of its
/// subclasses).
public protocol ObjectiveCBridgeable {
    /// The `@objc` class (or base class) type
    /// representing `Self` in Objective-C.
    associatedtype ObjectiveCType : AnyObject

    /// Returns `true` iff instances of `Self` can be converted to
    /// Objective-C.  Even if this property returns `true`, a given
    /// instance of `Self.ObjectiveCType` may, or may not, convert
    /// successfully to `Self`.
    ///
    /// A default implementation returns `true`. If a Swift type is
    /// generic and should only be bridged for some type arguments,
    /// provide your own implementation that returns `false` for
    /// non-bridged type parameters.
    ///
    ///     struct Foo<T>: ObjectiveCBridgeable {
    ///         static var isBridgedToObjectiveC: Bool {
    ///             return !(T is NonBridgedType)
    ///         }
    ///     }
    ///
    static var isBridgedToObjectiveC: Bool { get }

    /// Convert `self` to an instance of
    /// `ObjectiveCType` (or one of its subclasses)
    @warn_unused_result
    func bridgeToObjectiveC() -> ObjectiveCType

    /// Attempt to construct a value of the `Self` type from
    /// an Objective-C object of the bridged class type
    ///
    /// This bridging initializer is used for bridging when
    /// interoperating with Objective-C code, either in the body of an
    /// Objective-C thunk or when calling Objective-C code.
    ///
    /// - note: This initializer should eagerly perform the
    /// conversion without defering any work for later,
    /// returning `nil` if the conversion fails.
    init?(bridgedFromObjectiveC: ObjectiveCType)

    /// Bridge from an Objective-C object of the bridged class type to a
    /// value of the Self type.
    ///
    /// This bridging initializer is used for unconditional bridging when
    /// interoperating with Objective-C code, either in the body of an
    /// Objective-C thunk or when calling Objective-C code, and may
    /// defer complete checking until later. For example, when bridging
    /// from `NSArray` to `Array<Element>`, we can defer the checking
    /// for the individual elements of the array.
    ///
    /// - parameter unconditionallyBridgedFromObjectiveC:
    /// The Objective-C object from which we are bridging.
    /// This optional value will only be `nil` in cases where
    /// an Objective-C method has returned a `nil` despite being marked
    /// as `_Nonnull`/`nonnull`. In most such cases, bridging will
    /// generally force the value immediately. However, this gives
    /// bridging the flexibility to substitute a default value to cope
    /// with historical decisions, e.g., an existing Objective-C method
    /// that returns `nil` for an "empty result" rather than (say) an
    /// empty array. In such cases, when `nil` does occur, the
    /// implementation of `Swift.Array`'s conformance to
    /// `ObjectiveCBridgeable` will produce an empty array rather than
    /// dynamically failing.
    ///
    /// A default implementation calls `init?(bridgedFromObjectiveC:)`
    /// and aborts if the conversion fails.
    init(unconditionallyBridgedFromObjectiveC: ObjectiveCType?)
}

public extension ObjectiveCBridgeable {
    static var isBridgedToObjectiveC: Bool { return true }
    init(unconditionallyBridgedFromObjectiveC source: ObjectiveCType?) {
        self.init(bridgedFromObjectiveC: source!)!
    }
}
```

## Detailed Design

1. Expose the protocol `ObjectiveCBridgeable`. This protocol will replace the old private protocol `_ObjectiveCBridgeable`.
2. When generating an Objective-C interface for an `@objc` class type:
    1. When a function contains parameters or return types that are `@nonobjc` but those types adopt `ObjectiveCBridgeable`:
        1. Create `@objc` thunks that call the Swift functions but substitute the corresponding `ObjectiveCType`.
        2. The thunks will call the appropriate protocol functions to perform the conversion.
    2. If any `@nonobjc` types do not adopt `ObjectiveCBridgeable`, the function itself is not exposed to Objective-C (current behavior).
3. Swift Standard library types like `String`, `Array`, `Dictionary`, and `Set` will adopt the new protocol, thus demoting their bridging behavior from *magic* to regular behavior.
4. A clang attribute will be provided to indicate which Swift type bridges to an Objective-C class. A convenience `SWIFT_BRIDGED()` macro will be provided.
    1. If the `ObjectiveCType` is defined in Objective-C, the programmer should annotate the `@interface` declaration with `SWIFT_BRIDGED("SwiftTypeName")`.
    2. If the `ObjectiveCType` is defined in Swift, it must be an `@objc` class type. The compiler will annotate the generated bridging header with `SWIFT_BRIDGED()` automatically.
5. The Swift type and `ObjectiveCType` must be defined in the same module. If the `ObjectiveCType` is defined in Objective-C then it must come from the same-named Objective-C module.


### Ambiguity and Casting

The compiler generates automatic thunks only when there is no ambiguity, while explicit casts and bridged collection types always use the protocol implementation.


1. For `ObjectiveCType`s defined in Objective-C:
    1. Omitting the `SWIFT_BRIDGED()` attribute causes Objective-C APIs using the `ObjectiveCType` to import without automatic bridging.
    2. There are no implicit conversions from the Swift type to its Objective-C bridged type; if an Objective-C parameter imports as `SomeObjectiveCType`, attempting to pass `Foo<T>` is an error. However a user *may* explicitly cast to an `ObjectiveCBridgeable` Swift type (eg: `funcTakingObjCObject(Foo<T> as! SomeObjectiveCType`).
    3. Bridged collection types will still observe the protocol conformance if cast to a Swift type (eg: `NSArray as? [Int]` will call the `ObjectiveCBridgeable` implementation on `Array`, which itself will call the implementation on `Int` for the elements)
2. A Swift type may bridge to an Objective-C base class then provide different subclass instances at runtime, but no other Swift type may bridge to that base class or any of its subclasses.
    1. The compiler should emit a diagnostic when it detects two Swift types attempting to bridge to the same `ObjectiveCType`.
3. An exception to these rules exists for trivially convertable built-in types like `NSInteger` &lt;--&gt; `Int` when specified outside of a bridged collection type. In those cases the compiler will continue the existing behavior, bypassing the `ObjectiveCBridgeable` protocol. The effect is that types like `Int` will not bridge to `NSNumber` unless contained inside a collection type (see `BuiltInBridgeable below`).

### Resiliance

Adding or removing conformance to `ObjectiveCBridgeable`, or changing the `ObjectiveCType` is a fragile (breaking) change.


### Example

Here is an enum with associated values that adopts the protocol and bridges by converting itself into an object representation.

*Note: The ways you can represent the type in Objective-C are endless; I’d prefer not to bikeshed that particular bit :) The Objective-C type is merely one representation you could choose to allow getting and setting the enum's associated values*

```swift
enum Fizzer {
    case Case1(String)
    case Case2(Int, Int)
}

extension Fizzer: ObjectiveCBridgeable {
    func bridgeToObjectiveC() -> ObjCFizzer {
        let bridge = ObjCFizzer()
        switch self {
        case let .Case1(x):
            bridge._case1 = x
        case let .Case2(x, y):
            bridge._case2 = (x, y)
        }
        return bridge
    }

    init?(bridgedFromObjectiveC source: ObjCFizzer) {
        if let stringValue = source._case1 {
            self = Fizzer.Case1(stringValue)
        } else if let tupleValue = source._case2 {
            self = Fizzer.Case2(tupleValue.0, tupleValue.1)
        } else {
            return nil
        }
    }
}

class ObjCFizzer: NSObject {
    private var _case1: String?
    private var _case2: (Int, Int)?

    var fizzyString: String? { return _case1 }
    var fizzyX: Int? { return _case2?.0 }
    var fizzyY: Int? { return _case2?.1 }

    func setTupleCase(x: Int, y: Int) {
        _case1 = nil
        _case2 = (x, y)
    }

    func setStringCase(string: String) {
        _case1 = string
        _case2 = nil
    }
}
```


## Impact on existing code

None. There are no breaking changes and adoption is opt-in.


## Alternatives considered

The main alternative, as stated above, is not to adopt Swift features that cannot be expressed in Objective-C. 

The less feasible alternative is to provide bridging manually by segmenting methods and properties into `@objc` and `@nonobjc` variants, then manually converting at all the touch points. In practice I don't expect this to be very common due to the painful overhead it imposes. Developers are much more likely to avoid using Swift features (even subconsciously).

### Ambiguity

The idea of allowing multiple Swift types to bridge to the same Objective-C type was discussed. It should technically be possible since the same-module rule wouldn't allow the shape of an imported API to vary based on which modules you imported. The compiler *could* skip generating the thunks in this case and the user would need to provide `@objc` equivalent members that performed casting to resolve the ambiguity.

However there doesn't appear to be a convincing case to support such complex behavior so in the interests of simplicity this proposal keeps this kind of ambiguity an error. It can always be relaxed in the future if desired.


### BuiltInBridgeable

On the mailing list the idea of a protocol to supersede `ObjectiveCBridgeable` for built-in types like `Int` was brought up but not considered essential for this proposal. (The protocol would be decorative only, not having any functions or properties).

These types are special because they bridge differently inside collections vs outside. The compiler already has *magic* knowledge of these types and I don't anticipate the list of types will ever get any longer. The only benefit of a `BuiltInBridgeable` protocol would be to explicitly declare which types have this "magic".

This can always be implemented in the future if it is desired.


## Future Directions

### Conditional Conformance

It is intended that when and if Swift 3 adopts conditional protocol conformance that the standard library types such as `Array` and `Dictionary` will declare conditional conformance to `ObjectiveCBridgeable` if their element types are `ObjectiveCBridgeable` (with explicitly declared conformance for built-ins like `Int`).

## Rationale

On April 12, 2016, the core team decided to **defer** this proposal from
Swift 3. We agree that it would be valuable to give library authors the
ability to bridge their own types from Objective-C into Swift using the
same mechanisms as Foundation. However, we lack the confidence and 
implementation experience to commit to `_ObjectiveCBridgeable` in its
current form as public API. In its current form, as its name suggests, the
protocol was designed to accommodate the specific needs of bridging
Objective-C object types to Swift value types. In the future, we may
want to bridge with other platforms, including C++ value types or 
other object systems such as COM, GObject, JVM, or CLR. It isn't clear at
this point whether these would be served by a generalization of the existing
mechanism, or by bespoke bridging protocols tailored to each case. This
is a valuable area to explore, but we feel that it is too early at this
point to accept our current design as public API.

