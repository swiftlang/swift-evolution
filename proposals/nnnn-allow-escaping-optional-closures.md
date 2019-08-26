# Allow @escaping for optional closures as functions parameters

* Proposal: [SE-NNNN](nnnn-allow-escaping-optional-closures.md)
* Authors: [Giuseppe Lanza](https://github.com/gringoireDM)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

> A closure is said to escape a function when the closure is passed as an argument 
> to the function, but is called after the function returns . When you declare a 
> function that takes a closure as one of its parameters, you can write @escaping 
> before the parameter’s type to indicate that the closure is allowed to escape.

Quote from [Swift documentation](https://docs.swift.org/swift-book/LanguageGuide/Closures.html)

This statement is not always true when considering optional closures passed as function parameters.

This proposal aims to uniform the behaviour of optional closures with the well-known behaviour of 
non-optional closures when passed as function parameters.

Swift-evolution thread: [Allowing @escaping for optional closures in method signature](https://forums.swift.org/t/allowing-escaping-for-optional-closures-in-method-signature/27556/1)

## Motivation

Since swift 3, closures in function parameters are by default non-escaping: when a closure is 
passed as a function parameter, then this closure will be synchronously used within the function 
scope before it returns.

```swift
func nonescaping(closure: () -> Void)
func escaping(closure: @escaping () -> Void)
```

The swift documentation currently doesn't cover the case where an optional closure is accepted
as a function parameter.

```swift
func foo(closure: (() -> Void)? = nil)
```

In this case the closure is implicitly escaping because it is stored as associated value of the 
case `.some` of `Optional`. But is that closure intended to escape the actual function scope? 

Is this closure executed before or after the function's return?

This is an information that remains unknown without knowing the actual function implementation, 
or without the help of additional documentation provided by the developer.

```swift
func foo(closure: (() -> Void)? = nil) {
    ....
    closure?()
    ...
}
```

is therefore equivalent to 

```swift
func foo(closure: @escaping () -> Void = { }) {
    ....
    closure?()
    ...
}
```

with the exception that `closure` is not escaping `foo` in the second case, and if it wasn't 
for the `Optional`, `closure` wasn't escaping `foo` in the first case either.

Besides, the fact that for optional the escapability is not explicitly defined by the usual 
`@escaping` keyword, brought many developers to think that it isn't possible to make an 
optional closure escapable, having many newcomers to the language in confusion after reading 
the documentation.

## Proposed solution

Escape analysis should be extended to optional parameter functions to allow them to be explicitly
marked as `@escaping` in case they will escape the function scope.

Having Optional closures uniformed to non-optional closures behavior will reduce the confusion
caused by the documentation not covering this case. Also it will provide to users more explicit and
expressive APIs. Optional closures not marked as `@escaping` should be by default non-escaping
to match the existing behavior of non-optional closures.

## Detailed design

```
func foo(closure: @escaping (() -> Void)? = nil) // escaping
func foo(closure: (() -> Void)? = nil) // non-escaping
```

Having the closure to be Optional will no longer cause, as side effect, the closure to implicitly
escape. The escape analysis would be extended to Optional parameter functions so that they can be
explicitly marked as `@escaping` where appropriate.

## Source compatibility

Changing the default of Optional closures from being escaping to non-escaping will introduce a
a change to the contract on the function, which is potentially source-breaking for both 
implementations and clients of the function.

## Effect on ABI stability

Default for optional closures will have to change from being escaping to non-escaping.

## Effect on API resilience

This feature can be added without breaking ABI just by introducing `@nonescaping`, extending escape 
analysis to optional parameter functions to allow them to be explicitly marked as `@nonescaping`,
without changing the default behaviour.
