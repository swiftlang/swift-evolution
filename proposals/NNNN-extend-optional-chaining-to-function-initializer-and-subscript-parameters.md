# Extend Optional Chaining to Function, Initializer, and Subscript Parameters

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Liam Stevenson](https://github.com/liam923)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Optional chaining is a feature of Swift that allows easy use of optionals. Sometimes, it is useful to call a function, initializer, or subscript conditionally based on whether the value of one of its parameters is `nil`.

## Motivation

Often when using Swift, optional chaining is used “for querying and calling properties, methods, and subscripts on an optional that might currently be nil,” to quote Apple's "The Swift Programming Language." This is one of the great features of the language. However, often it is useful to call a function, initializer, or a subscript if its parameter's values are not `nil`, but this must be done using an `if` statement:

```swift
var arr = ["apples", "oranges", "pears", "bananas"]
let index: Int? = 2

var removedElement: String?
if let index = index {
    removedElement = arr.removeAtIndex(index) //sets removedElement to "pears"
}
```

This `if` statement seems unneccessary considering the usefulness of optional chaining.

## Proposed solution

The proposed solution is to allow a question mark (?) to be placed after an optional value wished to be used as a parameter. Then, the function, initializer, or subscript will be called if and only if the parameter's value is not `nil`. If it has a return type, it will return an optional, which will be `nil` if the parameter is nil. This would allow the example above to be shortened to:

```swift
var arr = ["apples", "oranges", "pears", "bananas"]
let index: Int? = 2

var removedElement: String?
removedElement = arr.removeAtIndex(index?) //sets removedElement to "pears"
```

However, if `index` is changed to `nil`, the following happens:

```swift
var arr = ["apples", "oranges", "pears", "bananas"]
let index: Int? = nil

var removedElement: String?
removedElement = arr.removeAtIndex(index?) //sets removedElement to nil
```

Due to the syntax used for optional chaining, this use of the question mark (?) fits well with its existing uses with optionals in Swift.

## Detailed design

In a subscript or parameter call, any number of the parameters are allowed to use this proposed optional chaining feature. If none of them are `nil`, then the function, initializer, or subscript will be called normally, with each parameter being unrapped:

```swift
func foo(x: Int, _ y: Int, _ z: Int) { ... }
var a: Int?
var b: Int?
var c: Int?

a = 1
b = 2
c = 3
foo(a?, b?, c?) //Calls foo(a!, b!, c!) since none are nil

a = nil
b = 2
c = 3
foo(a?, b?, c?) //Doesn't call foo since a is nil

a = 1
b = nil
c = nil
foo(a?, b?, c?) //Doesn't call foo since b and c are nil

a = 1
b = 2
c = 3
foo(a?, b?, 3) //Calls foo(a!, b!, 3) since none are nil

a = 1
b = 2
c = 3
foo(1, 2, c?) //Calls foo(1, 2, c!) since c is not nil


func bar(x: Int, _ y: Int, _ z: Int) -> Int { ... }

a = 1
b = 2
c = 3
bar(a?, b?, c?) //Calls bar(a!, b!, c!) since none are nil and returns its normal value as type Int?

a = nil
b = 2
c = 3
bar(a?, b?, c?) //Doesn't call bar since a is nil and returns nil

a = 1
b = nil
c = nil
bar(a?, b?, c?) //Doesn't call bar since b and c are nil and returns nil

a = 1
b = 2
c = 3
bar(a?, b?, 3) //Calls bar(a!, b!, 3) since none are nil and returns its normal value as type Int?

a = 1
b = 2
c = 3
bar(1, 2, c?) //Calls bar(1, 2, c!) since c is not nil and returns its normal value as type Int?
```

However, this is not allowed to be used when the type of the parameter is already optional:

```swift
func foo(x: Int, _ y: Int, _ z: Int) { ... }
func bar(x: Int?, _ y: Int, _ x: Int) { ... }
var a: Int?
var b: Int?
var c: Int?

// OK
foo(a?, b?, c?)

// Not allowed since the first parameter takes an optional
bar(a?, b?, c?)

// OK
bar(a, b?, c?)
```

## Impact on existing code

None. This is purely additive.

## Alternatives considered

Not changing anything.
