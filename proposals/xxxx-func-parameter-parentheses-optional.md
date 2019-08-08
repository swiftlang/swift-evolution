# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Nicholas Maccharoli](https://github.com/nirma)
* Review Manager: TBD
* Status: **Awaiting implementation**


## Introduction

This proposal simply aims to make parentheses optional when defining a function that takes no arguments.
This would make Swift's syntax a little more fluid. 

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

Another example could be functions that return nothing.
It is legal to write: 

```swift
func bar() {
    ...
}
```

Omitting `-> Void` instead of writing the void return type explicitly:

```swift
func bar() -> Void {
    ...
}
```

The empty parameter list seems a bit pointless when defining a function, the presence of `func` already signals that it is a function definition and being able to omit `()` and just write: `func funcName {}` instead of `func funcName() {}` would make the language's syntax a little more fluid.

## Proposed solution

Allow functions that take no arguments to be defined as follows with no parentheses:

```swift
    func foo {
      ...
    }
```

but the callsite would still use the fucntion call operator as before:

`foo()`

This proposal **DOES NOT** affect rules around return type syntax or `throws` or anything other than the case of an empty parameter list during function definition.


The following is a list of examples that would all be valid under the proposed new syntax:

```swift
func foo {
    ...
}

func foo() {
    ...
}

func foo throws {
    ...
}

func foo() -> Int {
    ...
}

func foo throws -> Int {
    ...
}

func foo<T> -> T {
    ...
}
```


## Detailed design

TBA

## Source compatibility

This change would not break any existing code because the alternative notation of `func foo() { ... }` is still completely valid.

## Effect on ABI stability

This should have no effect in ABI stability.

## Effect on API resilience

None.

## Alternatives considered

None at the time of this writing.
