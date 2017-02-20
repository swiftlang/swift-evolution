# Swift Enum strings ported to Objective-c

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Derrick Ho](https://github.com/wh1pch81n)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
* Previous Proposal: [SE-0033](0033-import-objc-constants.md)

## Introduction

Currently, you can add NS_STRING_ENUM or NS_EXSTENSIBLE_STRING_ENUM to your Objective-c global strings to make them available in swift as a struct thanks to SE-0033.  This is a one way port.  This proposal seeks a way to write an enum of strings or a struct of strings that can be ported to objective-c by introducing a new attribute, @objcstring.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

## Motivation

In SE-0033, we were given NS_STRING_ENUM and NS_EXSTENSIBLE_STRING_ENUM which is suppose to port to a swift enum and swift struct respectively.  NS_STRING_ENUM allows Objective-C global strings to be available in swift as a string enum.  However there is currently no way to bring string enums into Objective-c.  Although NS_STRING_ENUM aims to create a swift enum, it fails and ends up generating a struct instead. According to this bug report it seems like it is impossible to do (https://bugs.swift.org/browse/SR-3146 ).  If turning global string into an enum is impossible then perhaps we should rethink the data structure.

## Proposed solution

### The counter part to NS_STRING_ENUM
```
// a new attribute `@objcstring` can be applied to an enum to make it available to objective-c:
//
@objcstring
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

### The counter part to NS_EXTENSIBLE_STRING_ENUM

```
// a new attribute `@objcstring` can be applied to a struct to make it available to objective-c:
//

@objcstring
public struct Planets {
  public let rawValue: String //<- This should be automatically defined by @objcstring
  init(rawValue: String) { self.rawValue = rawValue } //<- This should be automatically defined by @objcstring 
  
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

## Detailed design

### NS_STRING_ENUM - case/string translations

A swift enum string, is created with cases and it has an implicit string value based on the name of the case.  The user may also add a name that does not equal the name of the case.

```
// Swift
@objcstring
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

### NS_STRING_ENUM - failable initializer

A swift enum string has the ability to be initialized with a string.  If the string matches one of the possible cases, then it returns it, otherwise it will return nil.  This feature might be implemented as a dictionary or some other means that gets the same results; Below is my suggestion.

```
// Assuming this swift implementation
@objcstring
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

### NS_STRING_ENUM - methods

swift enums allow methods to be defined.  If you mark a method with @objc it should be made available to objective-c.  The enum needs to have @objcstring applied to it in order to be allowed to add @objc to one of the functions.

``` 
// Swift
@objcstring
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

### NS_EXTENSIBLE_STRING_ENUM - string translations

A struct marked with @objcstring will have an objective-c class produced.  A property or method must be marked with @objc to be made available to objective-c.

```
// Swift
@objcstring
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

### NS_EXTENSIBLE_STRING_ENUM - non-failable initializer

The initializer should not be failable and will accept any string value

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

### NS_EXTENSIBLE_STRING_ENUM - extension

One of the key attributes of an extensible string enum is that it can be extended.  This should produce something available to objective-c.  The original definition of Planet needs to have been marked with @objcstring.

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

### NS_STRING_ENUM && NS_EXTENSIBLE_STRING_ENUM - equality/hash

When an enum or struct is marked with @objcstring, the objective-c class that is produced should have its equality/hash methods implicitly be implemented.  The user should not need to implement these on his/her own. 

```
@implementation Food

- (NSUInteger)hash {
return [[self rawValue] hash];
}

- (BOOL)isEqual:(id)object {
if (self == object) { return YES }
if (![object isKindOfClass:[Food class]]) { return NO; }

return [self.rawValue isEqualToString:((Food *)object).rawValue];
}

@end

## Objective-c name

In the above examples, the objective-c name of the class and the swift name of the class were the same.  If this causes a naming conflict then the objective-c name could be Prefixed with ENUM.

```
// Swift
@objcstring
enum Planet { ... }

// Objective-c
@interface ENUMPlanet
@end
```

The programmer should still be able to add their own name by specifying it as an argument.
```
// Swift
@objcstring(CustomPlanet)
enum Planet { ... }

// Objective-c
@interface CustomPlanet
@end
```

## Source compatibility

This will be an additive feature and will not break anything existing.

## Alternatives considered

- Continuing to use NS_STRING_ENUM to make available strings that can be accessed in objective-c and swift.  This is not a good solution because it forces the programmer to use Objective-c;  The proposed solution would allow developers to continue developing in swift.

- Implement a swift class that implements the above described behviors.
