# Extend implicit member syntax to cover chains of member references

* Proposal: [SE-NNNN](NNNN-implicit-member-chains.md)
* Authors: [Frederick Kellison-Linn](https://github.com/jumhyn)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#31679](https://github.com/apple/swift/pull/31679)

## Introduction

When the type of an expression is implied by the context, Swift allows developers to use what is formally referred to as an "implicit member expression," sometimes referred to as "leading dot syntax":

```swift
class C {
    static let zero = C(0)
    var x: Int

    init(_ x: Int) {
        self.x = x
    }
}

func f(_ c: C) {
    print(c.x)
}

f(.zero) // prints '0'
```

This allows for the omission of repetitive type information in contexts where the type information is already obvious to the reader:
```swift
view.backgroundColor = .systemBackground
```

This proposal suggests the expansion of implicit member syntax to more complex expressions than just a single static member or function. Specifically, implicit member syntax would be allowed to cover chains of member references.

## Motivation

Today, attempting to use implicit member syntax with a chain of member references fails:

```swift
extension C {
    var incremented: C {
        return C(self.x + 1)
    }
}

f(.zero.incremented) // Error: Type of expression is ambiguous without more context
```

This error breaks the mental model that many users likely have for implicit member syntax, which boils down to a simple lexical omission of the type name in contexts where the type is clear. I.e., users expect that writing:

```swift
let one: C = .zero.incremented
```

is just the same as writing

```swift
let one = C.zero.incremented
```

This issue arises in practice with any type that offers "modifier" methods that vend updated instances according to some rule. For example, `UIColor` offers the `withAlphaComponent(_:)` modifier for constructing new colors, which cannot be used with implicit member syntax:

```swift
let milky: UIColor = .white.withAlphaComponent(0.5) // error
```

## Proposed solution

Improve in order to be able to handle multiple chained member accesses. The type of the resulting expression would be constrained to match the contextual type. Under this proposal, all of the following would successfully typecheck:

```swift
let milky: UIColor = .white.withAlphaComponent(0.5)
let milky2: UIColor = .init(named: "white")!.withAlphaComponent(0.5)
let milkyChance: UIColor? = .init(named: "white")?.withAlphaComponent(0.5)

struct Foo {
    static var foo = Foo()
    
    var anotherFoo: Foo { Foo() }
    func getFoo() -> Foo { Foo() }
    var optionalFoo: Foo? { Foo() }
    var fooFunc: () -> Foo { Foo() }
    var optionalFooFunc: () -> Foo? { { Foo() } }
    var fooFuncOptional: (() -> Foo)? { { Foo() } }
    subscript(arg: Void) -> Foo() { Foo() }
}

let _: Foo = .foo.anotherFoo
let _: Foo = .foo.anotherFoo.anotherFoo.anotherFoo.anotherFoo
let _: Foo = .foo.getFoo()
let _: Foo = .foo.optionalFoo!.getFoo()
let _: Foo = .foo.fooFunc()
let _: Foo = .foo.optionalFooFunc()!
let _: Foo = .foo.fooFuncOptional!()
let _: Foo = .foo.optionalFoo
let _: Foo = .foo[()]
let _: Foo = .foo.anotherFoo[()]
let _: Foo = .foo.fooFuncOptional!()[()]

struct Bar {
    var anotherFoo = Foo()
}

extension Foo {
    static var bar = Bar()
    var anotherBar: Bar { Bar() }
}

let _: Foo = .bar.anotherFoo
let _: Foo = .foo.anotherBar.anotherFoo
```

## Detailed design

This proposal would provide the model mentioned earlier for implicit member expressions: anywhere that a contextual type `T` can be inferred, writing

```swift
.member1.member2.(...).memberN
```

Will behave as if the user had written:

```swift
T.member1.member2.(...).memberN
```

Members of this "implicit member chain" can be any of the following:
- Property references
- Method calls
- Force unwraping expressions
- Optional-chaining question marks
- Subscripts

When any of the above is encountered by the type checker, it will determine two things:

1. Whether this expression sits at the tail of the chain.
2. Whether the base of the chain is an implicit member expression.

If those two conditions are met, then a constraint is introduced requiring the result of the whole chain to equal the type of the base of the implicit member expression.

Members of the chain are allowed to participate in generic parameter inference as well. Thus, the following code is valid:

```swift
struct Foo<T> {
    static var foo: Foo<T> { Foo<T>() }
    var anotherFoo: Foo<T> { Foo<T>() }
    func getAnotherFoo() -> Foo<T> {
        Foo<T>()
    }
}

extension Foo where T == Int {
    static var fooInt: Foo<Int> { Foo<Int>() }
    var anotherFooInt: Foo<Int> { Foo<Int>() }
    var anotherFooIntString: Foo<String> { Foo<String>() }
    func getAnotherFooInt() -> Foo<Int> {
        Foo<Int>()
    }
}

extension Foo where T == String {
    var anotherFooStringInt: Foo<Int> { Foo<Int>() }
}

func implicit<T>(_ arg: Foo<T>) {}

// T inferred as Foo<Int> in all of the following
implicit(.fooInt)
implicit(.foo.anotherFooInt)
implicit(.foo.anotherFooInt.anotherFoo)
implicit(.foo.anotherFoo.anotherFooInt)
implicit(.foo.getAnotherFooInt())
implicit(.foo.anotherFoo.getAnotherFooInt())
implicit(.foo.getAnotherFoo().anotherFooInt)
implicit(.foo.getAnotherFooInt())
implicit(.foo.getAnotherFoo().getAnotherFooInt())
// Members types along the chain can have different generic arguments
implicit(.foo.anotherFooIntString.anotherFooStringInt)
```

If `T` is the contextually inferred type but `memberN` has non-convertible type `R` , a diagnostic of the form:

```swift
Error: Cannot convert value of type 'R' to expected type 'T'
```

will be produced. The exact form of the diagnostic will depend on how `T` was contextually inferred (e.g. as an argument, as an explicit type annotation, etc.).

## Source compatibility

This is a purely additive change and does not have any effect on source compatibility.

## Effect on ABI stability

This change is frontend only and would not impact ABI.

## Effect on API resilience

This is not an API-level change and would not impact resilience.

## Alternatives considered

# Require homogeneously-typed chains

While overall discussion around this feature was very positive, one point of minor disagreement was whether chains should be required to have the same typealong the length of the chain. Such a rule would prohibit constructs like this:

```swift
struct S {
    static var foo = T()
}

struct T {
    var bar = S()
}

let _: S = .foo.bar // error!
```

Proponents of this rule argued that the most common use case for these member chains (the aforementioned "modifier" or "builder" methods) doesn't require heterogeneously-typed chains, and that supporting them would introduce a cognitive load for readers of code that relies on heterogeneously-typed chains. 

A rule of this form was explored during implementation, but was abandoned for several reasons. One was simply that the implementation complexity would have been greatly increased in order to properly support the additional constraints along the chain while still offering helpful diagnostics. Another is that such a rule is far less flexible in situations that seem like they should work even with homogeneously-typed chains. For instance, allowing heterogeneously-typed chains easily enables the following syntax to compile:

```swift
struct HasClosure {
  static var factoryOpt: ((Int) -> HasClosure)? = { _ in .init() }
}

var _: HasClosure = .factoryOpt!(4)
```

Trying to support this construction with "homogeneously-typed chains" rule in place would require significantly more interaction between the different segments of the chain in order to decide whether certain constructions should be allowed.

Lastly, the author makes the subjective determination that such a rule would be at odds with the expectations of most users when using implicit member chains. Visually, implicit member chains appear very similar to keypath expressions, and indeed support all the same elements as keypath expressions (additionally supporting method/function calls). There is no such restriction that keypath expressions refer to the same type along their length (even when the keypath base type is omitted), so users may find it surprising that the compiler does not accept identical syntax for direct property accesses:

```swift
struct S {
    static var foo = T()
    var foo: T { T() }
}

struct T {
    var bar = S()
}

let _: KeyPath<S, S> = \.foo.bar
let _: S = .foo.bar // error?
```

