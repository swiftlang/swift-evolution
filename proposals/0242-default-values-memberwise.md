# Synthesize default values for the memberwise initializer

* Proposal: [SE-0242](0242-default-values-memberwise.md)
* Author: [Alejandro Alonso](https://github.com/Azoy)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 5.1)**
* Decision Notes: [Rationale](https://forums.swift.org/t/se-0242-synthesize-default-values-for-the-memberwise-initializer/20618/98)
* Implementation: [apple/swift#19743](https://github.com/apple/swift/pull/19743)

## Introduction

This proposal aims to solve a simple outstanding problem with the way the Swift compiler currently synthesizes the memberwise initializer for structures by synthesizing default values for properties with default initializers.

*This is mentioned in the "State of the Memberwise Initializer" forum post: [here](https://forums.swift.org/t/state-of-the-memberwise-initializer/17168)*

## Motivation

Currently the Swift compiler is able to synthesize a fairly basic memberwise initializer for structures.

```swift
struct Dog {
  var age: Int
  var name: String
}
```

The compiler is able to synthesize a memberwise iniailizer for this structure which simply looks like this:

```swift
init(age: Int, name: String)
```

But, lets say we want all dogs to have a default value of `0` for the age:

```swift
struct Dog {
  var age: Int = 0
  var name: String
}
```

A user might naively try using this default value when constructing their `Dog` instance:

```swift
// I just want to set the name of Dog, sparky is a newborn
let sparky = Dog(name: "Sparky")
```

To their surprise, they can't. `missing argument for parameter 'age' in call`. Using the compiler synthesized memberwise initializer has turned to become a nuisance rather than a nice removal of boilerplate. In many cases the user may optionally just define their own initializer with a default value for the age parameter.

```swift
struct Dog {
  var age: Int = 0
  var name: String
  
  // This is defined because the Swift compiler can't generate default values for properties with an initial value
  init(age: Int = 0, name: String) {
    self.age = age
    self.name = name
  }
}
```

## Proposed solution

I propose simply doing the obvious and synthesizing default values for properties with default initializers in the memberwise initializer. Simple code like the following will simply work:

```swift
struct Dog {
  var age: Int = 0
  var name: String

  // The generated memberwise init:
  init(age: Int = 0, name: String)
}

// This now works
let sparky = Dog(name: "Sparky") // Dog(age: 0, name: "Sparky")
```

The following example displays the memberwise initializer being produced by the compiler with a combination of variables with default values.

```swift
struct Alphabet {
  var a: Int = 97
  let b: String
  var c: String = "c"
  let d: Bool = true
  var e: Double = Double.random(in: 0 ... .pi)

  // The generated memberwise init:
  init(
    a: Int = 97,
    b: String,
    c: String = "c",
    e: Double = Double.random(in: 0 ... .pi)
  )
}
```

Notice the `d` variable does not get an entry in the memberwise initializer because it is a constant whose value is already assigned. This behavior already exists with the current initializer.

In the case where multiple variables are being initialized together, we cannot generate a default value for them in the memberwise initializer. For example:

```swift
struct Person {
  var (firstName, lastName) = ("First", "Last")

  // The generated memberwise init:
  init(firstName: String, lastName: String)
}
```

## Detailed design

This change does not alter the requirements needed to synthesize the memberwise initializer, but rather if we can synthesize the memberwise initializer, also synthesize default values for properties with default initializers. Note that we can only synthesize values for *variables* that have declared default initializers and not *constants*.

## Source compatibility

This is a purely additive feature, thus source compatibility is not affected.

## Effect on ABI stability

This feature does not alter ABI, thus ABI stability is not affected.

## Effect on API resilience

As the memberwise initializer is only synthesized as an internal initializer, this feature does not affect API resilience.

## Alternatives considered

We could simply not do this and save this proposal for a solution much larger in regards to fixing more problems the memberwise initializer has. The downside is that we put off obvious changes like this for much longer because of wanting to solve a bigger problem. I agree we should solve the bigger problems, but by solving problems like this it aids in the solution of the larger problem.
