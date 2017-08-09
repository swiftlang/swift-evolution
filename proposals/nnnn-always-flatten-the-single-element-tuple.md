# Feature name

* Proposal: [SE-NNNN](nnnn-always-flatten-the-single-element-tuple.md)
* Authors: [SusanDoggie](https://github.com/SusanDoggie)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Because the painful of SE-0110, here is a proposal to clarify the tuple
syntax.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170605/037054.html)

## Motivation

Because of implementation of SE-0110, Swift 4 has a horrible source compatibility breaking changed.

The code in Swift 3, which is not passed the type checking in Swift 4.
```swift
[(1, 2)].map(+)  // return [3]
```

## Proposed solution
1. single element tuple always be flattened

```swift
let tuple1: (((Int))) = 0  // TypeOf(tuple1) == Int

let tuple2: ((((Int))), Int) = (0, 0)  // TypeOf(tuple2) == (Int, Int)

let tuple3: ((((Int, Int))), Int) = ((0, 0), 0)  // TypeOf(tuple3) == ((Int, Int), Int)
```

2. function arguments list also consider as a tuple, which means the
function that accept a single tuple should always be flattened.

```swift
// TypeOf(add1) == `(Int, Int) -> Void`
func add1(lhs: Int, rhs: Int) -> Int {
    return lhs + rhs
}

// TypeOf(add2) == `(Int, Int) -> Void`, flattened
func add2(pair: (Int, Int)) -> Int {
    return pair.0 + pair.1
}
```

```swift
let fn1: (Int, Int) -> Void = { _, _ in }  // TypeOf(fn1) == `(Int, Int) -> Void`

let fn2: ((Int, Int)) -> Void = { _, _ in }  // TypeOf(fn2) == `(Int, Int) -> Void`, always flattened

let fn3: (Int, Int) -> Void = { _ in }  // not allowed, here are two arguments

let fn4: ((Int, Int)) -> Void = { _ in }  // not allowed, here are two arguments
```

## Examples

```swift
[(1, 2)].map({ x, y in x + y })  // this line is correct

[(1, 2)].map({ $0 + $1 })  // this line is correct
 
[(1, 2)].map({ tuple in tuple.0 + tuple.1 })  // this line should not accepted

[(1, 2)].map({ $0.0 + $0.1 })  // this line should not accepted
```

```swift
// `((Int, Int)) -> Void` always flatten to `(Int, Int) -> Void` and $0 is never be a tuple.
[(1, 2)].map({ $0 })  // return [1], 
```

## Source compatibility

It's breaking source compatibility with Swift 3, closure accept a single element tuple will not passed anymore.

## Alternatives considered
