# Default Generic Arguments 

* Proposal: [SE-NNNN](XXXX-default-generic-arguments.md)
* Author: [Srdan Rasic](https://github.com/srdanrasic)
* Review manager: TBD
* Status: TBD

## Introduction

Generics are one of the most powerful features of Swift. They enable us to write code that operates on various types while providing compile-time type safety. Sometimes it is natural for generic code to often operate on the same type, but currently this is not facilitated by the language. This proposal introduces default generic arguments.

## Motivation

In some scenarios, a generic argument is often fulfilled by the same type. Consider the following type from popular reactive frameworks:

```swift
struct Signal<T, E: Error> {}
```

Such type is more often than not used with the second argument set to a non-instantiable `NoError` type:

```swift
let message: Signal<String, NoError>
```

It would be convenient if the second argument could be defaulted to the `NoError` type so that the previous declaration can look like:

```swift
let message: Signal<String>
```

Supporting default arguments would make the typical declarations clean and concise while allowing more specific declarations when needed.   

## Current Workaround

The problem can be partially solved by introducing a typealias that fulfils the generic argument.

```swift
typealias NonFailableSignal<T> = Signal<T, NoError>
```

This solution, however, requires tackling into the realm of the hardest problems in computer science - naming. It is often hard to find appropriate name for the partial specialisation of a multi-argument generic type. Additionally, in most cases the solution does not share overall feel of the programming language.

Similar partial solution can be achieved by subclassing, but it shares same disadvantages as typealiases and is limited to class types only.

## Proposed Solution

Allow setting default types to generic arguments in type declarations. This proposal suggests syntax inspired by default values of function arguments. 

### Type Declaration

Default generic type specialisation would follow generic argument declaration, separated by the equality sign:

```swift
struct X<T = Int> {}
```

In case of multiple generic arguments, it would be possible to default last *N* arguments where *N* is less than or equal to the total number of arguments:

```swift
struct X<T, U = Int> {}
struct X<T = Int, U = Int> {}
```

Defaulting `T`, but not `U` would not be permitted as declaring an instance of such type would ambiguous since the arguments are index-based.

When an argument is constrained, default type specification would be placed after the constraint:

```swift
struct X<T: P = Int> {}
```

### Usage 

When declaring an instance of generic type with default arguments, few cases are worth considering.

Given the type:

```swift
struct X<T = Int, U = Float, V = Double> {}
```

(I) by not specialising generic arguments one accepts the default argument types:

```swift
let x: X // assumes X<Int, Float, Double>
```

(II) by specialising first *N* arguments, one accepts the default argument types of the remaining arguments:

```swift
let x: X<Int32> 				// assumes X<Int32, Float, Double>
let x: X<Int32, Int64> 			// assumes X<Int32, Int64, Double>
let x: X<Int32, Int64, Int128> 	// assumes X<Int32, Int64, Int128>
```

It would not be possible to specialise argument at index *i* without specialising all prior arguments (those at indices less than *i*) due to arguments being index-based.

## Impact on Existing Code

None. This functionality is strictly additive and does not break any existing code.


## Alternatives Considered

If generic argument would have labels like their function counterparts, it would be possible to default and declare any combination of arguments. However, since it is very rare that generic types have more than two or three arguments, such feature is deemed redundant.