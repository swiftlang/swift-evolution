# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Nicholas Maccharoli](https://github.com/nirma)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

This proposal simply aims to make parentheses optional when defining a function that takes no arguments and to make computed properties with a return type of `Void` a compile time error.

[Swift-evolution thread](https://forums.swift.org/t/pitch-allow-function-definitions-to-omit-parentheses-if-no-parameters/)

## Motivation

Function definitions in swift allow omitting `-> Void` as the return type for functions that return nothing.
`()` is also Void as well but why not extend the logic and convenience of not having to write a `Void` return type for a function that returns nothing to not having to write an empty parameter list for a function that takes nothing, no arguments.

I believe that this would make the language more consistent and if
this change was paired with making it illegal to define computed properties with a `Void` return type it would make the Swift language more consistent.

Computed properties should try not to stray away from running any complex logic greater than `O(1)`.


## Proposed solution

### `func` definitions

Allow functions that take no arguments to be defined as follows with no parentheses:

```swift
    func foo {
      ...
    }
```

### `Void` computed properties

Currently it is legal to write this:

```swift
class Foo {
    var myProperty: Void {
        print("Why do I exist?")
    }
}

```

This should not be allowed by the compiler, it serves little to no purpose.
Computed properties should be `O(1)` complexity and return something,
anything else belongs in a function.

## Detailed design

TBA

## Source compatibility

Making computed properties with a type `Void` illegal would break any existing code that does that but in my honest opinion common sense would dictate that code written like that is illformed anyways.

## Effect on ABI stability

I don't think there is any practical effect on ABI stability.

## Effect on API resilience

TBA

## Alternatives considered

None at the time of this writing.
