# Allow Swift types to provide custom Objective-C representations

* Proposal: SE-NNNN
* Author(s): [Russ Bishop](https://github.com/russbishop)
* Status: **Awaiting review**
* Review manager: TBD


# Introduction

Provide an `ObjectiveCBridgeable` protocol that allows a Swift type to control how it is represented in Objective-C by converting into and back from an entirely separate `@objc` type. This frees library authors to create truly native Swift APIs while still supporting Objective-C.

Swift-evolution thread: [[Idea] ObjectiveCBridgeable](http://thread.gmane.org/gmane.comp.lang.swift.evolution/7852/)


# Motivation

There is currently no good way to define a Swift-y API that makes use of generics, enums with associated values, structs, protocols with associated types, and other Swift features while still exposing that API to Objective-C.

This is especially prevelant in a mixed codebase. Often an API must be dumbed-down or Swift features eschewed because rewriting the entire codebase is impractical and Objective-C code must be able to call the new Swift code. This results in a situation where new code or refactored code adopts an Objective-C compatible API which is compromised, less type safe, and isn't as nice to work with as a truly native Swift API. 

The cascading effect is even worse because when the last vestiges of Objective-C have been swept away, you're left with a mountain of Swift code that essentially looks like a direct port of Objective-C code and doesn't take advantage of any of Swift's modern features. 

For framework and library authors it presents an awful choice:

1. Write mountains of glue code to convert between Swift and Objective-C versions of your types.
2. Write your shiny new framework in Swift, but in an Objective-C style using only `@objc` types.
3. Write your shiny new framework in Objective-C.

Choice #1 is not practical in the real world with ship dates, resulting in most teams choosing #2 or #3. 


# Proposed Solution

Today you can adopt the private protocol `_ObjectiveCBridgeable` and when a bridged collection (like `Array` &lt;--&gt; `NSArray`) is passed between Swift and Objective-C, Swift will automatically call the appropriate functions to  control the way the type bridges. This allows a Swift type to have a completely different representation in Objective-C.

The solution proposed is to expose the existing protocol as a public protocol `ObjectiveCBridgeable` and have the compiler generate the appropriate Objective-C bridging thunks for any member of an `@objc` type, not just for values inside collections.

**Note:** Expressing a more generalized mapping mechanism (eg: `NSInteger` to `Int`) is not currently within the scope of this proposal.Allowing Objective-C code to control its manifestation to a Swift consumer is also outside the scope of this proposal.

## ObjectiveCBridgeable Protocol

```
/// A type adopting `ObjectiveCBridgeable` will be exposed
/// to Objective-C as the type `ObjectiveCType`
public protocol ObjectiveCBridgeable {
    associatedtype ObjectiveCType : AnyObject

    /// Returns `true` iff instances of `Self` can be converted to
    /// Objective-C.  Even if this method returns `true`, a given
    /// instance of `Self._ObjectiveCType` may, or may not, convert
    /// successfully to `Self`
    @warn_unused_result
    static func isBridgedToObjectiveC() -> Bool

    /// Convert `self` to Objective-C.
    @warn_unused_result
    func bridgeToObjectiveC() -> ObjectiveCType

    /// Bridge from an Objective-C object of the bridged class type to a
    /// value of the Self type.
    ///
    /// This bridging operation is used for forced downcasting (e.g.,
    /// via as!), and may defer complete checking until later.
    ///
    /// - parameter result: The location where the result is written. The optional
    ///   will always contain a value.
    static func forceBridgeFromObjectiveC(
        source: ObjectiveCType,
        inout result: Self?
    )

    /// Try to bridge from an Objective-C object of the bridged class
    /// type to a value of the Self type.
    ///
    /// This conditional bridging operation is used for conditional
    /// downcasting (e.g., via as?) and therefore must perform a
    /// complete conversion to the value type; it cannot defer checking
    /// to a later time.
    ///
    /// - parameter result: The location where the result is written.
    ///
    /// - Returns: `true` if bridging succeeded, `false` otherwise. This redundant
    ///   information is provided for the convenience of the runtime's `dynamic_cast`
    ///   implementation, so that it need not look into the optional representation
    ///   to determine success.
    static func conditionallyBridgeFromObjectiveC(
        source: ObjectiveCType,
        inout result: Self?
        ) -> Bool
}
```

# Detailed Design

1. Expose the protocol `ObjectiveCBridgeable` (essentially a renamed `_ObjectiveCBridgeable`)
2. When generating an Objective-C interface for an `@objc` type:
  1. When a function contains parameters or return types that are `@nonobjc` but those types adopt `ObjectiveCBridgeable`:
     1. Create `@objc` thunks that call the Swift functions but substitute the corresponding `ObjectiveCType`.
     2. The thunks will call the appropriate protocol functions to perform the conversion.
  2. If any `@nonobjc` types do not adopt `ObjectiveCBridgeable`, the function itself is not exposed to Objective-C (current behavior).
3. Collection bridging will be updated to use the new protocol names but otherwise works just as it does today.
4. The `ObjectiveCType` must be defined in Swift. If a `-swift.h` header is generated, it will include a `SWIFT_BRIDGED()` macro where the parameter indicates the Swift type with which the `ObjectiveCType` bridges. The macro will be applied to the `ObjectiveCType` and any subclasses.
5. It is an error for bridging to be ambiguous.
  1. A Swift type may bridge to an Objective-C base class, then provide different subclass instances at runtime but no other Swift type may bridge to that base class or any of its subclasses.
  2. The compiler may emit a diagnostic when it detects two Swift types attempting to bridge to the same `ObjectiveCType`. 
6. The Swift type and `ObjectiveCType` must be defined in the same module


## Example

Here is an enum with associated values that adopts the protocol and bridges by converting itself into an object representation.

*Note: The ways you can represent the type in Objective-C are endless; I’d prefer not to bikeshed that particular bit :) The Objective-C type is merely one representation you could choose to allow getting and setting the enum's associated values*

```
enum Fizzer {
    case Case1(String)
    case Case2(Int, Int)
}

extension Fizzer: ObjectiveCBridgeable {
    typealias ObjectiveCType = ObjCFizzer
    static func isBridgedToObjectiveC() -> Bool {
        return true
    }
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
    static func conditionallyBridgeFromObjectiveC(source: ObjCFizzer, inout result: Fizzer?) -> Bool {
        if let stringValue = source._case1 {
            result = Fizzer.Case1(stringValue)
        } else if let tupleValue = source._case2 {
            result = Fizzer.Case2(tupleValue.0, tupleValue.1)
        } else {
            return false
        }
        return true
    }
    static func forceBridgeFromObjectiveC(source: ObjCFizzer, inout result: Fizzer?) {
        precondition(
            conditionallyBridgeFromObjectiveC(source, result: &result),
            "Failed to cast from Objective-C type"
        )
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

## Generic Example

This example demonstrates how an API author could expose a Generic class to Objective-C. Making the constructor of `ObjCBar` available means Objective-C consumers can construct new instances, which are handled by deferring creation of an actual `Bar<T>` instance until bridging occurs. 

*As mentioned previously, there are a million ways to bikeshed the bridging. It should go without saying that allowing Objective-C code to construct new instances provides less type safety owing to the nature of Objective-C.*

```
struct Bar<T> {
    var storage: T
}

extension Bar: ObjectiveCBridgeable {
    typealias ObjectiveCType = ObjCBar
    static func isBridgedToObjectiveC() -> Bool {
        return true
    }
    func bridgeToObjectiveC() -> ObjCBar {
        return ObjCBar(storage: self)
    }
    static func conditionallyBridgeFromObjectiveC(source: ObjCBar, inout result: Bar?) -> Bool {
        if let instance = source._storage as? Bar<T> {
            result = instance
            return true
        } else if let value = source._storage as? T {
            result = Bar<T>(storage: value)
            return true
        }
        return false
    }
    static func forceBridgeFromObjectiveC(source: ObjCBar, inout result: Bar?) {
        precondition(
            conditionallyBridgeFromObjectiveC(source, result: &result),
            "Failed to cast from Objective-C type"
        )
    }
}

class ObjCBar: NSObject {
    private var _storage: Any
    init(storage: Any) {
        _storage = storage
    }
    init(object: AnyObject) {
        _storage = object
    }
}

let objCValue = ObjCBar(object: NSString(string: "my string"))
var dest: Bar<String>? = nil
let success = Bar<String>.conditionallyBridgeFromObjectiveC(objCValue, result: &dest)

// success = true
// dest = Bar<string> instance
```

# Impact on existing code

Almost None. There are no breaking changes and adoption is opt-in.

If user code is currently adopting the private protocol then some minor renaming would be required but in theory no one should be using a private protocol.


# Alternatives considered

The main alternative, as stated above, is not to adopt Swift features that cannot be expressed in Objective-C. 

The less fesible alternative is to provide bridging manually by segmenting methods and properties into `@objc` and `@nonobjc` variants, then manually converting at all the touch points. In practice I don't expect this to be very common due to the painful overhead it imposes. Developers are much more likely to avoid using Swift features (even subconsciously).

