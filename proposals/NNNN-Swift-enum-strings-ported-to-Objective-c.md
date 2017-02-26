# Swift Enum strings ported to Objective-c

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Derrick Ho](https://github.com/wh1pch81n)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
* Previous Proposal: [SE-0033](0033-import-objc-constants.md)

## Introduction

We should allow swift-enum-strings and swift-struct-strings to be bridged to objective-c.  We can use the following notation:

@objc enum Planets: String {
  case Mercury
}

@objc struct Food: String {
  public static let hamburger = Food(rawValue: "hamburger")
}

Creating a bridgable version will allow objective-c to enjoy some of the benefits that swift enjoys. 

Swift-evolution thread: 
[Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
[Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170220/032656.html)


## Motivation

NS_STRING_ENUM and NS_EXSTENSIBLE_STRING_ENUM are annotations that you can add to an objective-c global string.
The annotations will make swift interpret the objective-c global strings as enum and structs respectively in theory.
But it actually [doesn't ever create enums](https://bugs.swift.org/browse/SR-3146).

The problem seems to stem from the conversion from objc to swift.  It might be more fruitful to make a conversion from swift to objc.

However, what if we take it a step further?  Turning a swift-string-enum into a bunch of global NSStrings really limits its power.  There are many classes written by apple that are structs in swift but become classes in objective-c (i.e. String becomes NSString, Date becomes NSDate, Array becomes NSArray, etc).  There is a special bridging mechanism that allows this to be possible.  I think we should expand on that.

## Proposed solution

```
// `@objc` and `String` can be applied to an enum to make it available to objective-c:
//
@objc
public enum Food: String {
   case Calamari 
   case Fish
} 

// This can be ported over to Objective-c as an objective-c class

@interface Food: NSObject

@property (readonly) NSString *_Nonnull rawValue;

- (instancetype _Nullable)initWithRawValue:(NSString *_Nonnull)rawValue;

+ (instanceType _Nonnull)Calamari;
+ (instanceType _Nonnull)Fish;

@end

```

```
// `@objc` and `String` can be applied to a struct to make it available to objective-c:
//

@objc
public struct Planets: String {
  public let rawValue: String //<- This should be implicit and the user should not need to add it
  init(rawValue: String) { self.rawValue = rawValue } //<- This should be implicit and the user should not need to add it
  
  public static let Earth = Planets(rawValue: "Earth") //<- user defines these
  public static let Venus = Planets(rawValue: "Venus") //<- user defines these
}

// This can be ported over to objective-c as a class

@interface Planets: NSObject 
- (instancetype _Nonnull)initWithRawValue:(NSString *_Nonnull)rawValue;

+ (instancetype)Earth;
+ (instancetype)Venus;
@end
```

The difference between a swift-enum-string and a swift-struct-string is that swift-enum-string provides a failable initializer while swift-struct-string provides a non-failable initializer.

## Detailed design

### swift-string-enum - case/string translations

A swift-enum-string, is created with cases and it has an implicit string value based on the name of the case.  The user may also add a name that does not equal the name of the case.

```
// Swift
@objc
public enum Food: String {
  case Calamari 
  case Fish = "Flounder" //<-- User wants Fish to be Flounder
} 

// Objective-c

@interface Food: NSObject

@property (readonly) NSString *_Nonnull rawValue;

+ (instanceType _Nonnull)Calamari;
+ (instanceType _Nonnull)Fish;

@end

@implementation Food
+ (instanceType _Nonnull)Calamari { return [[Food alloc] initWithRawValue:@"Calimari"]; }
+ (instanceType _Nonnull)Fish { return [[Food alloc] initWithRawValue:@"Flounder"]; } //<-- Fisher contains Flounder
@end
```

### swift-string-enum - failable initializer

A swift-enum-string has the ability to be initialized with a string.  If the string matches one of the possible cases, then it returns it, otherwise it will return nil.  This feature might be implemented as a dictionary or some other means that gets the same results; Below is my suggestion.

```
// Assuming this swift implementation
@objc
public enum Food: String {
  case Calamari 
  case Fish = "Flounder" //<-- User wants Fish to be Flounder
} 

// The objective-c failable initializer may look like this.
@implementation Food

- (instancetype _Nullable)initWithRawValue:(NSString *_Nonnull)rawValue {
  static NSDictionary <NSString *, NSString *>*states;
  if (!states) {
    // A dictionary where the KEYs are the acceptable rawValue's and the VALUE are the string representation of a static method signature
    states = @{
      @"Calimari" : @"Calimari",
      @"Flounder" : @"Fish"
    }
  }

  NSString *method;
  if ((method = states[rawValue])) {
    return [[Food class] performSelector:NSSelectorFromString(method)];
  }
  return nil;
}

@end
```

### swift-string-enum - methods

swift enums allow methods to be defined.  If you mark a method with `@objc` it should be made available to objective-c. 

``` 
// Swift
@objc
public enum Food: String {
  case Calamari 
  case Fish

  @objc func price() -> Double {
    // ...
  }
} 

// Objective-c
@interface Food: NSObject 
// ...

- (Double)price;

// ...
@end
```

### swift-struct-string - string translations

A swift-struct-string needs to be marked with `@objc` and inherit from `String` to bridge to objective-c.  A property or method must be marked with @objc to be made available to objective-c.

```
// Swift
@objc
struct Planet {
  @objc public static let Earth = Planet(rawValue: "Earth")

  @objc public func distanceFromSun() -> Double { ... }
}

// Objective-c
@interface Planet
+ (instancetype _Nonnull)Earth;
+ (Double)distanceFromSun;
@end
```

### swift-struct-string - non-failable initializer

The swift-struct-string initializer should not be failable and will accept any string value

```
@implementation Planet
- (instancetype _Nonnull)initWithRawValue:(NSString *)rawValue {
  if ((self = [super init])) {
    _rawValue = rawValue;
  }

  return self;
}
@end
```

### swift-struct-string - extension

One of the key attributes of an extensible string enum is that it can be extended.  This should produce something available to objective-c.  The original definition of Planet needs to have been marked with @objc.

```
// Swift
extension Planet {
  @objc public static let Pluto = Planet(rawValue: "Pluto")
}

// Objective-c

@interface Planet (extention_1)
- (instancetype _Nonnull)Pluto;
@end

@implementation Planet (extention_1)
- (instancetype _Nonnull)Pluto {
  return [[Planet alloc] initWithRawValue:@"Pluto"];
}
@end
```

### swift-string-enum && swift-struct-string - equality/hash/rawValue

When an enum or struct is marked with `@objc` and `String`, the objective-c class that is produced should have its equality/hash methods and rawValue property implicitly be implemented.  The user should not need to implement these on his/her own. 

```
@implementation Food

- (instancetype)rawValue { return _rawValue; }

- (NSUInteger)hash {
  return [[self rawValue] hash];
}

- (BOOL)isEqual:(id)object {
  if (self == object) { return YES }
  if (![object isKindOfClass:[Food class]]) { return NO; }

  return [self.rawValue isEqualToString:((Food *)object).rawValue];
}

@end
```

## Objective-c name

In the above examples, the objective-c name of the class and the swift name of the class were the same.  If this causes a naming conflict then the objective-c name could be Prefixed with ENUM.

```
// Swift
@objc
enum Planet: String { ... }

// Objective-c
@interface ENUMPlanet
@end
```

The programmer should still be able to add their own name by specifying it as an argument.

```
// Swift
@objc(CustomPlanet)
enum Planet { ... }

// Objective-c
@interface CustomPlanet
@end
```

## Source compatibility

This will be an additive feature and will not break anything existing.

## Alternatives considered

- Implement a swift class that implements the above described behviors.

- Don't change anything.
