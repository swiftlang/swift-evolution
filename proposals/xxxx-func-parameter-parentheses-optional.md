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

The empty parameter list seems a bit pointless when defining a function and being able to omit it and just write: `func funcName {}` instead of `func funcName() {}` would make the language's syntax a little more fluid and would remove the need to write `()` which just adds noise to the code when there are no parameters defined.

I personally think this would improve readability. 

## Proposed solution

Allow functions that take no arguments to be defined as follows with no parentheses:

```swift
    func foo {
      ...
    }
```

but the callsite would still use the fucntion call operator as before:

`foo()`

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
