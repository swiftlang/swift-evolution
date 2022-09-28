# Lift all limitations on variables in result builders

* Proposal: [SE-NNNN](NNNN-vars-without-limits-in-result-builders.md)
* Author: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting discussion**
* Implementation: [apple/swift#60839](https://github.com/apple/swift/pull/60839)
* Review: ([pitch](https://forums.swift.org/t/pitch-lift-all-limitations-on-variables-in-result-builders/60460))

## Introduction

The implementation of the result builder transform (introduced by [SE-0289](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md)) places a number of limitations on local variable declarations in the transformed function. Specifically, local variables need to have an initializer expression, they cannot be computed, they cannot have observers, and they cannot have attached property wrappers. None of these restrictions were explicit in the SE-0289 proposal, but they are a *de facto* part of the current feature.

## Motivation

The result builder proposal [describes how the result builder transform handles each individual component in a function body](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md#the-result-builder-transform). It states that local declarations are unaffected by the transformation, which implies that any declaration allowed in that context should be supported. That is not the case under the current implementation, which requires that local variables declarations must have a simple name, storage, and an initializing expression.

In certain circumstances, it's useful to be able to declare a local variable that, for example, declares multiple variables, has default initialization, or has an attached property wrapper (with or without an initializer). Let's take a look at a simple example:

```swift
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

Both declarations are currently rejected because result builders only allow simple (with just one name) stored variables with an explicit initializer expression.

Local variable declarations with property wrappers (with or without an explicit initializer) can be utilized for a variety of use-cases, including but not limited to:

* Verification and/or formatting of the user-provided input

```swift
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

```swift
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

I propose to treat local variable declarations in functions transformed by result builders as if they appear in an ordinary function without any additional restrictions.

## Detailed design

The change is purely semantic, without any new syntax. It allows variables of all of these kinds to be declared in a function that will be transformed by a result builder:

* uninitialized variables
* default-initialized variables (e.g. variables with optional type)
* computed variables
* observed variables
* variables with property wrappers
* `lazy` variables

These variables will be treated just like they are treated in regular functions.  All of the ordinary semantic checks to verify their validity will still be performed, and invalid declarations (based on the standard rules) will still be rejected by the compiler.

Uninitialized variables are of particular interest because they require special support in the result builder as stated in [SE-0289](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md#assignments); otherwise, there is no way to initialize them.

## Source compatibility

This is an additive change which should not affect existing source code.

## Effect on ABI stability and API resilience

These changes do not require support from the language runtime or standard library, and they do not change anything about the external interface to the transformed function.
