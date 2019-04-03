# Introduce callables

* Proposal: [SE-0253](https://github.com/apple/swift-evolution/blob/master/proposals/0253-callable.md)
* Authors: [Richard Wei](https://github.com/rxwei), [Dan Zheng](https://github.com/dan-zheng)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Active review (March 27 - April 5, 2019)**
* Implementation: [apple/swift#23517](https://github.com/apple/swift/pull/23517)

## Introduction

Note: throughout this document, let "call-syntax" refer to the syntax of applying a function to arguments: `f(x, y, z)`.

This proposal introduces [callables](https://en.wikipedia.org/wiki/Callable_object) to Swift. Callables are values that define function-like behavior and can be applied using function application syntax.

In a nutshell, we propose to introduce a new declaration syntax with the keyword `call`:

```swift
struct Adder {
    var base: Int
    call(_ x: Int) -> Int {
        return base + x
    }
}
```

Values that have a `call` member can be applied like functions, forwarding arguments to the `call` member.

```swift
let add3 = Adder(base: 3)
add3(10) // => 13
```

## Motivation

Currently, in Swift, only a few kinds of values are syntactically callable:
- Values with function types.
- Type names (e.g. `T` can be called like `T(...)`, which is desugared to `T.init(...)`).
- Values with a `@dynamicCallable` type.

However, call-syntax can also be useful for other values, primarily those that behave like functions. This includes:
- Values that represent functions: mathematical functions, function expressions, etc.
- Values that have one main use and want to provide a simple call-syntax interface: neural network layers, parsers, efficient bound closures, etc.

Here are some concrete sources of motivation.

### Values representing functions

Values of some nominal types exactly represent functions: in the mathematical sense (a mapping from inputs to outputs), or in the context of programming languages.

Here are some examples:

```swift
/// Represents a polynomial function, e.g. `2 + 3x + 4x²`.
struct Polynomial {
    /// Represents the coefficients of the polynomial, starting from power zero.
    let coefficients: [Float]
}
```

Since these types represent functions, naturally they can be applied to inputs. However, currently in Swift, the "function application" functionality must be defined as a method.

```swift
extension Polynomial {
    func evaluated(at input: Float) -> Float {
        var result: Float = 0
        for (i, c) in coefficients.enumerated() {
            result += c * pow(input, Float(i))
        }
        return result
    }
}

let polynomial = Polynomial(coefficients: [2, 3, 4])
print(polynomial.evaluated(at: 2)) // => 24
```

The mathematical notation for function application is simply `output = f(input)`. Using subscript methods achieve a similar application syntax `f[x]`, but subscripts and square brackets typically connote "indexing into a collection", which is not the behavior here.

```swift
extension Polynomial {
    subscript(input: Float) -> Float {
        ...
    }
}
let polynomial = Polynomial(coefficients: [2, 3, 4])
// Subscript syntax, may be confusing.
print(polynomial[2]) // => 24
```

The proposed feature enables the same call syntax as the mathematical notation:
```swift
extension Polynomial {
    call(_ input: Float) -> Float {
        ...
    }
}
let polynomial = Polynomial(coefficients: [2, 3, 4])
// Call syntax.
print(polynomial(2)) // => 24
```

#### Bound closures

Variable-capturing closures can be modeled explicitly as structs that store the bound variables. This representation is more performant and avoids the type-erasure of closure contexts.

```swift
// Represents a nullary function capturing a value of type `T`.
struct BoundClosure<T> {
    var function: (T) -> Void
    var value: T

    call() { return function(value) }
}

let x = "Hello world!"
let closure = BoundClosure(function: { print($0) }, value: x)
closure() // prints "Hello world!"
```

A call syntax sugar would enable `BoundClosure` instances to be applied like normal functions.

### Nominal types with one primary method

Some nominal types have a "primary method" that performs their main use. For example:

* Calculators *calculate*: `calculator.calculating(query)`.
* Parsers *parse*: `parser.parsing(text)`.
* Neural network layers *apply to inputs*: `layer.applied(to: input)`.
* Types representing functions *apply to arguments*: `function.applied(to: arguments)`.

Types that have a primary method usually call that method frequently. Thus, it may be desirable to sugar applications of the main method with call syntax to reduce noise.

Let's explore neural network layers and string parsers in detail.

#### Neural network layers

[Machine learning](https://en.wikipedia.org/wiki/Machine_learning) models often represent a function that contains an internal state called "trainable parameters", and the function takes an input and predicts the output. In code, models are often represented as a data structure that stores trainable parameters, and a method that defines the transformation from an input to an output in terms of these trained parameters. Here's an example:

```swift
struct Perceptron {
    var weight: Vector<Float>
    var bias: Float

    func applied(to input: Vector<Float>) -> Float {
        return weight • input + bias
    }
}
```

Stored properties `weight` and `bias` are considered as trainable parameters, and are used to define the transformation from model inputs to model outputs. Models can be [trained ](https://developers.google.com/machine-learning/glossary/#training), during which parameters like `weight` are updated, thus changing the behavior of `applied(to:)`. When a model is used, the call site looks just like a function call.

```swift
let model: Perceptron = ...
let ŷ = model.applied(to: x)
```

Many deep learning models are composed of layers, or layers of layers. In the definition of those models, repeated calls to `applied(to:)` significantly complicate the look of the program and reduce the clarity of the resulting code.

```swift
struct Model {
    var conv = Conv2D<Float>(filterShape: (5, 5, 3, 6))
    var maxPool = MaxPool2D<Float>(poolSize: (2, 2), strides: (2, 2))
    var flatten = Flatten<Float>()
    var dense = Dense<Float>(inputSize: 36 * 6, outputSize: 10)

    func applied(to input: Tensor<Float>) -> Tensor<Float> {
        return dense.applied(to: flatten.applied(to: maxPool.applied(to: conv.applied(to: input))))
    }
}
```

These repeated calls to `applied(to:)` harm clarity and makes code less readable. If `model` could be called like a function, which it mathematically represents, the definition of `Model` becomes much shorter and more concise. The proposed feature [promotes clear usage by omitting needless words](https://swift.org/documentation/api-design-guidelines/#promote-clear-usage).

```swift
struct Model {
    var conv = Conv2D<Float>(filterShape: (5, 5, 3, 6))
    var maxPool = MaxPool2D<Float>(poolSize: (2, 2), strides: (2, 2))
    var flatten = Flatten<Float>()
    var dense = Dense<Float>(inputSize: 36 * 6, outputSize: 10)

    call(_ input: Tensor<Float>) -> Tensor<Float> {
        // Call syntax.
        return dense(flatten(maxPool(conv(input))))
    }
}

let model: Model = ...
let ŷ = model(x)
```

There are more ways to further simplify model definitions, but making models callable like functions is a good first step.

#### Domain specific languages

DSL constructs like string parsers represent functions from inputs to outputs. Parser combinators are often implemented as higher-order functions operating on parser values, which are themselves data structures—some implementations store closures, while some other [efficient implementations ](https://infoscience.epfl.ch/record/203076/files/p637-jonnalagedda.pdf) store an expression tree. They all have an "apply"-like method that performs an application of the parser (i.e. parsing).

```swift
struct Parser<Output> {
    // Stored state...

    func applied(to input: String) throws -> Output {
        // Using the stored state...
    }

    func many() -> Parser<[Output]> { ... }
    func many<T>(separatedBy separator: Parser<T>) -> Parser<[Output]> { ... }
}
```

When using a parser, one would need to explicitly call `applied(to:)`, but this is a bit cumbersome—the naming this API often repeats the type. Since parsers are like functions, it would be cleaner if the parser itself were callable.

```swift
call(_ input: String) throws -> Output {
    // Using the stored state...
}
```

```swift
let sexpParser: Parser<Expression> = ...
// Call syntax.
let sexp = sexpParser("(+ 1 2)")
```

### A static counterpart to `@dynamicCallable`

[SE-0216 ](https://github.com/apple/swift-evolution/blob/master/proposals/0216-dynamic-callable.md) introduced user-defined dynamically callable values. In its [alternatives considered](https://github.com/apple/swift-evolution/blob/master/proposals/0216-dynamic-callable.md#alternatives-considered) section, it was requested that we design and implement the "static callable" version of this proposal in conjunction with the dynamic version proposed. See its [pitch thread](https://forums.swift.org/t/pitch-3-introduce-user-defined-dynamically-callable-types/12232) for discussions about "static callables".

### Prior art

Many languages offer the call syntax sugar:

* Python: [ `object.__call__(self[, args...])` ](https://docs.python.org/3/reference/datamodel.html#emulating-callable-objects)
* C++: [ `operator()` (function call operator)](https://en.cppreference.com/w/cpp/language/operators)
* Scala: [ `def apply(...)` (apply methods) ](https://twitter.github.io/scala_school/basics2.html#apply)

### Unifying compound types and nominal types

A long term goal with the type system is to unify compound types (e.g. function types and tuple types) and nominal types, to allow compound types to conform to protocols and have members. When function types can have members, it will be most natural for them to have a `call` member, which can help unify the compiler's type checking rules for call expressions.

## Proposed design

We propose to introduce a new keyword `call` and a new declaration syntax–the call declaration syntax.

```swift
struct Adder {
    var base: Int
    call(_ x: Int) -> Int {
        return base + x
    }
}
```

Values that have a `call` member can be called like a function, forwarding arguments to the `call` member.

```swift
let add3 = Adder(base: 3)
add3(10) // => 13
```

Note: there are many alternative syntaxes for marking "call-syntax delegate
methods". These are listed and explored in the ["Alternatives
considered"](#alternative-ways-to-denote-call-syntax-delegate-methods) section.

## Detailed design

### `call` member declarations

`call` members can be declared in structure types, enumeration types, class types, protocols, and extensions thereof.

A `call` member declaration is similar to `subscript` in the following ways:

* It does not take a name.
* It must be an instance member of a type. (Though there is [a pitch to add
  static and class subscripts][static-and-class-subscripts].)

But it is more similar to a `func` declaration in that:

* It does not allow `get` and `set` declarations inside the body.
* When a parameter has a name, the name is treated as the argument label.
* It can be referenced directly by name, e.g. `foo.call`.

The rest of the `call` declaration grammar and semantics is identical to that of
function declarations – it supports the same syntax for:
- Access levels.
- Generic parameter clauses.
- Argument labels.
- Return types.
- `throws` and `rethrows`.
- `mutating`.
- `where` clauses.

`call` declarations can be overloaded based on argument and result types.
`call` declarations are inherited from superclasses, just like other class members.
Most modifiers/attributes that can be applied to function declarations can also be applied to
`call` declarations.

<details>
<summary>Click here for a comprehensive list of modifiers/attributes supported by <code>call</code> declarations.</summary>

<br>

Preface: `call` declarations are implemented as a `CallDecl` class, inheriting
from `FuncDecl`, which in tern inherits from `AbstractFunctionDecl`.

### Supported modifiers/attributes on `call` declarations

The following attributes are supported on `AbstractFunctionDecl` or all
declarations, and thus by default are supported on `call` declarations.
(Disabling these attributes on `call` declarations is possible, but may require
ad-hoc implementation changes.)

* `fileprivate`, `internal`, `public`, `open`
* `@available`
* `@objc`
* `@inlinable`
* `@inline`
* `@usableFromInline`
* `@_alwaysEmitIntoClient`
* `@_dynamicReplacement`
* `@_effects`
* `@_forbidSerializingReference``
* `@_optimize`
* `@_silgen_name`
* `@_semantics`
* `@__raw_doc_comment`

The following attributes are supported on `FuncDecl`, and are also are supported on `call` declarations.

* `final`
* `optional`
* `dynamic`
* `__consuming`
* `mutating`
* `nonmutating`
* `override`
* `private`
* `rethrows`
* `@discardableResult`
* `@nonobjc`
* `@_cdecl`
* `@_implements`
* `@_implicitly_unwrapped_optional`
* `@_nonoverride`
* `@_specialize_`
* `@_transparent`
* `@_weakLinked`

### Notable unsupported modifiers/attributes on `call` declarations

* `@warn_unqualified_access`
  * It would be weird to require qualified access (e.g. `self.call` in another
    member) for `call` members, given their purpose as a call-syntax delegate
    method.

</details>
<br>

To support source compatibility, `call` is treated as a keyword only when
parsing members of a nominal type. Otherwise, it is treated as a normal
identifier. See the source compatibility section below.

```
call-declaration → call-head generic-parameter-clause? function-signature generic-where-clause? function-body?
call-head → attributes? declaration-modifiers? 'call'
```

#### Examples

```swift
struct Adder {
    var base: Int

    call(_ x: Int) -> Int {
        return base + x
    }

    call(_ x: Float) -> Float {
        return Float(base) + x
    }

    call<T>(_ x: T, bang: Bool) throws -> T where T: BinaryInteger {
        if bang {
            return T(Int(exactly: x)! + base)
        } else {
            return T(Int(truncatingIfNeeded: x) + base)
        }
    }
   
    // This is a normal function, not a `call` member.
    func call(x: Int) {}
}
```

### Call expressions

When type-checking a call expression, the type checker will try to resolve the callee. Currently, the callee can be a value with a function type, a type name, or a value of a `@dynamicCallable` type. This proposal adds a fourth kind of a callee: a value with a matching `call` member.

```swift
let add1 = Adder(base: 1)
add1(2) // => 3
try add1(4, bang: true) // => 5
```

When type-checking fails, error messages look like those for function calls. When there is ambiguity, the compiler will show relevant `call` member candidates.

```swift
add1("foo")
// error: cannot invoke 'add1' with an argument list of type '(String)'
// note: overloads for 'call' exist with these partially matching parameter lists: (Float), (Int)
add1(1, 2, 3)
// error: cannot invoke 'add1' with an argument list of type '(Int, Int, Int)'
```

### When the type is also `@dynamicCallable`

A type can both have `call` members and be declared with `@dynamicCallable`. When type-checking a call expression, the type checker will first try to resolve the call to a function or initializer call, then a `call` member call, and finally a dynamic call.

### Direct reference to a `call` member

Like methods and initializers, a `call` member can be directly referenced, either through the base name and the contextual type, or through the full name.

```swift
let add1 = Adder(base: 1)
let f: (Int) -> Int = add1.call
f(2) // => 3
[1, 2, 3].map(add1.call) // => [2, 3, 4]
```

When a type has both an instance method named "call" and a `call` member with the exact same type signature, a redeclaration error is produced.

```swift
struct S {
    func call() {}
    call() {}
}
```

```console
test.swift:3:5: error: invalid redeclaration of 'call()'
    call() {}
    ^
test.swift:2:10: note: 'call()' previously declared here
    func call() {}
         ^
```

When a type does not have a `call` member but has an instance method or an instance property named "call", a direct reference to `call` gets resolved to that member.

```swift
struct S {
    var call: Int = 0
}
S().call // resolves to the property
```

A value cannot be implicitly converted to a function when the destination function type matches the type of the `call` member.

```swift
let h: (Int) -> Int = add1 // error: cannot convert value of type `Adder` to expected type `(Int) -> Int`
```

Implicit conversions are generally problematic in Swift, and as such we would like to get some experience with this base proposal before considering adding such capability.

## Source compatibility

The proposed feature adds a `call` keyword. Normally, this would require existing identifiers named "call" to be escaped as `` `call` ``. However, this would break existing code using `call` identifiers, e.g. `func call`.

To maintain source compatibility, we propose making `call` a contextual keyword: that is, it is a keyword only in declaration contexts and a normal identifier elsewhere (e.g. in expression contexts). This means that `func call` and `call(...)` (apply expressions) continue to parse correctly.

Here's a comprehensive example of parsing `call` in different contexts:

```swift
struct Callable {
    // declaration
    call(_ body: () -> Void) {
        // expression
        call() {}
        // expression
        call {}

        struct U {
            // declaration
            call(x: Int) {}

            // declaration
            call(function: (Int) -> Void) {}

            // error: expression in declaration context
            // expected '(' for 'call' member parameters
            call {}
        }

        let u = U()
        // expression
        u { x in }
    }
}

// expression
call() {}
// expression
call {}
```

## Effect on ABI stability

This proposal is about a syntactic sugar and has no ABI breaking changes.

## Effect on API resilience

This proposal is about a syntactic sugar and has no API breaking changes.

## Alternatives considered

### Alternative ways to denote call-syntax delegate methods

#### Use unnamed `func` declarations to mark call-syntax delegate methods

```swift
struct Adder {
    var base: Int
    // Option: unnamed `func`.
    func(_ x: Int) -> Int {
        return base + x
    }
    // Option: `call` declaration modifier on unnamed `func` declarations.
    // Makes unnamed `func` less weird and clearly states "call".
    call func(_ x: Int) -> Int { ... }
}
```

This approach represents call-syntax delegate methods as unnamed `func` declarations instead of creating a new `call` declaration kind.

One option is to use `func(...)` without an identifier name. Since the word "call" does not appear, it is less clear that this denotes a call-syntax delegate method. Additionally, it's not clear how direct references would work: the proposed design of referencing `call` declarations via `foo.call` is clear and consistent with the behavior of `init` declarations.

To make unnamed `func(...)` less weird, one option is to add a `call` declaration modifier: `call func(...)`. The word `call` appears in both this option and the proposed design, clearly conveying "call-syntax delegate method". However, declaration modifiers are currently also treated as keywords, so with both approaches, parser changes to ensure source compatibility are necessary. `call func(...)` requires additional parser changes to allow `func` to sometimes not be followed by a name. The authors lean towards `call` declarations for terseness.

#### Use an attribute to mark call-syntax delegate methods

```swift
struct Adder {
    var base: Int
    @callDelegate
    func addingWithBase(_ x: Int) -> Int {
        return base + x
    }
}
```

This approach achieves a similar effect as `call` declarations, except that methods can have a custom name and be directly referenced by that name. This is useful for types that want to make use of the call syntax sugar, but for which the name "call" does not accurately describe the callable functionality.

However, we feel that using a `@callableMethod` method attribute is more noisy. Introducing a `call` declaration kind makes the concept of "callables" feel more first-class in the language, just like subscripts. `call` is to `()` as `subscript` is to `[]`.

For reference: other languages with callable functionality typically require call-syntax delegate methods to have a particular name (e.g. `def __call__` in Python, `def apply` in Scala).

#### Use `func` with a special name to mark call-syntax delegate methods

```swift
struct Adder {
    var base: Int
    // Option: specially-named `func` declarations.
    func _(_ x: Int) -> Int
    func self(_ x: Int) -> Int
}
```

This approach represents call-syntax delegate methods as `func` declarations with a special name instead of creating a new `call` declaration kind. However, such `func` declarations do not convey "call-syntax delegate method" as clearly as the `call` keyword.

Also, we want to support direct references to call-syntax delegate methods via `foo.call`. This makes more sense when call-syntax delegate methods are declared with the `call` keyword, and is consistent with `init` declarations and direct references (e.g. `foo.init`).

#### Use a type attribute to mark types with call-syntax delegate methods

```swift
@staticCallable // alternative name `@callable`; similar to `@dynamicCallable`
struct Adder {
    var base: Int
    // Informal rule: all methods with a particular name (e.g. `func call`) are deemed call-syntax delegate methods.
    //
    // `StringInterpolationProtocol` has a similar informal requirement for
    // `func appendInterpolation` methods.
    // https://github.com/apple/swift-evolution/blob/master/proposals/0228-fix-expressiblebystringinterpolation.md#proposed-solution
    func call(_ x: Int) -> Int {
        return base + x
    }
}
```

We feel this approach is not ideal because:

* A marker type attribute is not particularly meaningful. The call-syntax
  delegate methods of a type are what make values of that type callable - a type
  attribute means nothing by itself. There's an unforunate edge case that must
  be explicitly handled: if a `@staticCallable` type defines no call-syntax
  delegate methods, an error must be produced.
* The name for call-syntax delegate methods (e.g. `func call` ) is not first-class in the language, while their call site syntax is.

#### Use a `Callable` protocol to represent callable types

```swift
// Compiler-known `Callable` marker protocol.
struct Adder: Callable {
    var base: Int
    // Informal rule: all methods with a particular name (e.g. `func call`) are deemed call-syntax delegate methods.
    func call(_ x: Int) -> Int {
        return base + x
    }
}
```

We feel this approach is not ideal for the same reasons as the marker type attribute. A marker protocol by itself is not meaningful and the name for call-syntax delegate methods is informal. Additionally, protocols should represent particular semantics, but "callable" behavior has no inherent semantics.

In comparison, `call` declarations have a formal representation in the language and exactly indicate callable behavior (unlike a marker attribute or protocol).

### Property-like `call` with getter and setter

In C++, `operator()` can return a reference, which can be used on the left hand side of an assignment expression. This is used by some DSLs such as [Halide](http://halide-lang.org/docs/class_halide_1_1_func.html):

```swift
Halide::Func foo;
Halide::Var x, y;
foo(x, y) = x + y;
```

This can be achieved via Swift's subscripts, which can have a getter and a setter.

```swift
foo[x, y] = x + y
```

Since the proposed `call` declaration syntax is like `subscript` in many ways, it's in theory possible to allow `get` and `set` in a `call` declaration's body.

```swift
call(x: T) -> U {
    get {
        ...
    }
    set {
        ...
    }
}
```

However, we do not believe `call` should behave like a storage accessor like `subscript`. Instead, `call`'s appearance should be as close to function calls as possible. Function call expressions today are not assignable because they can't return an l-value reference, so a call to a `call` member should not be assignable either.

### Static `call` members

Static `call` members could in theory look like initializers at the call site.

```swift
extension Adder {
    static call(base: Int) -> Int {
        ...
    }
    static call(_ x: Int) -> Int {
        ...
    }
}
Adder(base: 3) // error: ambiguous static member; do you mean `init(base:)` or `call(base:)`?
Adder(3) // okay, returns an `Int`, but it looks really like an initializer that returns an `Adder`.
```

We believe that the initializer call syntax in Swift is baked tightly into programmers' mental model, and thus do not think overloading that is a good idea.

We could also make it so that static `call` members can only be called via call expressions on metatypes.

```swift
Adder.self(base: 3) // okay
```

But since this would be an additive feature on top of this proposal and that `subscript` cannot be `static` yet, we'd like to defer this feature to future discussions.

### Unify callable functionality with `@dynamicCallable`

Both `@dynamicCallable` and the proposed `call` members involve syntactic sugar related to function applications. However, the rules of the sugar are different, making unification difficult. In particular, `@dynamicCallable` provides a special sugar for argument labels that is crucial for usability.

```swift
// Let `PythonObject` be a `@dynamicMemberLookup` type with callable functionality.
let np: PythonObject = ...
// `PythonObject` with `@dynamicCallable.
np.random.randint(-10, 10, dtype: np.float)
// `PythonObject` with `call` members. The empty strings are killer.
np.random.randint(["": -10, "": 10, "dtype": np.float])
```

[static-and-class-subscripts]: https://forums.swift.org/t/pitch-static-and-class-subscripts/21850 
