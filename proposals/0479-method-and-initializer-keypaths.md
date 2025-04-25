# Method and Initializer Key Paths

* Proposal: [SE-0479](0479-method-and-initializer-keypaths.md)
* Authors: [Amritpan Kaur](https://github.com/amritpan), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Becca Royal-Gordon](https://github.com/beccadax)
* Status: **Active Review (April 22 ... May 5, 2025)**
* Implementation: [swiftlang/swift#78823](https://github.com/swiftlang/swift/pull/78823), [swiftlang/swiftsyntax#2950](https://github.com/swiftlang/swift-syntax/pull/2950), [swiftlang/swiftfoundation#1179](https://github.com/swiftlang/swift-foundation/pull/1179) 
* Experimental Feature Flag: `KeyPathWithMethodMembers`
* Review: ([pitch](https://forums.swift.org/t/pitch-method-key-paths/76678)) ([review](https://forums.swift.org/t/se-0479-method-and-initializer-key-paths/79457))

## Introduction

Swift key paths can be written to properties and subscripts. This proposal extends key path usage to include references to method members, such as instance and type methods, and initializers.

## Motivation

Key paths to method members and their advantages have been explored in several discussions on the Swift forum, specifically to [unapplied instance methods](https://forums.swift.org/t/allow-key-paths-to-reference-unapplied-instance-methods/35582) and to [partially and applied methods](https://forums.swift.org/t/pitch-allow-keypaths-to-represent-functions/67630). Extending key paths to include reference to methods and initializers and handling them similarly to properties and subscripts will unify instance and type member access for a more consistent API. While this does not yet encompass all method kinds, particularly those with effectful or non-hashable arguments, it lays the groundwork for more expressive, type-safe APIs. In doing so, it brings many of the benefits of existing key path components to supported methods and initializers, such as abstraction, reusability via generic functions and dynamic invocation with state type safety. 

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
  static func add(_ a: Int, _ b: Int) -> Int {
    return a + b
  }
}

let addKeyPath: KeyPath<Calculator.Type, Int> = \Calculator.Type.add(4, 5)
```

Here, `addKeyPath` is a key path that references the add method of `Calculator` as a metatype member. The key path’s root type is `Calculator.Type`, and the value resolves to an applied instance method result type of`Int`. 

### Overloads

Keypaths to methods with the same base name and distinct argument labels can be disambiguated with explicit  argument labels:

```swift
struct Calculator {
  var subtract: (Int, Int) -> Int { return { $0 + $1 } }
  func subtract(this: Int) -> Int { this + this}
  func subtract(that: Int) -> Int { that + that }
}
  
let kp1 = \Calculator.subtract // KeyPath<Calculator, (Int, Int) -> Int
let kp2 = \Calculator.subtract(this:) // KeyPath<Calculator, (Int) -> Int>
let kp3 = \Calculator.subtract(that:) // KeyPath<Calculator, (Int) -> Int>
let kp4 = \Calculator.subtract(that: 1) // KeyPath<Calculator, Int>
```

### Implicit closure conversion

This feature also supports implicit closure conversion of key path methods, allowing them to used in expressions where closures are expected, such as in higher order functions: 

```swift
struct Calculator {
  func power(of base: Int, exponent: Int) -> Int {
    return Int(pow(Double(base), Double(exponent)))
  }
}

let calculators = [Calculator(), Calculator()]
let results = calculators.map(\.power(of: 2, exponent: 3))
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
let power = dynamicCalculator.power
print(power(10, 2))
```

### Effectful value types

Methods annotated with `nonisolated` and `consuming` are supported by this feature. However, noncopying root and value types [are not supported](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0437-noncopyable-stdlib-primitives.md#additional-future-work). `mutating`, `throws` and `async` are not supported for any other component type and will similarly not be supported for methods. Additionally keypaths cannot capture closure arguments that are not `Hashable`/`Equatable`.

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

## Future directions

The effectful value types that are unsupported by this feature will all require new `KeyPath` types and so have been left out of this proposal. Additionally, this lack of support impacts existing key path component kinds and could be addressed in a unified proposal that resolves this gap across all key path component kinds. 
