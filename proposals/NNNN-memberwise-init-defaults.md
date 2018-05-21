# Memberwise Initializers With Default Values

* Proposal: [SE-NNNN](NNNN-memberwise-init-defaults.md)
* Authors: [Ortal Yahdav](https://github.com/swift-ortal)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

This proposal makes structure's (`struct`) auto-synthesized initializers more consistent, and more versatile by adding [default parameter values](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Functions.html#//apple_ref/doc/uid/TP40014097-CH10-ID169) to all parameters that have corresponding properties with [default values](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID206).

Swift-evolution thread: [TBD: Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Structures will oftentimes have reasonable defaults. Consider an Environment which defaults to [Earth's properties](https://nssdc.gsfc.nasa.gov/planetary/factsheet/):

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

The structure could easily be constructed thanks to the [default intializer](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID213):

```
/// The auto-synthesized default initializer behaves like this:
init() { }
```

Example usage:

```
generatePlanet(
  name: "Earth",
  environment: Environment())
```

The structure could also be constructed by modifying all of its properties thanks to the [memberwise initializers](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Initialization.html#//apple_ref/doc/uid/TP40014097-CH18-ID214):

```
/// The auto-synthesized memberwise initializer behaves like this:
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

The solution is twofold:

1. Remove the default initializer for `struct`s.
2. Modify the memberwise initializer for `struct`s to include default values equivalent to the default values of their corresponding properties.

This would make initializers more **consistent**:

- Today, a `struct` that does not define a custom initializer will have 1 or 2 initializers: it will always have a memberwise initializer; but it only receives a default intializer if all of its properties have default values. This can be a [source of confusion](https://forums.swift.org/t/rules-for-structs-default-memberwise-initializers/5189). This proposal makes `struct`s more conisistent by providing exactly 1 auto-synthesized initializer.

This would make initializers more **versatile**:

- Today, memberwise initializers must be called with an argument corresponding to each of the properties on a struct, even those with default values. This proposal makes the auto-synthesized memberwise initializer more versatile by allowing the user to provide zero or more arguments for each of the properties that have default values.

## Detailed design

Here is what would happen to each property type:

 - `var` properties without default values will be required arguments. `var a: Int` -> `a: Int`
 - `var` properties with default values will be arguments with default values. `var a: Int = 1` -> `a: Int = 1`
 - `let` properties without default values will be required arguments (same as today's behavior). `let a: Int` -> `a: Int`
 - `let` properties with default values will not be arguments (same as today's behavior). `let a: Int = 1` -> N/A
 - `lazy` properties are untouched
 - `static` properties are untouched
 
The following can be pasted into a Swift Playground to see today's current behavior:
 
```
struct A {
  var a: Int = 1
  var b: Int = 1

  // TODAY: this has 2 auto-synthesized init methods:
  // init() { }
  // init(a: Int, b: Int) {
  //   self.a = a
  //   self.b = b
  // }
}

A()
// A(a: 1) // ❌ Doesn't compile; PROPOSAL: This should be valid
// A(b: 1) // ❌ Doesn't compile; PROPOSAL: This should be valid
A(a: 1, b: 1)

struct B {
  var a: Int
  var b: Int = 1

  // TODAY: this has 1 auto-synthesized init method:
  // init(a: Int, b: Int) {
  //   self.a = a
  //   self.b = b
  // }
}

// B() // Doesn't compile; OK
// B(a: 1) // ❌ Doesn't compile; PROPOSAL: This should be valid
// B(b: 1) // Doesn't compile; OK
B(a: 1, b: 1)

struct C {
  let a: Int = 1
  let b: Int = 1

  // TODAY: this has 1 auto-synthesized init method:
  // init() { }
}

C()
// C(a: 1) // Doesn't compile; OK
// C(b: 1) // Doesn't compile; OK
// C(a: 1, b: 1) // Doesn't compile; OK

struct D {
  let a: Int
  let b: Int = 1

  // TODAY: this has 1 auto-synthesized init method:
  // init(a: Int) {
  //   self.a = a
  // }
}

// D() // Doesn't compile; OK
D(a: 1)
// D(b: 1) // Doesn't compile; OK
// D(a: 1, b: 1) // Doesn't compile; OK
```

This proposal only modifies the first two structures' (`A` and `B`) behavior:

```
struct A_Proposal {
  var a: Int = 1
  var b: Int = 1

  // PROPOSAL: auto-synthesize this memberwise init:
  init(a: Int = 1, b: Int = 1) {
    self.a = a
    self.b = b
  }
}

A_Proposal()
A_Proposal(a: 1) // ✅ PROPOSAL: This would now be valid
A_Proposal(b: 1) // ✅ PROPOSAL: This would now be valid
A_Proposal(a: 1, b: 1)

struct B_Proposal {
  var a: Int
  var b: Int = 1

  // PROPOSAL: auto-synthesize this memberwise init:
  init(a: Int, b: Int = 1) {
    self.a = a
    self.b = b
  }
}

// B_Proposal() // Doesn't compile; OK
B_Proposal(a: 1) // ✅ PROPOSAL: This would now be valid
// B_Proposal(b: 1) // Doesn't compile; OK
B_Proposal(a: 1, b: 1)
```

A struct with all combinations of `var` and `let` would behave like this:

```
struct E {
  var a: Int
  var b: Int = 1
  let c: Int
  let d: Int = 1
  static var e: Int = 1
  static let f: Int = 1
  lazy var g: Int = 1

  // PROPOSAL: auto-synthesize this memberwise init
  init(a: Int, b: Int = 1, c: Int) {
    self.a = a
    self.b = b
    self.c = c
  }
}

E(a: 1, c: 1)
E(a: 1, b: 1, c: 1)
```

## Source compatibility

This will not affect source compatibility as it is purely additive:

- This will only affect `struct`s that would receive auto-synthesized memberwise initializers.
- Even though the default initializer would be removed, the same source code would compile due to the default arguments in the memberwise initializer being added.

In the examples above, everywhere `A` and `B` were used, `A_Proposal` and `B_Proposal` are used, respectively, and the code still compiles without any modifications.

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

- Wait until [[SE-0018] Flexible Memberwise Initialization](https://github.com/apple/swift-evolution/blob/master/proposals/0018-flexible-memberwise-initialization.md) is reviewed again.
  - In addition to adding default parameters to the memberwise initializer, SE-0018 solves several other, more contentious problems, and introduces new syntax. Rather than waiting until that proposal is modified/adopted/rejected, this proposal eliminates a lot of boilerplate, while sticking with current syntax. Even if SE-0018 is eventually adopted, this could be thought of as a stepping stone to that proposal.
  - One of the arguments against SE-0018 was that adding a default value would make breaking changes (since members with default values would move to the end of the memberwise initializer list). This proposal would keep them in the same place and simply make the argument optional. Thus adding a default value to a struct in this proposal would not cause breaking changes.
  - Another argument against SE-0018 was that adding/reordering members would make breaking changes. That problem already exists today; this propsal would not add a new problem. It could, however, make adding/reordering members less likely to cause breaking changes. E.g. if the deault values are used most of the time.
- Code generator: This would be difficult to keep in-sync, and the compiler is already generating initializers. It would be better to slightly tweak the generated code rather than running an extrenal code generator that does almost exactly the same thing.
