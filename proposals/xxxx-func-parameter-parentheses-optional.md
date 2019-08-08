# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Nicholas Maccharoli](https://github.com/nirma)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

This proposal simply aims to make parentheses optional when defining a function that takes no arguments.
This would make Swift's syntax a little more fluid I believe. 

[Swift-evolution thread](https://forums.swift.org/t/pitch-allow-function-definitions-to-omit-parentheses-if-no-parameters/)

## Motivation

Swift already has parts of the language that allow omission of syntax for the sake of clarity.
One example is omitting writing `return` when it is clearly implied.

Instead of writing:
```swift
var defaultHeight: Int {
    return 100
}
```

We can simply write:

```swift
var defaultHeight: Int {
    100
}
```
The empty parameter list seems a bit pointless when defining a function, the presence of `func` already signals that it is a function and being able to omit `()` and just write: `func funcName {}` instead of `func funcName() {}` would make the language's syntax a little more fluid and would remove the need to write `()` which just adds noise to the code when there are no parameters defined.

I personally think this would improve readability and help promote the notion of no unnecessary syntax.

## Proposed solution

Allow functions that take no arguments to be defined as follows with no parentheses:

```swift
    func foo {
      ...
    }
```

but the callsite would still use the fucntion call operator as before:

`foo()`

This proposal **DOES NOT** affect rules around return type syntax or `throws` or anything other than the parameter list.
The following is a list of examples that would all be valid under the new syntax:


## Detailed design

TBA

## Source compatibility

This change would not break any existing code.


## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

None at the time of this writing.
