# Introduce `IfOptionalUnWrappingOperator` to Fundation framework

* Proposal: [SE-0219](0219-introduce-ifOptionalUnwrappingOperator.md)
* Author: [Tim Wang](https://github.com/ShenghaiWang)
* Review Manager:
* Status: Awaiting review
* Implementation:

## Introduction

This proposal adds >> as Optional value Unwrapping Operator.

## Motivation

Swift has optional value types and we often do need to do some operation if there is a value and do nothing if there is not as shown in the code below:

```swift
var str: String? = "some string"
if let str = str {
  print(str)
}
```

However, it looks too lengthy especially considering there are many cases like this.

## Proposed solution

Add the >> operator to the language, either we can implement in compiler level or just add as operator definition as below:

```swift
func >><T>(lhs: T?, rhs: ((T) -> Void)) {
    if let lhs = lhs {
        rhs(lhs)
    }
}
```

Thus, we can just write code like this:

```swift
var str: String? = "some string"
func someFunc(str: String) {
    print(str)
}
str >> someFunc
```

or

```swift
var str: String? = "some string"
s >> {
    //some Func
    print($0)
}
```

## Detailed design

Suggest to add the >> operator definition to the Fundation framework as below:

```swift
func >><T>(left: T?, right: ((T) -> Void)) {
    if let left = left {
        right(left)
    }
}
```

## Source compatibility

This change is purely additive so has no source compatibility consequences.

## Effect on ABI stability

This change is purely additive so has no ABI stability consequences.

## Effect on API resilience

This change is purely additive so has no API resilience consequences.

## Alternatives considered

The alternative of >> definition that returns a value from the operation could be like below. However, considering if we get returned value from the method applied, it is just like mapping operation on that variable, which is kind of unnecessary.

```swift
@discardableResult
func >><T, R>(lhs: T?, rhs: ((T) -> R)) -> R? {
    if let lhs = lhs {
        return rhs(lhs)
    }
    return nil
}
```swift

For this operation, we could also consider using ?>.
