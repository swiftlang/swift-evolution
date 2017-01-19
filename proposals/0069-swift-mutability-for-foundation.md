# Mutability and Foundation Value Types

* Proposal: [SE-0069](0069-swift-mutability-for-foundation.md)
* Author: [Tony Parker](https://github.com/parkera)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000132.html)

## Introduction

One of the core principles of Swift is "mutability when you need it." This is espoused by Apple's official documentation about Swift:

* [Value and Reference Types - Swift Developer Blog](https://developer.apple.com/swift/blog/?id=10)
* [Building Better Apps with Value Types in Swift - WWDC 2015 (Doug Gregor)](https://developer.apple.com/videos/play/wwdc2015/414/)
* [Swift Programming Language - Classes and Structures](https://developer.apple.com/library/ios/documentation/Swift/Conceptual/Swift_Programming_Language/ClassesAndStructures.html#//apple_ref/doc/uid/TP40014097-CH13-ID82)

[Swift Evolution Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160418/015503.html), [Swift Evolution Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015682.html)

This concept is so important that it is literally the second thing taught in _The Swift Programming Language_, right after `print("Hello, world!")`:

> **Simple Values**
> 
> Use `let` to make a constant and `var` to make a variable. The value of a constant doesn’t need to be known at compile time, but you must assign it a value exactly once.
> 
> __Excerpt From: Apple Inc. “[The Swift Programming Language (Swift 3.0.1).](https://itun.es/us/jEUH0.l)__” 

When certain Foundation types are imported into Swift, they do not fully take advantage of the features that Swift has to offer developers for controlling mutability of their objects. 

This proposal describes a straightforward concept for providing this capability. It describes a set of new Foundation value types which wrap their corresponding reference types. This is a technique used by the standard library. This allows us to:

1. Improve the developer experience, 
2. Increase performance for small types like `Date`
3. Preserve the ability for developers to customize the behavior of most types.

This proposal describes the fundamental ideas and provides general justification.

## Motivation

Foundation itself already uses many value types in Objective-C and Swift:

* Primitive C types (`double`, `long`, `int64_t`, and more)
* Architecture-hiding integer types (`NSUInteger`, `NSInteger`)
* Enumerations (276 in Foundation)
* Option sets (51 in Foundation)
* C structure types (18 in Foundation, including `Point`, `Rect`, `EdgeInsets`, `Decimal`)

In C, developers can control the mutability of these value types by using the `const` keyword:

```c
const NSPoint p = {1, 2};
p.x = 3; // Error: error: cannot assign to variable 'p' with const-qualified type 'const NSPoint'
```

In Swift, developers control the mutability of these value types by using `let` instead of `var`:

```swift
let p = NSPoint(x: 1, y: 2)
p.x = 3 // Error: cannot assign to property: 'p' is a 'let' constant
```

However, struct types in Swift have far more functionality available to them than their primitive C ancestors:

* Methods
* Initializers
* Access control (private, public, internal) on both methods and ivars
* Conformance to protocols, including default implementations from those protocols
* Generics support
* Ability to modify without sacrificing binary compatibility

The Swift standard library takes full advantage of these new capabilities for `String`, `Array`, `Dictionary`, `Set`, and others. In fact, we go as far as to automatically bridge these Foundation types to the standard library struct type when API using them is imported into Swift.

#### Fixing a Mutability Impedance Mismatch

The public API of the Swift standard library itself is composed of almost entirely value types (109 `struct`, 6 `class`, as of Swift 2.2).

The pervasive presence of struct types in the standard library, plus the aforementioned automatic bridging of all Cocoa SDK API when imported into Swift, leads to the feeling of an API impedance mismatch for key unbridged Foundation reference types.

This is because in our Objective-C API, we sometimes provide mutability via methods that return a new version of an immutable receiver:

```objc
// NSDate
- (instancetype)dateByAddingTimeInterval:(NSTimeInterval)ti;

// NSURL
- (nullable NSURL *)URLByAppendingPathExtension:(NSString *)pathExtension;
```

And sometimes via mutable properties:

```objc
@interface NSDateComponents : NSObject <NSCopying, NSSecureCoding>

@property (nullable, copy) NSCalendar *calendar;
@property (nullable, copy) NSTimeZone *timeZone;
@property NSInteger era;
@property NSInteger year;
// etc.
@end
```

However, we do not use the C `const` keyword for controlling mutable behavior on Objective-C classes.

Focusing on the `NSDate` example, let's translate the existing design pattern directly into Swift:

```swift
let myDate = Date()
let myLaterDate = myDate.dateByAddingTimeInterval(60)
```

Unfortunately, this feels awkward for two reasons:

1. The `var` or `let` keywords mean almost nothing. The code above behaves exactly the same if it uses `var` instead of `let`. This is a major language feature we are dropping on the floor.
2. The only way to mutate `Date` is to create a new one. This does not match with the idea of "mutability when you need it."

The following code is a more natural match for the way Swift developers would expect this to work:

```swift
var myDate = Date()
myDate.addTimeInterval(60) // OK

let myOtherDate = Date()
myOtherDate.addTimeInterval(60) // Error, as expected
```

It is important to remember that the `Date` API author still controls the methods available on the type, and does not have to provide mutability for every property (as they would in a C struct). For types where we want to provide limited mutability, we can make all properties `get` only and add `mutating` methods to tightly control state and maintain internal consistency. For example, in the case of `Date` the `NSTimeInterval` ivar is still private to the implementation while we provide a `mutating func` to add a time interval.

#### Predictable Composition

Swift provides automatic and natural support for copying value types just by using assignment. However, when a value type contains a reference type, the developer must take special care to ensure that the reference type is copied correctly. For some Foundation types, this means calling `copy()`. If this is not done correctly, then the failure will be found at runtime.

As an example, let's borrow the Barcode example from the official Swift documentation.

```swift
enum Barcode {
    case UPCA(Int, Int, Int, Int)
    case QRCode(String)
    case SpecialCode(IncrementingCode)
}
```

`SpecialCode` is a new kind of mutable barcode that contains an incrementing counter. Let's say that this counter is backed by mutable data.

```swift
// Simplified for clarity
struct IncrementingCode {
    private var data : NSMutableData
    init() { /* Store a value of 0 in our Data */ }
    func increment() {
       // Retrieve the value, increment, and set it back
    }
}
```

This code has an error that is not obvious at first. To see what it is, let's look at some example code:

```swift
var aCode = IncrementingCode()
aCode.increment() // value == 1

// Compose this incrementing code (appears to be a value type) into another value type (an enum)
let barcode = Barcode.SpecialCode(aCode) // BarCode.SpecialCode, value 1
    
aCode.increment()
// barcode is now a BarCode.SpecialCode with value 2 -- but barcode was "let" and should have been immutable.
```

The error is that the `IncrementingCode` type should have implemented copy-on write behavior when containing a reference type. Without that, "copies" of the value type are actually sharing all underlying data through the `NSMutableData` reference.

Today, developers using basic mutable Foundation types like `MutableData` must fix this themselves by re-implementing the same box/unbox logic each time they use the reference type.

If `Data` were instead a value type, then the `Data` struct itself handles the copying and developers do not have to manually box it.

#### Meaningful Mutable Keywords

The error above would have been obvious with a value type. Plus, that error would be found at compile time instead of runtime. As an example, let's use an Integer instead:

```swift
struct IncrementingCode_Value {
    var val : Int8
    init() { val = 0 }
    func increment() {
        val += 1 // error: 'self' is immutable
    }
}
```

The compiler correctly told us that a mutating operation must be marked as such on the structure type. When `val` was a mutable reference type, the mutation was unknown to the compiler and it could not help.

```swift
mutating func increment() {
    val += 1 // ok
}
```

## Proposed solution

Value types which hold more than a trivial amount of data in Swift are implemented using a copy on write technique. In this case, the value type is effectively a pointer to a shared reference type [^impldetails].

[^impldetails]: This proposal describes a high-level approach to implementation; the details may be more complex. For example, we use a custom subclass of the abstract `NSData` class to enable Swift reference counting even when bridged back to Objective-C. These details are out of the scope of this proposal.

The reference type is traditionally private to the implementation. However, by publishing the reference type, we can allow customization of its behavior via subclassing while simultaneously providing value semantics. In the case of Foundation value types, the published reference type is the current class type.

### New Value Types

The following value types will be added in the Swift overlay. Immutable/mutable pairs (e.g. `Data` and `MutableData`) will become one mutable struct type:

Value Type | Class Type
---------- |--------------------
AffineTransform | NSAffineTransform
CharacterSet | NSCharacterSet, NSMutableCharacterSet
Date | NSDate
DateComponents | NSDateComponents
Data | NSData, NSMutableData
IndexSet | NSIndexSet, NSMutableIndexSet
IndexPath | NSIndexPath
Notification | NSNotification
PersonNameComponents | NSPersonNameComponents
URL | NSURL
URLComponents | NSURLComponents
URLQueryItem | NSURLQueryItem
UUID | NSUUID

These types will have the same functionality as their corresponding `NS` type. In some cases, we will add new functionality if it is directly related to the new type becoming "more Swifty". However, we want API changes to remain focused on the task of converting these to value types and avoid feature creep by considering too much new API. The overlay is deployed back to the first supported release for Swift, so the implementation of these types will use the existing reference type API.

For a small number of these types, we will copy the contents and not hold a reference. This set of types is:

* AffineTransform
* Date
* Notification

The criteria for inclusion in this list is primarily a small memory footprint or a requirement for rapid mutation to avoid reference counting or bridging cost.

Some of the struct types will gain mutating methods. In general, the implementation of the struct type will forward to the underlying reference type, so as to allow a subclass to customize the behavior. If the struct is not initialized with a reference type (using a cast), then it is free to implement as much or as little behavior as it chooses either by delegation to the standard Foundation reference type or via a customized Swift implementation. However, our first version will rely heavily on the existing logic in the Objective-C Foundation framework. This approach is important to reduce the risk.

## Detailed design

The class types will be marked with an attribute that annotates them as Swift struct types [^swiftattr]. The struct types will be implemented in the Swift overlay. This re-implementation may either simply contain the Foundation reference type or reimplement functionality from Objective-C in Swift. Extremely simple types such as `Date` do not contain complicated logic, and writing their implementation in Swift will provide a performance benefit to all Swift users as well as a shared implementation for Swift Open Source.

[^swiftattr]: In the short term, a compiler attribute that can be applied via API notes will be used. This avoids a lock-step dependency between the framework code and overlay.

When these types are returned from Objective-C methods, they will be automatically bridged into the equivalent struct type. When these types are passed into Objective-C methods, they will be automatically bridged into the equivalent class type. The _Bridging_ section below contains more information.

Larger value types (for example, `Data`, `DateComponents`, and `URLComponents`) will be implemented with _copy on write_ behavior. This preserves the performance characteristics of a reference type while maintaining conformance with the Swift mutability model.

In the Swift overlay, each struct type adopts a new protocol that describes its behavior as a bridged type, along with common behavior of `Equatable`, `Hashable`, etc. The name of the protocol is `ReferenceConvertible`:

```swift
/// Decorates types which are backed by a Foundation reference type.
public protocol ReferenceConvertible : _ObjectiveCBridgeable, CustomStringConvertible, CustomDebugStringConvertible, Hashable, Equatable {
    associatedtype ReferenceType : NSObject
}
```

#### Type Conversion

Each reference type may be cast to its corresponding struct type. This may be used to wrap a custom subclass of the reference type. For example, in `Data`:

```swift
class MyData : NSMutableData { }

func myData() -> Data {
    return MyData() as Data
}
```

It is also possible to get the reference type from the struct type (`myData as? NSData`) [^mutref].

[^mutref]: In practice, we will use a custom subclass of the reference type where possible. This custom `NSObject` subclass uses the same Swift reference counting mechanism as a Swift class, which should maintain the correct behavior for uniqueness-checking.


#### Custom Behavior

The most obvious drawback to using a struct is that the type can no longer be subclassed. At first glance, this would seem to prevent the customization of behavior of these types. However, by publicizing the reference type and providing a mechanism to wrap it (`mySubclassInstance as ValueType`), we enable subclasses to provide customized behavior.

As a case study, we will look at the Foundation `Data` type.

##### Developer Experience / API

The following is a simplified example of how the Foundation-provided `struct Data` would be used by developers. It is the same as today, except that we can take advantage of Swift's built-in support for mutability via `let` and `var`:

```swift
// We have already setup two buffers with some data
let d = Data(bytes: buffer1, length: buffer1Size)
print("\(d)") 
// <68656c6c 6f00>

// Note: d2 does not copy the data here
var d2 = d 

// ... it copies it here, on mutation, automatically when needed
d2.appendBytes(buffer2, length: buffer2Size)

print("\(d) \(d2)") 
// <68656c6c 6f00> <68656c6c 6f002077 6f726c64 00>
```

##### Implementation Details

The methods and properties we want `Data` to have are defined on the structure itself. The reference type has similar (but not exactly the same) API [^apidiffs]. `Data` can adopt Swift standard library protocols like `MutableCollectionType`. 

[^apidiffs]: We will remove deprecated API from the value type. We will also remove API that is expressed differently via adoption of a Swift protocol.

The implementation calls through to the stored reference type. If we add API to `NSData` in the future, then we will also add it to `Data`.

Here is an over-simplified look at the `Data` structure [^moreimpldetails]:

```swift
public struct Data : Equatable, Hashable, Coding, MutableCollectionType {
    private var _box : _DataBox // Holds an NSData pointer
    
    public var count : Int {
        let reference = ... // Get reference out of the box
        return reference.length
    }
    
    // Etc.
}
```

[^moreimpldetails]: Exact implementation is out of scope for this proposal. This example is provided to help clarify the intended behavior, not as a reference for implementation.

Note that this structure is only 1 word in size, the same as a `class Data` pointer would be. The `_DataBox` type is an internal class type which holds a reference to the actual storage of the data. This is the key to both class clusters and copy-on-write behavior. The implementation of the storage is abstracted from the `struct Data` itself, and therefore from users of `struct Data`.

The `struct Data` may be initialized with any `NSData`:

```swift
/// Create Data with a custom backing reference type.
class MyData : NSData { }

let dataReference = MyData()
let dataValue = dataReference as Data
// dataValue copies dataReference 
```

This allows anyone to create their own kind of `Data` without exposing the implementation details or even existence of that new type. Just like in Objective-C, when we store a reference type we must call `copy()`. If the reference type is immutable then this copy will be cheap (calling `retain`).

In the most common case where a developer does not provide a custom reference type, then the backing store is our existing `NSData` and `NSMutableData` implementations. This consolidates logic into one place and provides cheap bridging in many cases (see _Bridging_ for more information).

Over time, `struct Data` may choose to move some of the logic from the Objective-C implementation into Swift to provide bridge-free behavior. This is mostly predicated on our ability to ship Swift framework code. We want to maintain as much capability to add new functionality and fix bugs as possible, without requiring apps to update. This means that most logic should be in the dynamic library instead of the embedded standard library.

#### Customization Example

Here is a simple `Data` that holds bytes initialized to `0x01` instead of `0`, and lazily creates backing storage when required.

It can customize the default superclass implementation in `NSData`. For example, it can provide a more efficient implementation of `getBytes(_:length:)`:

```swift
class AllOnesData : NSMutableData {
    var _pointer : UnsafeMutableBufferPointer<Void>?
    override func getBytes(buffer: UnsafeMutablePointer<Void>, length: Int) {
        if let d = _pointer {
            // Get the real data from the buffer
            memmove(buffer, d.baseAddress, length)
        } else {
            // A more efficient implementation of getBytes in the case where no one has asked for our backing bytes
            memset(buffer, 1, length)
        }
    }
    // ... Other implementations
}
```

To test the abstraction, here is a simple function which treats all `Data` equally:

```swift
func printFirstByte(of data : Data) {
    print("It's \(UnsafePointer<UInt8>(data.bytes).pointee)")
}
```

And here is how a developer would use it:

```swift
// Create a custom Data type and pass it to the same function
let allOnesData = AllOnesData(length: 5) as Data
printFirstByte(of: allOnesData) // It's 1
```

The abstraction of our custom `AllOnesData` class from all API that deals with `Data` demonstrates the key feature of Foundation's class cluster types.

### Performance

It is important to maintain a high bar for performance while making this transition.

> Note: The final design of the resilience feature for Swift will have an impact on these numbers.

#### Memory

Using Swift structures for our smallest types can be as effective as using tagged pointers in Objective-C.

For example, `struct Date` is the same size as an `NSDate` pointer:

```swift
public struct Date {
    // All methods, properties, etc. left out here, but they make no difference to the size of each Date instance
    private var _time : NSTimeInterval
}
```    

```swift
print("Date is \(sizeof(Date)) bytes") // Date is 8 bytes
print("NSDate is \(sizeof(NSDate)) bytes") // NSDate is 8 bytes
```

For larger struct types, implementation is based on a copy-on-write mechanism. This means the structure itself is still just one word. For Foundation reference types which are always immutable, the structure holds the reference directly [^evenmoreimpldetails]:

```swift
public struct URL {
    private var _url : NSURL
    
    // Methods go here
}
```

[^evenmoreimpldetails]: In some cases, we may choose to use some of Swift's unmanaged ref count features to reduce the overhead of calling retain/release.

As long as the struct is not mutated, instances share the same pointer to `_url`. When the struct is mutated, then the ivar is assigned to a new instance:

```swift
mutating public func appendPathComponent(pathComponent: String) {
    _url = _url.URLByAppendingPathComponent(pathComponent)
}
```

For types which support mutation (e.g. `Data`), a _box_ is used to hold a pointer to the reference. A Swift standard library function is used to check reference counts, allowing us to skip a copy when it is not necessary:

```swift
// Simplified; assume _box holds a NSMutableData
public mutating func appendBytes(bytes: UnsafePointer<UInt8>, count: Int) {
    if !isUniquelyReferencedNonObjC(&_box) {
        // Make a mutable copy first with original bytes and length
        let copy = _box.reference.mutableCopy() as! NSMutableData
        copy.appendBytes(bytes, length: count)
        _box = _DataBox(copy)
    } else {
        _box.reference.appendBytes(bytes, length: count)
    }
}
```

This provides about the same memory usage as a class in Objective-C, because these structures are a single pointer. However, there is an additional pointer dereference required to get the reference type pointer.

#### CPU

When the Swift compiler has knowledge about the layout of the structure, it can sometimes make optimizations that are otherwise unavailable.

There are two cases we should consider here:

1. Extremely small value types like `Date` (1 pointer size).
2. Larger value types like `URL`. These are actually also 1 pointer size, because they would be implemented with copy-on-write, and therefore share storage unless mutated. This is the same approach as we use in Objective-C and therefore the performance characteristics are approximately equal.

##### Access to Member Data

In microbenchmarks designed to test access time for `Date.timeIntervalSinceReferenceDate`, the Swift struct consistently performed about 15% faster. Although the `NSDate` was tagged, the overhead of calling through `objc_msgSend` was enough to make a difference versus more direct access.

##### Mutation

In microbenchmarks designed to test mutation for a new `Date.addTimeInterval` versus creating new `NSDate` objects with `dateByAddingTimeInterval`, the mutation approach was consistently about 40 times faster. The Objective-C code becomes slow when falling off the tagged pointer path which results in significant overhead from calling into `malloc` and `free`.

##### Passing to Function

In microbenchmarks designed to test performance of passing the struct to a function versus passing the `NSDate` reference to a function, the Swift struct consistently performed about twice as fast. Part of the reason for the additional overhead is that the Swift compiler knows it can omit calls to `retain` and `release` when working with a Swift structure.

### Bridging

Swift has an existing mechanism to support bridging of Swift struct types to Objective-C reference types. It is used for `NSNumber`, `NSString`, `NSArray`, and more. Although it has some performance limitations (especially around eager copying of collection types), these new struct types will use the same functionality for two reasons:

1. We do not have block important improvements to our API on the invention of a new bridging system.
2. If and when the existing bridging system is improved, we will also be able to take advantage of those improvements.

Bridged struct types adopt a compiler-defined protocol called `_ObjectiveCBridgeable`. This protocol defines methods that convert Swift to Objective-C and vice-versa [^objcbridge].

[^objcbridge]: See also [SE-0058](0058-objectivecbridgeable.md). Although the public version of the feature has been deferred from Swift 3, we will still use the internal mechanism for now.

#### From Objective-C to Swift

When a bridged object is returned from an Objective-C method to Swift, the compiler automatically inserts a call to a function in the protocol that performs whatever work is necessary to return the correct result.

For a simple struct type like `Date`, we simply construct the right structure by getting the value out of the class:

```swift
return Date(timeIntervalSinceReferenceDate: input.timeIntervalSinceReferenceDate)
```

For the more complex types, both bridging and casting (`myReference as Struct`) use a private initializers for the value types that accept references. This creates a new struct with the Objective-C pointer:

```swift
// Simplified
public struct Data {
    // For use by bridging code only.
    private init(dataReference: NSData) {
        self.dataReference = dataReference.copy()
    }
}
```

Just as in Objective-C, when we store a value type we must call copy to protect ourselves from mutation to that reference after the initializer returns.

In almost all API in the SDK, the returned value type is immutable. In these cases, the `copy` is simply a `retain` and this operation is cheap. If the returned type is mutable, then we must pay the full cost of the copy.

#### From Swift to Objective-C

For simple struct types like `Date`, we will create a new `NSDate` when the value is bridged.

```swift
return NSDate(timeIntervalSinceReferenceDate: _time)
```

For reference-holding types like `Data`, we simply pass our interior `NSData` pointer back to Objective-C. The underlying data is not copied at bridging time. If the receiver of that data wishes to store it, then they should call `copy` as usual. In some cases, we can use a technique employed by other bridge types to actually share a reference count between Swift and Objective-C, therefore preserving the value semantics of the type on the Swift side if the Objective-C code retains the reference.

#### Archiving

Encoding any of the new value types is possible by bridging them to their corresponding reference type and using all of the usual `NSCoding` mechanisms. An improved archiving system for Swift is a future goal and out of scope for this proposal.

#### Copying

In Swift, there is no need to conform to the `NSCopying` protocol. Copies are made by the implementation automatically and on-demand via a copy-on-write implementation.

When a Swift value type is sent to Objective-C, then it is converted into the corresponding reference type (see _Bridging_ above). In this case, the receiver may want to perform a `copy` in order to isolate itself from mutations that may happen to the object after the method call returns. This is the same as what is required in frameworks today.

If a custom subclass of a reference type is used, then that subclass must implement `copyWithZone` as per the usual rules. The struct type will call `copy` and `mutableCopy` on it when it determines it needs to copy.

### Existing Objective-C API that uses Reference Types

In the vast majority of cases, reference type API will appear as the bridged type.

However, if a reference type is used as a pointer-to-pointer (e.g., `NSData **`) then it will appear in Swift API as a reference type (`AutoreleasingUnsafeMutablePointer<NSData>`). These cases are rare in our SDK for the proposed Foundation value types.

### Binary Compatibility

The Swift team is developing an extensive proposal for binary compatibility. Details are are in the [LibraryEvolution.rst](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst) document. The current draft allows the following modifications for struct types in future versions of Foundation:

> Swift structs are a little more flexible than their C counterparts. By default, the following changes are permitted:
>
> * Reordering any existing members, including stored properties.
> * Adding any new members, including stored properties.
> * Changing existing properties from stored to computed or vice versa.
> * Changing the body of any methods, initializers, or accessors.
> * Adding or removing an observing accessor (willSet or didSet) to/from an existing property. This is effectively the same as modifying the body of a setter.
> * Removing any non-public, non-versioned members, including stored properties.
> * Adding a new protocol conformance (with proper availability annotations).
> * Removing conformances to non-public protocols.

## Impact on existing code

There is no impact on existing Objective-C clients, either for source or binary compatibility.

The impact on existing Swift code will be much higher:

* Existing Swift code that uses the reference types will be calling SDK code that uses value types
* We do not propose to automatically migrate uses of `NSData` to the new API vended by `Data`. The migrator will do the minimum amount of change possible. This will prevent new or changed behavior from surprising developers (for example, the more important distinction of `let` vs `var` for these types).
* Existing Swift subclasses of the reference types will remain as-is.
* Developers will be required to manually switch to the new API, if they choose to do so. In some cases, this may be more than a simple renaming of a method. They may choose to take advantage of the new, meaningful difference between `let` and `var`.

## Potential Future Directions

This proposal uses the existing `NS` classes as the customization point for the value types which store a reference. A future proposal could introduce a new Swift protocol, removing the requirement to subclass. This would be a great way to express the requirements of Foundation's class clusters. Implementing this approach would require quite a bit of new code to provide default implementations, which is why we defer it from this proposal.

## Alternatives considered

### Do Nothing

We know from our experience with Swift so far that if we do not provide these value types then others will, often by wrapping our types. It would be better if we provide one canonical API for greater consistency across all Swift code. This is, after all, the purpose of the Foundation framework.

Here are some of the most popular Swift projects on GitHub. For comparison purposes, at the time of writing, Foundation itself has 1,500+ stars on GitHub.

* [Alamofire](https://github.com/Alamofire/Alamofire) - A networking library, 14,000+ stars on GitHub
  * 4 struct types, including a key `Response` type
* [Carthage](https://github.com/Carthage/Carthage) - A package manager, 5,800+ stars on GitHub
  * 35 struct types, including command pattern objects, URLs, modules and submodules, errors, build arguments, build settings
* [Perfect](https://github.com/PerfectlySoft/Perfect) - A server-side app library, 5,000+ stars on GitHub
  * 6 struct types, including configuration types, database queries, route map and socket types
* [RxSwift](https://github.com/ReactiveX/RxSwift) - Reactive programming library, 2,900+ stars on GitHub
  * 14 struct types, including logging, events, observers, and a `Bag` collection type

### Hide Reference Types Completely

This was our first approach, but it has several downsides:

* A tremendous amount of risk, because there is no fallback if we miss an API or if we do not consider an esoteric use case.
* Requires more boilerplate in the overlay (introduction of a protocol, dummy subclass which calls through to Swift code, etc.), which introduces more opportunity for error.
* Considered to be extremely difficult to implement for the migrator. This means that most Swift code would have to be manually fixed up.
* If implementing the `struct` types requires changes to the frameworks that ship on the OS, we may be in a very difficult situation as the overlay has to run as far back as OS X 10.9 and iOS 7.

### Change the Name of the Reference Types

We considered changing the name of the reference types (e.g., `NSData` to `DataReference`), but decided to simply leave the NS prefix in place. This allows for a more natural transition to the value type without causing a lot of churn on existing code. It also avoids introducing a new name. We will have to document carefully what the difference is between the reference type and the value type, so developers can become familiar with our convention.

### Other Potential Foundation Value Types

Several criteria were used to develop the list of proposed value types:

0. The type must not rely upon object identity.
0. The reference type most likely already implements `NSCopying` and `NSCoding`.
0. The most interesting value types can provide new mutable API. If there are no mutations possible, it may still make sense as a value type but it is lower priority.

The following classes were considered and rejected or deferred for the described reasons:

* `Locale`: This class has API for an automatically updating current locale. It would be surprising for a `let` value to change based on user preferences. It may be reconsidered in the future.
* `Progress`: Progress objects are meant to be mutated, so the idea of a constant one (with `let`) does not make much sense. Additionally, `NSProgress` has object identity via the concept of `becomeCurrent` and `resignCurrent`.
* `Operation`: This class is designed to be subclassed and overridden to provide customized behavior.
* `Calendar`: This class has API for an automatically updating current calendar. It may be reconsidered in the future.
* `Port`: This class has a delegate, which would make for confusing value semantics as delegates require identity for their callbacks to make sense.
* `Number` and `Value`: These are already partially bridged. Some improvements could be made but we wish to consider them separately from this proposal.
* `Predicate`: We will consider this type in a future proposal.
* `OrderedSet`, `CountedSet`: We will consider these types in a future proposal.
* `NSError`: NSError is already partially bridged to the Swift `ErrorProtocol` type, which makes introducing a concrete value type difficult. We will consider improvements in this area in a future proposal.
* `NSAttributedString`: This is an obvious candidate for a value type. However, we want to take more time to get this one right, since it is the fundamental class for the entire text system. We will address it in a future proposal.
* `NSURLSession` and related networking types: We will consider these types in a future proposal.

