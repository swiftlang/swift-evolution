# Feature name

* Proposal: [SE-NNNN](NNNN-memberwise-init-defaults.md)
* Authors: [Ortal Yahdav](https://github.com/swift-ortal)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

This proposal makes [structure memberwise initializers](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID214) more consistent, and more versatile by adding [default parameter values](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Functions.html#//apple_ref/doc/uid/TP40014097-CH10-ID169) for all properties that have [default values](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID206).

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Oftentimes structures will have reasonable defaults. Consider an example of an Envirnoment that begins with [Earth's properties](https://nssdc.gsfc.nasa.gov/planetary/factsheet/):

```
struct Environment {
  var mass = 5.97
  var diameter = 12_756
  var density = 3_340
  var gravity = 9.8
  var escapeVelocity = 11.2
  var rotationPeriod = 23.9
  var lengthOfDay = 24
  var distanceFromSun = 149.6
  
  let speedOfLight: Int = 299_792_458
}
```

An instance could easily be constructed thanks to the [default intializer](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID213):

```
/// An example of what is auto-synthesized by the default initializer
init() { }
```

Example usage:

```
generatePlanet(
  name: "Earth",
  environment: Environment())
```

An instance could be constructed by modifying all the properties thanks to the memberwise initializer that would resemble:

```
/// An example of what is auto-synthesized by the memberwise initializer
init(
  mass: Double,
  diameter: Int,
  density: Int,
  gravity: Double,
  escapeVelocity: Double,
  rotationPeriod: Double,
  lengthOfDay: Int,
  distanceFromSun: Double)
{
  self.mass = mass
  self.diameter = diameter
  self.density = density
  self.gravity = gravity
  self.escapeVelocity = escapeVelocity
  self.rotationPeriod = rotationPeriod
  self.lengthOfDay = lengthOfDay
  self.distanceFromSun = distanceFromSun
}
```

Example usage:

```
generatePlanet(
  name: "Mars",
  environment: Environment(
    mass: 0.642,
    diameter: 6_792,
    density: 3_933,
    gravity: 3.7,
    escapeVelocity: 5.0,
    rotationPeriod: 24.6,
    lengthOfDay: 24.7,
    distanceFromSun: 227.9))
```

There are two main problems with the state as it is now:

1. It's not easy to modify some of the properties.
2. If even a single non-default property is added, all the default values must be provided.

### Problem 1: It's not easy to modify some of the properties.

If the user wants to create an Earth-like planet and only modify a few of the properties, he or she may attempt to do the following:

```
generatePlanet(
  name: "Earth",
  environment: Environment(
    gravity: 9.9))
```

However this won't compile. Instead, a workaround is required.

#### Workaround 1.1: Use a variable

```
var environment = Environment()
environment.gravity = 9.9

generatePlanet(
  name: "Earth",
  environment: environment)
```

The main drawback is that it requires more lines of code, and requires defining another variable everytime this strategy is used. In this simple example it meant 3 more lines of code and 1 extra variable, but when used in other instances such as when constructing a screen with a bunch of components, it could mean significantly more lines of code and having difficulty with variable naming.

#### Workaround 1.2: Creating a helper method

```
extension Environment {
  func with(gravity: Double) -> Environment {
    var environment = self
    environment.gravity = gravity
    return environment
  }
}

generatePlanet(
  name: "Earth",
  environment: Environment().with(gravity: 9.9))
```

Disadvantages:

- Again this requires more code.
- To enable any of the other properties to be modified too, either one monolithic method would be needed, or 8 additional methods similar to the one above (one for each property).

#### Workaround 1.3: Supply all the default arguments

```
generatePlanet(
  name: "Earth-like planet",
  environment: Environment(
    mass: 5.97,
    diameter: 12_756,
    density: 3_340,
    gravity: 9.9,
    escapeVelocity: 11.2,
    rotationPeriod: 23.9,
    lengthOfDay: 24,
    distanceFromSun: 149.6))
```

This has several disadvantages:

- It requires a lot more lines of code.
- It's difficult to see which is the variable that is actually different from the defaults (i.e. gravity).
- It no longer conforms to the [DRY principal](https://en.wikipedia.org/wiki/Don%27t_repeat_yourself), since the default values are repeated. If one of these defaults was found to be inaccurate, it would be difficult to ensure that all the places are updated accordingly.

#### Workaround 1.4: Create a custom initializer

```
struct Environment {
  var mass = 5.97
  var diameter = 12_756
  var density = 3_340
  var gravity = 9.8
  var escapeVelocity = 11.2
  var rotationPeriod = 23.9
  var lengthOfDay = 24
  var distanceFromSun = 149.6
  
  let speedOfLight: Int = 299_792_458
  
  init(
    mass: Double? = nil,
    diameter: Int? = nil,
    density: Int? = nil,
    gravity: Double? = nil,
    escapeVelocity: Double? = nil,
    rotationPeriod: Double? = nil,
    lengthOfDay: Int? = nil,
    distanceFromSun: Double? = nil)
  {
    if let mass = mass { self.mass = mass }
    if let diameter = diameter { self.diameter = diameter }
    if let density = density { self.density = density }
    if let gravity = gravity { self.gravity = gravity }
    if let escapeVelocity = escapeVelocity { self.escapeVelocity = escapeVelocity }
    if let rotationPeriod = rotationPeriod { self.rotationPeriod = rotationPeriod }
    if let lengthOfDay = lengthOfDay { self.lengthOfDay = lengthOfDay }
    if let distanceFromSun = distanceFromSun { self.distanceFromSun = distanceFromSun }
  }
}

generatePlanet(
  name: "Earth",
  environment: Environment(
    gravity: 9.9))
```

This too has several disadvantages:

- It's a lot more lines of boilerplate code.
- It no longer follows the DRY principal. Anytime a new property is added, 3 lines of code must be modified instead of 1.
- It either requires using `nil` as the default argument as in the example above, which keeps the default constant values DRY, but would not work well if any of the properties were optional; or
- It requires duplicating the default values in the arguments as in the previous workaround.

### Problem 2: If even a single non-default property is added, all the default values must be provided.

Imagine a new `id` property is added to the structure and it has no sensible default.

```
struct Environment {
  var id: Int
  var mass = 5.97
  var diameter = 12_756
  var density = 3_340
  var gravity = 9.8
  var escapeVelocity = 11.2
  var rotationPeriod = 23.9
  var lengthOfDay = 24
  var distanceFromSun = 149.6
  
  let speedOfLight: Int = 299_792_458
}
```

The user would like to initialize it like so:

```
let id = nextAutoIncrementID()

generatePlanet(
  name: "Earth",
  environment: Environment(
    id: id))
```

However, this is not possible. The default initializer no longer exists, and the memberwise initializer now looks like this:

```
/// An example of what is auto-synthesized by the memberwise initializer
init(
  id: Int,
  mass: Double,
  diameter: Int,
  density: Int,
  gravity: Double,
  escapeVelocity: Double,
  rotationPeriod: Double,
  lengthOfDay: Int,
  distanceFromSun: Double)
{
  self.id = id
  self.mass = mass
  self.diameter = diameter
  self.density = density
  self.gravity = gravity
  self.escapeVelocity = escapeVelocity
  self.rotationPeriod = rotationPeriod
  self.lengthOfDay = lengthOfDay
  self.distanceFromSun = distanceFromSun
}
```

#### Workaround 2.1: Supply a default value

```
struct Environment {
  var id = 0
  var mass = 5.97
  var diameter = 12_756
  var density = 3_340
  var gravity = 9.8
  var escapeVelocity = 11.2
  var rotationPeriod = 23.9
  var lengthOfDay = 24
  var distanceFromSun = 149.6
  
  let speedOfLight: Int = 299_792_458
}

var environment = Environment()
environment.id = nextAutoIncrementID()

generatePlanet(
  name: "Earth",
  environment: environment))
```

Drawbacks:

- The object exists for a period of time with a seemingly valid value (`0`) from the compiler's standpoint, but actually invalid value from the business logic standpoint.
- The user could forget to update the value to a correct one.

#### Workaround 2.2: Use a different type that can represent an invalid result

```
struct Environment {
  var id: Int? = nil
  var mass = 5.97
  var diameter = 12_756
  var density = 3_340
  var gravity = 9.8
  var escapeVelocity = 11.2
  var rotationPeriod = 23.9
  var lengthOfDay = 24
  var distanceFromSun = 149.6
  
  let speedOfLight: Int = 299_792_458
}

var environment = Environment()
environment.id = nextAutoIncrementID()

generatePlanet(
  name: "Earth",
  environment: environment))
```

Drawbacks:

- The underlying type was modified (i.e. `Int?` instead of `Int`), meaning everywhere that reads the code must handle the case where it is `nil`.
- The user could forget to update the value to a correct one.

#### Workaround 2.3: Supply all the default arguments

This is similar to Workaround 1.3.

```
generatePlanet(
  name: "Earth",
  environment: Environment(
    id: nextAutoIncrementID(),
    mass: 5.97,
    diameter: 12_756,
    density: 3_340,
    gravity: 9.8,
    escapeVelocity: 11.2,
    rotationPeriod: 23.9,
    lengthOfDay: 24,
    distanceFromSun: 149.6))
```

#### Workaround 2.4: Create a custom initializer

This is similar to Workaround 1.4.

## Proposed solution

Describe your solution to the problem. Provide examples and describe
how they work. Show how your solution is better than current
workarounds: is it cleaner, safer, or more efficient?

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Source compatibility

Relative to the Swift 3 evolution process, the source compatibility
requirements for Swift 4 are *much* more stringent: we should only
break source compatibility if the Swift 3 constructs were actively
harmful in some way, the volume of affected Swift 3 code is relatively
small, and we can provide source compatibility (in Swift 3
compatibility mode) and migration.

Will existing correct Swift 3 or Swift 4 applications stop compiling
due to this change? Will applications still compile but produce
different behavior than they used to? If "yes" to either of these, is
it possible for the Swift 4 compiler to accept the old syntax in its
Swift 3 compatibility mode? Is it possible to automatically migrate
from the old syntax to the new syntax? Can Swift applications be
written in a common subset that works both with Swift 3 and Swift 4 to
aid in migration?

## Effect on ABI stability

Does the proposal change the ABI of existing language features? The
ABI comprises all aspects of the code generation model and interaction
with the Swift runtime, including such things as calling conventions,
the layout of data types, and the behavior of dynamic features in the
language (reflection, dynamic dispatch, dynamic casting via `as?`,
etc.). Purely syntactic changes rarely change existing ABI. Additive
features may extend the ABI but, unless they extend some fundamental
runtime behavior (such as the aforementioned dynamic features), they
won't change the existing ABI.

Features that don't change the existing ABI are considered out of
scope for [Swift 4 stage 1](README.md). However, additive features
that would reshape the standard library in a way that changes its ABI,
such as [where clauses for associated
types](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md),
can be in scope. If this proposal could be used to improve the
standard library in ways that would affect its ABI, describe them
here.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.
