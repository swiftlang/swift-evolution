# Allow explicit specialization of generic functions

* Proposal: [SE-XXXX](https://github.com/apple/swift-evolution/blob/master/proposals/XXXX-allow-explicit-specialization-generic-functions.md)
* Author: [David Hart](https://github.com/hartbit), [Douglas Gregor](https://github.com/DougGregor)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal allows bypassing the type inference engine and explicitly specializing type arguments of generic functions. 

Previous discussions:

* [[swift-evolution] [Pitch] Allow explicit specialization of generic	functions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/018960.html)
* [[swift-evolution] Proposal: Allow explicit type parameter specification in generic function call](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161121/028971.html)

## Motivation

In Swift, generic type parameters are inferred by the argument or return value types as follows:

```swift
func foo<T>(t: T) { ... }

foo(5) // infers T = Int
```

There exists certain scenarios when a programmer wants to explicitly specialize a generic function. Swift does not allow it, so we resort to giving hints to the inference engine:

```swift
let f1 = foo as ((Int) -> Void)
let f2: (Int) -> Void = foo
let f3 = foo<Int> // error: Cannot explicitly specialize a generic function

func bar<T>() -> T { ... }

let b1 = bar() as Int
let b2: Int = bar()
let b3 = bar<Int>() // error: Cannot explicitly specialize a generic function
```

This behaviour is not very consistent with generic types which allow specialization:

```swift
let array: Array<Int> = Array<Int>(arrayLiteral: 1, 2, 3)
```

Therefore, this proposal seeks to make the above errors valid specializations:

```swift
let f3 = foo<Int> // explicitly specialized to (Int) -> Void 
let b3 = bar<Int>() // explicitly specialized to () -> Int 
```

An ambiguous scenario arrises when we wish to specialize initializer functions:

```swift
struct Foo<T: RawRepresentable> where T.RawValue == String {
    let storage: T
    
    init<U: CustomStringConvertible>(_ value: U) {
        storage = T(rawValue: value.description)!
    }
}

enum Bar: String, CustomStringConvertible {
    case foobar = "foo"
    
    var description: String {
        return self.rawValue
    }
}

let a = Foo<Bar>(Bar.foobar)
```

Does this specialization specialize the struct's or the initializer's generic type? The proposal solves this ambiguity by requiring initializer generic type specialization to use the `init` syntax:

```swift
let a = Foo<Bar>.init<Bar>(Bar.foobar)
```

## Detailed Design

The proposal modifies the grammar to allow function call and initizations to have all of their generic types explicitly specified inside angle brackets.

Function calls are fairly straight forward and have their grammar modified as follows:

*function-call-expression* → *postfix-expression­* *generic-argument-clause<sub>­opt</sub>* *parenthesized-expression*

*function-call-expression* → *postfix-expression* *generic-argument-clause<sub>­opt</sub>* *­parenthesized-expression<sub>­opt</sub>* *­trailing-closure­*

To allow initializers to be called with explicit specialization, we need to use the Initializer Expression. Its grammar is modified to:

*initializer-expression* → *postfix-expression­* **.** *­init­* *generic-argument-clause<sub>­opt</sub>*

*initializer-expression* → *postfix-expression­* **.** *­init­* *generic-argument-clause<sub>­opt</sub>* **(** *­argument-names­* **)**

## Impact on Existing Code

This proposal is purely additive and will have no impact on existing code.

## Alternatives Considered

Not adopting this proposal for Swift.