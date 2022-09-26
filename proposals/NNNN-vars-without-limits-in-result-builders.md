# Lift all limitations on variables in result builders

* Authors: [Pavel Yaskevich](https://github.com/xedin)
* Implementation: [apple/swift#60839](https://github.com/apple/swift/pull/60839)
* Review Manager: TBD
* Status: **Awaiting discussion**

## Introduction

Implementation of result builder transform (introduced by [SE-0289](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md)) places a number of limitations on local variable declarations, specifically: all declarations should have initializer expression, cannot be computed, have observers, or attached property wrappers. None of the uses described above are explicitly restricted by SE-0289.

Swift-evolution thread: [Pitch thread topic for this proposal](https://forums.swift.org/t/pitch-lift-all-limitations-on-variables-in-result-builders/60460)

## Motivation

Result builder proposal [describes how individual components in a result builder body are transformed](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md#the-result-builder-transform), and it states that local declaration statements are unaffected by the transformation, which implies that all declarations allowed in context should be supported but that is not the case under current implementation that requires that declarations to have a simple name, storage, and an initializing expression.

In certain circumstances it's useful to be able to declare a local variable that, for example, declares multiple variables, has default initialization, or an attached property wrapper (with or without initializer). Let's take a look at a simple example:


```
func compute() -> (String, Error?) { ... }

func test(@MyBuilder builder: () -> Int?) {
  ...
}

test {
  let (result, error) = compute()

  let outcome: Outcome

  if let error {
    // error specific logic
    outcome = .failure
  } else {
    // complex computation
    outcome = .success
  }

  switch outcome {
   ...
  }
}
```


Both declarations are currently rejected because result builders only allow simple (with just one name) stored properties with an explicit initializer expression.

Local variable declarations with property wrappers (with or w/o explicit initializer) could be utilized for a variety of use-cases, including but not limited to:

* Verification and/or formatting of the user-provided input

```
import SwiftUI

struct ContentView: View {
    var body: some View {
        GeometryReader { proxy in
            @Clamped(10...100) var width = proxy.size.width
            Text("\(width)")
        }
    }
}
```

* Interacting with user defaults

```
import SwiftUI

struct AppIntroView: View {
    var body: some View {
        @UserDefault(key: "user_has_ever_interacted") var hasInteracted: Bool
        ...
        Button("Browse Features") {
            ...
            hasInteracted = true
        }
        Button("Create Account") {
            ...
            hasInteracted = true
        }
    }
}
```



## Proposed solution

I propose to treat local variable declarations in the result builder bodies as-if they appear in a function or a multi-statement closure without any additional restrictions.

## Detailed design

The change is purely semantic, without any new syntax. It allows declaring:

* uninitialized
* default initialized
* computed
* observed
* property wrapped
* lazy

properties in the result builder bodies and treat them just like they are treated in regular functions and closures, which means all of the semantics checks to verify their validity would still be performed and invalid (based on existing rules) declarations are still going to be rejected by the compiler.

Uninitialized variables are of particular interest because they require special support in the result builder as stated in [SE-0289](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md#assignments) otherwise there is no way to initialize them.

## Source compatibility

This is an additive change which should not affect existing source code.


## Effect on ABI stability and API resilience

These changes do not require support from the language runtime or standard library.
