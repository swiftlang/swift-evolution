# Method and Initializer Key Paths

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Amritpan Kaur](https://github.com/amritpan), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#78823](https://github.com/swiftlang/swift/pull/78823) [swiftsyntax/swiftsyntax#2950](https://github.com/swiftlang/swift-syntax/pull/2950) 
* Upcoming Feature Flag: `KeyPathWithMethodMembers`
* Review: ([pitch](https://forums.swift.org/t/pitch-method-key-paths/76678))

## Introduction

Swift key paths can be written to properties and subscripts. This proposal extends key path usage to include references to method members, such as instance and type methods, and initializers.

## Motivation

Key paths to method members and their advantages have been explored in several discussions on the Swift forum, specifically to [unapplied instance methods](https://forums.swift.org/t/allow-key-paths-to-reference-unapplied-instance-methods/35582) and to [partially and applied methods](https://forums.swift.org/t/pitch-allow-keypaths-to-represent-functions/67630). Extending key paths to include reference to methods and initializers and handling them similarly to properties and subscripts will unify instance and type member access for a more consistent API. Key path methods and initializers will also enjoy all of the benefits offered by existing key path component kinds, e.g. simplify code by abstracting away details of how these properties/subscripts/methods are modified/accessed/invoked, reusability via generic functions that accept key paths to methods as parameters, and supporting dynamic invocation while maintaining type safety.

## Proposed solution

We propose the following usage:

```swift
struct Calculator {
  func square(of number: Int) -> Int {
    return number * number * multiplier
  }

  func cube(of number: Int) -> Int {
    return number * number * number * multiplier
  }

  init(multiplier: Int) {
    self.multiplier = multiplier
  }

  let multiplier: Int
}

// Key paths to Calculator methods
let squareKeyPath = \Calculator.square
let cubeKeyPath = \Calculator.cube
```

These key paths can then be invoked dynamically with a generic function:

```swift
func invoke<T, U>(object: T, keyPath: KeyPath<T, (U) -> U>, param: U) -> U {
  return object[keyPath: keyPath](param)
}

let calc = Calculator(multiplier: 2)

let squareResult = invoke(object: calc, keyPath: squareKeyPath, param: 3)
let cubeResult = invoke(object: calc, keyPath: cubeKeyPath, param: 3)
```

Or used to dynamically create a new instance of Calculator:

```swift
let initializerKeyPath = \Calculator.Type.init(multiplier: 5)
```

This proposed feature homogenizes the treatment of member declarations by extending the expressive power of key paths to method and initializer members.

## Detailed design

Key path expressions can refer to instance methods, type methods and initializers, and imitate the syntax of non-key path member references.

### Argument Application

Key paths can reference methods in two forms:

1. Without argument application: The key path represents the unapplied method signature.
2. With argument application: The key path references the method with arguments already applied.

Continuing our `Calculator` example, we can write either:

```swift
let squareWithoutArgs: KeyPath<Calculator, (Int) -> Int> = \Calculator.square
let squareWithArgs: KeyPath<Calculator, Int> = \Calculator.square(of: 3)
```

If the member is a metatype (e.g., a static method, class method, initializer, or when referring to the type of an instance), you must explicitly include `.Type` in the key path root type.

```swift
struct Calculator {
  func add(_ a: Int, _ b: Int) -> Int {
    return a + b
  }
}

let calc = Calculator.self
let addKeyPath: KeyPath<Calculator.Type, (Calculator) -> (Int, Int) -> Int> = \Calculator.Type.add
```

Here, `addKeyPath` is a key path that references the add method of `Calculator` as a metatype member. The key path’s root type is `Calculator.Type`, and it resolves to an unapplied instance method: `(Calculator) -> (Int, Int) -> Int`. This represents a curried function where the first step binds an instance of `Calculator`, and the second step applies the method arguments.

```swift
let addFunction = calc[keyPath: addKeyPath]
let fullyApplied = addFunction(Calculator())(20, 30)`
```

`addFunction` applies an instance of Calculator to the key path method. `fullyApplied` further applies the arguments (20, 30) to produce the final result.

### Overloads

Keypaths to methods with the same base name and distinct argument labels can be disambiguated by explicitly including the argument labels:

```swift
struct Calculator {
  var subtract: (Int, Int) -> Int { return { $0 + $1 } }
  func subtract(this: Int) -> Int { this + this}
  func subtract(that: Int) -> Int { that + that }
}
  
let kp1 = \S.subtract // KeyPath<S, (Int, Int) -> Int
let kp2 = \S.subtract(this:) // WritableKeyPath<S, (Int) -> Int>
let kp3 = \S.subtract(that:) // WritableKeyPath<S, (Int) -> Int>
let kp4 = \S.subtract(that: 1) // WritableKeyPath<S, Int>
```

### Dynamic member lookups

`@dynamicMemberLookup` can resolve method references through key paths, allowing methods to be accessed dynamically without explicit function calls:

```swift
@dynamicMemberLookup
struct DynamicKeyPathWrapper<Root> {
    var root: Root

    subscript<Member>(dynamicMember keyPath: KeyPath<Root, Member>) -> Member {
        root[keyPath: keyPath]
    }
}

let dynamicCalculator = DynamicKeyPathWrapper(root: Calculator())
let subtract = dynamicCalculator.subtract
print(subtract(10))
```

### Effectful value types

Methods annotated with `nonisolated` and `consuming` are supported by this feature. `mutating`, `throwing` and `async` are not supported for any other component type and will similarly not be supported for methods. Keypaths cannot capture method arguments that are not `Hashable`/`Equatable`, so `escaping` is also not supported.

### Component chaining

Component chaining between methods or from method to other key path types is also supported with this feature and will continue to behave as `Hashable`/`Equatable` types.

```swift
let kp5 = \Calculator.subtract(this: 1).signum()  
let kp6 = \Calculator.subtract(this: 2).description
```

## Source compatibility

This feature has no effect on source compatibility.

## ABI compatibility

This feature does not affect ABI compatibility.

## Implications on adoption

This feature has no implications on adoption.
