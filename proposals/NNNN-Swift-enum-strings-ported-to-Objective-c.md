# Swift Enum strings ported to Objective-c

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Derrick Ho](https://github.com/wh1pch81n)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
* Previous Proposal: [SE-0033](0033-import-objc-constants.md)

## Introduction

We should allow swift-enum-strings and swift-struct-strings to be ported to objective-c.  We can use the following notation:

@objc enum Planets: String {
  case Mercury
}

struct Food {
  @objc public static let hamburger = Food(rawValue: "hamburger")
}

Swift-evolution thread: 
[Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161114/028950.html)
[Discussion](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170220/032656.html)


## Motivation

NS_STRING_ENUM and NS_EXSTENSIBLE_STRING_ENUM are annotations that you can add to an objective-c global string.
The annotations will make swift interpret the objective-c global strings as structs.  However, there does not exist 
any way to go the other way around.  Anyone that wants global strings to be available to objective-c and swift will need
to make them in Objective-c.  We should give API authors the ability to make global strings in the swift language by allowing 
enums to be converted to NSString's in objective-c


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

typedef NSString *_Nonnull Food;
static Food const FoodCalamari = @"Calamari";
static Food const FoodFish = @"Fish";
```

```
// `@objc` and `String` can be applied to a struct to make it available to objective-c:
//

@objc
public struct Planets: String {
  public let rawValue: String //<- This should be implicit and the user should not need to add it
  init(rawValue: String) { self.rawValue = rawValue } //<- This should be implicit and the user should not need to add it
  
  @objc public static let Earth = Planets(rawValue: "Earth") //<- user defines these
  @objc public static let Venus = Planets(rawValue: "Venus") //<- user defines these
}

// This can be ported over to objective-c as a class

typedef NSString *_Nonnull Planets;
Planets const PlanetsEarth = @"Earth";
Planets const PlanetsVenus = @"Venus";
```

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
// The variable will <name_of_enum><name_of_case>.  And should follow camel-case rules.
typedef NSString *_Nonnull Food;
static Food const FoodCalamari = @"Calamari";
static Food const FoodFish = @"Flounder";
```

### swift-struct-string - string translations

A swift-struct-string needs to be marked with `@objc` and inherit from `String` to be available to objective-c.  A property must be marked with @objc to be made available to objective-c.

```
// Swift
@objc
struct Planet {
  @objc public static let Earth = Planet(rawValue: "Earth")
}

// Objective-c
typedef NSString *_Nonnull Planet;
static Planet const PlanetEarth = @"Earth";
```

## Source compatibility

This will be an additive feature and will not break anything existing.

## Alternatives considered

- Don't change anything.
