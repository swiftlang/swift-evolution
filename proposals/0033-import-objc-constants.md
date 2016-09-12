# Import Objective-C Constants as Swift Types

* Proposal: [SE-0033](0033-import-objc-constants.md)
* Author: [Jeff Kelley](https://github.com/SlaunchaMan)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000097.html)

## Introduction

Given a list of constants in an Objective-C file, add an attribute that will enable Swift to import them as either an Enum or a Struct, using `RawRepresentable` to convert to their original type. This way, instead of passing strings around for APIs, we can use more type-safe objects and take advantage of Swift’s code completion, as well as making our Swift (and Objective-C!) code more readable and more approachable to beginners.

Swift-evolution thread: [Original E-Mail](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006893.html), [Replies](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/006904.html)

[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010625.html)

## Motivation

Many Objective-C APIs currently use constants, especially `NSString` constants, to list possible values. Consider this small example from `HKTypeIdentifiers.h` for body measurements (comments and availability macros stripped for readability):

```Objective-C
HK_EXTERN NSString * const HKQuantityTypeIdentifierBodyMassIndex;
HK_EXTERN NSString * const HKQuantityTypeIdentifierBodyFatPercentage;
HK_EXTERN NSString * const HKQuantityTypeIdentifierHeight;
HK_EXTERN NSString * const HKQuantityTypeIdentifierBodyMass;
HK_EXTERN NSString * const HKQuantityTypeIdentifierLeanBodyMass;
```

When imported to Swift, these declarations are imported thusly:

```Swift
public let HKQuantityTypeIdentifierBodyMassIndex: String
public let HKQuantityTypeIdentifierBodyFatPercentage: String
public let HKQuantityTypeIdentifierHeight: String
public let HKQuantityTypeIdentifierBodyMass: String
public let HKQuantityTypeIdentifierLeanBodyMass: String
```

The aim of this proposal is to encapsulate these strings into an `enum` or a `struct` that conforms to `RawRepresentable` to represent as type `String`. Why bother? When these APIs are used, the methods that use the constants simply take `NSString` parameters where these constants are to be used, such as the methods listed below. For a novice programmer, it’s not immediately clear that these methods take “special” values defined in another file altogether:

```Objective-C
+ (nullable HKQuantityType *)quantityTypeForIdentifier:(NSString *)identifier;
+ (nullable HKCategoryType *)categoryTypeForIdentifier:(NSString *)identifier;
+ (nullable HKCharacteristicType *)characteristicTypeForIdentifier:(NSString *)identifier;
+ (nullable HKCorrelationType *)correlationTypeForIdentifier:(NSString *)identifier;
```

Sometimes, as with `NSError` domains, it’s OK to use your own values when there are predefined constants, but other times, such as with HealthKit identifiers, it’s not. The former cases are well-handled by a `struct`, whereas the latter are well-handled by an `enum`. By adding a these cases, we can both better document our existing Objective-C code and provide more power in Swift. When a new programmer to the framework looks at the documentation, it will be immediately clear where the string—or other type—constants they need to use come from.

## Proposed solution

As [suggested by Doug Gregor on swift-evolution](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/006904.html), combining a `typedef` with a new attribute could clean this up while still keeping everything as the original type internally. Here are examples using both structs and enums:

### Enums

HealthKit identifiers are a good case for enums, as the user of the API cannot add new entries:

```Objective-C
typedef NSString * HKQuantityTypeIdentifier __attribute__((swift_wrapper(enum));

HK_EXTERN HKQuantityTypeIdentifier const HKQuantityTypeIdentifierBodyMassIndex;
HK_EXTERN HKQuantityTypeIdentifier const HKQuantityTypeIdentifierBodyFatPercentage;
HK_EXTERN HKQuantityTypeIdentifier const HKQuantityTypeIdentifierHeight;
HK_EXTERN HKQuantityTypeIdentifier const HKQuantityTypeIdentifierBodyMass;
HK_EXTERN HKQuantityTypeIdentifier const HKQuantityTypeIdentifierLeanBodyMass;
```

With this additional type information, the Swift import would be vastly improved:

```Swift
enum HKQuantityTypeIdentifier : String {
    case BodyMassIndex
    case BodyFatPercentage
    case Height
    case BodyMass
    case LeanBodyMass
}
```

Method signatures in Objective-C would then use the new `typedef`:

```Objective-C
+ (nullable HKQuantityType *)quantityTypeForIdentifier:(HKQuantityTypeIdentifier)identifier;
```

This would allow us to call `quantityTypeForIdentifier()` from Swift with the struct constant directly, rather than having to call `rawValue` on it to extract the underlying `String`. The Swift code would look like this:

```Swift
let quantityType = HKQuantityType.quantityTypeForIdentifier(.BodyMassIndex)
```

Once a type is imported as an enum, other modules—and the user fo the API—would not be able to add additional entries.

### Structs

NSError domains are a good case for structs, as the user can add new entries. This subset of the declared domains:

```Objective-C
typedef NSString * NSErrorDomain __attribute__((swift_wrapper(struct)));

FOUNDATION_EXPORT NSErrorDomain const NSCocoaErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const NSPOSIXErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const NSOSStatusErrorDomain;
FOUNDATION_EXPORT NSErrorDomain const NSMachErrorDomain;
```

would be imported as:

```Swift
struct NSErrorDomain : RawRepresentable {
    typealias RawValue = String

    init(rawValue: RawValue)
    var rawValue: RawValue { get }

    static var Cocoa: NSErrorDomain { get }
    static var POSIX: NSErrorDomain { get }
    static var OSStatus: NSErrorDomain { get }
    static var Mach: NSErrorDomain { get }
}
```

For types importing as structs, if other modules need to add additional instances of the constant, it would be imported as an extension:

```Objective-C
extern NSString * const NSURLErrorDomain;
```

would be imported as:

```Swift
extension NSErrorDomain {
    static var URL: NSErrorDomain  { get }
}
```

### Naming

The name of the new constants is determined by removing any common prefix and suffix from the type name and the given cases. Names are uppercase, as with these examples from Swift code today:

```Swift
struct NSSortOptions : OptionSetType {
    init(rawValue rawValue: UInt)
    static var Concurrent: NSSortOptions { get }
    static var Stable: NSSortOptions { get }
}
```

```Swift
enum NSSearchPathDirectory : UInt {
    case ApplicationDirectory
    case DemoApplicationDirectory
    case DeveloperApplicationDirectory
    …
    case AllApplicationsDirectory
    case AllLibrariesDirectory
    case TrashDirectory
}
```

## Impact on existing code

Existing, unmodified Objective-C code will continue to be imported as-is with no changes. Existing Swift code that uses Objective-C code with these annotations will need to be updated to use the new types, but this should be possible to migrate to as all of the type information is present, and the Swift code will be using the Objective-C names for the constants.

## Alternatives considered

The second draft of this proposal used `struct` solely, as some types don’t make sense to import as enums (e.g. error domains). This version adds enums back, allowing for both versions to be used depending on the appropriate type.

The first draft of this proposal used `enum` instead of `struct` and did not contain `RawRepresentable`. It has been modified per list discussion; using `RawRepresentable` makes it easier to add new values defined elsewhere—e.g. in another module. There was some concern that `enum` didn’t quite match up with the aims of this proposal, as these identifier lists are not often `switch`ed over.

My original idea considered marking regions of code using something like `NS_CASE_LIST_BEGIN` and `NS_CASE_LIST_END`, then importing the constants declared inside of the markers as an enum, but Doug’s `typedef` solution allows for methods to also be annotated, giving the proposal even more type information to use in Swift.
