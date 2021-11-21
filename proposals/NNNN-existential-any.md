# Introduce existential `any`

* Proposal: [SE-NNNN](NNNN-existential-any.md)
* Authors: [Holly Borla](https://github.com/hborla)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#40282](https://github.com/apple/swift/pull/40282)

## Introduction

Existential types in Swift have an extremely lightweight spelling: a plain protocol name in type context means an existential type. Over the years, this has risen to the level of **active harm** by causing confusion, leading programmers down the wrong path that often requires them to re-write code once they hit a fundamental [limitation of value-level abstraction](https://forums.swift.org/t/improving-the-ui-of-generics/22814#heading--limits-of-existentials). This proposal makes the impact of existential types explicit in the language by annotating such types with `any`.

## Motivation

Existential types in Swift have significant limitations and performance implications. Some of their limitations are missing language features, but many are fundamental to their type-erasing semantics. For example, given a protocol with associated type requirements, the existential type cannot conform to the protocol itself without a manual conformance implementation, because there is not an obvious concrete associated type that works for any value conforming to the protocol, as shown by the following example:

```swift
protocol P {
  associatedtype A
  func test(a: A)
}

func generic<ConcreteP: P>(p: ConcreteP, value: ConcreteP.A) {
  p.test(a: value)
}

func useExistential(p: P) {
  generic(p: p, value: ???) // what type of value would P.A be??
}
```

Existential types are also significantly more expensive than using concrete types. Because they can store any value whose type conforms to the protocol, and the type of value stored can change dynamically, existential types require dynamic memory unless the value is small enough to fit within an inline 3-word buffer. In addition to heap allocation and reference counting, code using existential types incurs pointer indirection and dynamic method dispatch that cannot be optimized away.

Despite these significant and often undesirable implications, existential types have a minimal spelling. Syntactically, the cost of using one is hidden, and the similar spelling to generic constraints has caused many programmers to confuse existential types with generics. In reality, the need for the dynamism they provided is relatively rare compared to the need for generics, but the language makes existential types too easy to reach for, especially by mistake. The cost of using existential types should not be hidden, and programmers should explicitly opt into these semantics.

## Proposed solution

I propose to make existential types syntactically explicit in the language using the `any` keyword. This proposal introduces the new syntax, and this syntax should be required under the Swift 6 language mode.

## Detailed design

### Grammar of explicit existential types

This proposal adds the following production rules to the grammar of types:

```
type -> existential-type

existential-type -> 'any' type
```

### Semantics of explicit existential types

The semantics of `any` types are the same as existential types today. Explicit `any` can only be applied to protocols and protocol compositions; `any` cannot be applied to nominal types, structural types, and type parameters:

```swift
struct S {}

let s: any S = S() // error: 'any' has no effect on concrete type 'S'

func generic<T>(t: T) {
  let x: any T = t // error: 'any' has no effect on type parameter 'T'
}
```

`any` also cannot be applied to `Any` and `AnyObject` (unless part of a protocol composition).


> Rationale: `any Any` and `any AnyObject` are redundant. `Any` and `AnyObject` are already special types in the language, and their existence isn’t nearly as harmful as existential types for regular protocols because the type-erasing semantics is already explicit in the name.


The existential metatype becomes `(any P).Type`, and the protocol metatype remains `P.Protocol`.

Examples

```swift
protocol P {}
class C {}

any P
any Any           // error
any AnyObject     // error
any P & AnyObject
any C             // error
any P & C
any () -> Void    // error

(any P).Type

func test<T>(_: T) where T == any P
```

## Source compatibility

Enforcing that existential types use the `any` keyword will require a source change. To ease the migration, I propose to start allowing existential types to be spelled with `any` with the Swift 5.6 compiler, and require existential types to be spelled with `any` under the Swift 6 language mode. The old existential type syntax will continue to be supported under the Swift 5 language mode, and the transition to the new syntax is mechanical, so it can be performed automatically by a migrator.

[SE-0306 Unlock existentials for all protocols](https://github.com/apple/swift-evolution/blob/main/proposals/0309-unlock-existential-types-for-all-protocols.md) enables more code to be written using existential types. To minimize the amount of new code written that will become invalid in Swift 6, I propose requiring `any` immediately for protocols with `Self` and associated type requirements. This introduces an inconsistency for protocols under the Swift 5 language mode, but this inconsistency already exists today (because you cannot use certain protocols as existential types at all), and the syntax difference serves two purposes:

1. It saves programmers time in the long run by preventing them from writing new code that will become invalid later.
2. It communicates the existence of `any` and encourages programmers to start using it for other existential types before adopting Swift 6.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

Instead of leaving `Any` and `AnyObject` in their existing spelling, an alternative is to spell these types as `any Value` and `any Object`, respectively. Though this is more consistent with the rest of the proposal, this change would have an even bigger source compatibility impact. Given that `Any` and `AnyObject` aren’t as harmful as other existential types, changing the spelling isn’t worth the churn.

## Future Directions

### Extending existential types

This proposal provides an obvious syntax for extending existential types in order to manually implement protocol conformances:

```swift
extension any Equatable: Equatable { ... }
```

### Re-purposing the plain protocol name

In other places in the language, a plain protocol name is already sugar for a type parameter conforming to the protocol. Consider a normal protocol extension:

```swift
extension Collection { ... }
```

This extension is a form of universal quantification; it extends all types that conform to `Collection`. This extension introduces a generic context with a type parameter `<Self: Collection>`, which means the above syntax is effectively sugar for a parameterized extension:

```swift
extension <Self> Self where Self: Collection { ... }
```

Changing the syntax of existential types creates an opportunity to expand upon this sugar. If existential types are spelled explicitly with `any`, a plain protocol name could always mean sugar for a type parameter on the enclosing context with a conformance requirement to the protocol. For example, consider the declaration of `append(contentsOf:)` from the standard library:

```swift
extension Array {
  mutating func append<S: Sequence>(contentsOf newElements: S) where S.Element == Element
}
```

Combined with a syntax for constraining associated types in angle brackets, such as in [[Pitch] Light-weight same-type constraint syntax](https://forums.swift.org/t/pitch-light-weight-same-type-constraint-syntax/52889), the above declaration could be simplified to:

```swift
extension Array {
  mutating func append(contentsOf newElements: Sequence<Element>)
}
```

This sugar eliminates a lot of noise in cases where a type parameter is only referred to once in a generic signature, and it enforces a natural model of abstraction, where programmers only need to name an entity when they need to refer to it multiple times.

## Acknowledgments

Thank you to Joe Groff, who originally suggested this direction and syntax in [Improving the UI of generics](https://forums.swift.org/t/improving-the-ui-of-generics/22814), and to those who advocated for this change in the recent discussion about [easing the learning curve for generics](https://forums.swift.org/t/discussion-easing-the-learning-curve-for-introducing-generic-parameters/52891).
