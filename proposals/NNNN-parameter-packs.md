# Parameter Packs

  - [Proposed solution](#proposed-solution)
  - [Detailed design](#detailed-design)
    - [Type parameter packs](#type-parameter-packs)
      - [Pack expansion type substitution](#pack-expansion-type-substitution)
      - [Requirements on type parameter packs](#requirements-on-type-parameter-packs)
      - [Same-length requirement inference](#same-length-requirement-inference)
      - [Open questions](#open-questions)
    - [Value parameter packs](#value-parameter-packs)
      - [**Iteration**](#iteration)
        - [Open questions](#open-questions-1)
    - [Labels](#labels)
    - [Ambiguities](#ambiguities)
      - [Pack expansion vs non-pack variadic parameter](#pack-expansion-vs-non-pack-variadic-parameter)
      - [Pack expansion vs postfix closed-range operator](#pack-expansion-vs-postfix-closed-range-operator)
      - [Pack expansion vs operator `...>`](#pack-expansion-vs-operator-)
  - [Effect on ABI stability](#effect-on-abi-stability)
  - [Alternatives considered](#alternatives-considered)
    - [Modeling packs as tuples with abstract elements](#modeling-packs-as-tuples-with-abstract-elements)
    - [Syntax alternatives to `...`](#syntax-alternatives-to-)
      - [Another operator](#another-operator)
      - [Pack declaration and expansion keywords](#pack-declaration-and-expansion-keywords)
      - [Magic builtin `map` method](#magic-builtin-map-method)
  - [Future directions](#future-directions)
    - [Value expansion operator](#value-expansion-operator)
    - [Local value packs](#local-value-packs)
    - [Pack destructuring operations](#pack-destructuring-operations)
    - [Tuple conformances](#tuple-conformances)
  - [Acknowledgments](#acknowledgments)

Generic functions and types in Swift currently require a fixed number of type parameters. It is not possible to write a function or type that accepts an arbitrary number of arguments with distinct types, instead requiring one of the following workarounds:

* Erasing all of the types involved, e.g. using `Any...`
* Using a single tuple type argument instead of separate type arguments
* Overloading for each argument length with an artificial limit

There are a number of examples of these workarounds in the Swift Standard Library alone, including `Zip2Sequence` / limiting `zip` to two arguments, and 6 overloads for each tuple comparison operator:

```swift
func zip<Sequence1, Sequence2>(
    _ sequence1: Sequence1,
    _ sequence2: Sequence2
) -> Zip2Sequence<Sequence1, Sequence2> where Sequence1 : Sequence, Sequence2 : Sequence
```

```swift
func < (lhs: (), rhs: ()) -> Bool

func < <A, B>(lhs: (A, B), rhs: (A, B)) -> Bool where A : Comparable, B : Comparable

func < <A, B, C>(lhs: (A, B, C), rhs: (A, B, C)) -> Bool where A : Comparable, B : Comparable, C : Comparable

// and so on, up to 6-element tuples
```

Similarly, the standard library’s `Regex` type has a single type parameter `Output`, and [`RegexComponentBuilder`](https://developer.apple.com/documentation/regexbuilder/regexcomponentbuilder) has 10+ overloads of the aggregate `build` methods that substitute `Output` with tuples of lengths 1-10.

All of these APIs that accept a variable number of arguments with distinct types could be expressed more naturally and concisely with language support for a variable number of type arguments.

## Proposed solution

This proposal adds *parameter packs* and *pack expansions* into Swift. Parameter packs introduce the fundamental concept of abstracting over a list of type parameters and corresponding value parameters. While this proposal is useful on its own, there are many future directions that build upon this concept. This is the first step toward equipping Swift programmers with a set of tools that enable variadic generic programming.

A _parameter pack_ is a parameter that represents a list of zero or more component parameters. A _type parameter pack_ represents zero or more type parameters, and a _value parameter pack_ represents zero or more value parameters.

Parameter packs can be expanded into positions that naturally accept a comma-separated list of types or values. A pack expansion flattens the elements in the pack into a comma-separated list, and elements can be appended to either side of a pack expansion by writing more values in the comma-separated list.

The following function uses parameter packs to prepend a value to the beginning of an arbitrary list of zero or more other values, returning the result in a tuple:

```
func prepend<First, Rest...>(value: First, to rest: Rest...) -> (First, Rest...) {
  return (value, rest...)
}
```

## Detailed design

### Type parameter packs

A type parameter pack is declared in a generic parameter list with an identifier followed by `...`:

```swift
struct HeterogeneousContainer<T...> {}
```

Recall that the following kinds of declarations may have a generic parameter list:

* Struct, enum, class and type alias declarations
* Function and subscript declarations

We will consider each of the two cases above separately.

A generic type can only have a single type parameter pack, because there is no way to delimit the type arguments in a specialization of this type:

```swift
struct MultiplePacks<T..., U...> {} // error

MultiplePacks<String, Int, Void> // Which types are bound to T... vs U...?
```

A generic type whose generic parameter list contains a type parameter pack accepts a variable number of generic arguments, which at a minimum must equal the number of non-pack type parameters. After consuming the prefix and suffix of length equal to the number of non-pack type parameters, all remaining generic arguments are collected into a *pack type* which becomes the generic argument for the pack parameter.

In this proposal, pack types will be denoted as a comma-separated list of types in curly braces, e.g. `{Int, String}`, but this proposal does not introduce such a syntax for writing pack types in the language itself; the syntax is purely for notational convenience.

Here is an example:

```swift
struct PackExample<T, U..., V> {} // PackExample needs at least 2 generic arguments

Pack<Int> // error: insufficient generic arguments
Pack<Int, String> // T := Int; U := {}; V := String
Pack<Int, Float, Double, String> // T := Int; U := {Float, Double}; V := String
```

A function may have multiple type parameter packs:

```swift
func multiplePacks<T..., U...>() {}
```

The generic arguments are inferred from the types of the argument expressions at the call site. Before explaining the rules, we need to introduce *pack expansion types*.

A reference to a type parameter pack can only appear in the following contexts:

* The pattern type of a pack expansion type
* A generic requirement; see [Requirements on type parameter packs](#requirements-on-type-parameter-packs)

A pack expansion type consists of a *pattern type* containing references to type parameter packs, followed by `...`.

Pack expansion types can appear in the following contexts:

* Generic arguments of a generic type, e.g. `Generic<T...>`
* Parameter types of a function declaration, e.g. `func foo<T...>(values: T...) -> Bool`
* Parameter types of a function type, e.g. `(T...) -> Bool`
* The elements of a tuple type, e.g. `(T...)`


Type argument substitutions for generic functions are inferred from the types of call argument expressions. In order for this inference to be unambiguous, the following restrictions are imposed:

* If the type of a function parameter is a pack expansion type, the parameter must either be the final parameter in the function’s parameter list, or it must be followed by another parameter with a label.
* If a pack expansion type appears inside of a tuple type, the pack expansion must either be the final element of the tuple type, or it must be followed by another element with a label.
* If a pack expansion type appears inside of a function type’s parameter list; it must be the only pack expansion type in the function’s parameter list. (This rule is slightly different from that of pack expansion types in the parameter of a *function declaration*, because function *types* cannot have argument labels.)

#### Pack expansion type substitution

A reference to a generic declaration is always formed together with a set of *substitutions* which map the type parameters of the declaration’s generic parameter list to *replacement types*. The replacement type of a type parameter pack is always a pack type.

The replacement pack types of each type parameter pack occurring inside a given pack expansion must have the same length; call this length `N`. This *same-length requirement* is enforced with generic requirements, as detailed below. The behavior of a pack expansion type under substitution is that the pattern type is repeated `N` times, and inside the pattern type, each reference to a type parameter pack is replaced with the `N`th element of the replacement pack type.

For example, consider this generic type alias with a type parameter pack `E`:

```swift
typealias G<E...> = (Array<E>...)
```

The underlying type of the type alias is a tuple type containing a pack expansion type. The pattern type of this pack expansion type is `Array<E>`. By the rules for generic types described above,  `G`  can be specialized with zero or more generic arguments. Consider the following specialization:

```swift
G<Int, String, Float>
```

This specialization substitutes the type parameter pack `E` with the replacement pack type `{Int, String, Float}`. By the substitution rule for pack expansion types, the substituted underlying type is the tuple type

```swift
(Array<Int>, Array<String>, Array<Float>)
```

#### Requirements on type parameter packs

A type parameter pack may have one of the following requirements:

1. Two type parameter packs can be required to have the same length:

```swift
func sameLength<T..., U...>() where length(T...) == length(U...) {}
```

2. The elements in a type parameter pack may have a conformance, superclass, or layout requirement:

```swift
struct RequiresSequence<S...> where S: Sequence { ... }
```

3. The elements in a type parameter pack may be required to all equal a common type:

```swift
struct Container<T...> {}

extension Container where T == Int {}
```

4. The elements in a type parameter pack may be required to pairwise equal the elements of another type parameter pack; this implies a same-length requirement between the two type parameters:

```swift
struct Container<S...> where S: Sequence {}

extension Container {
  func append<T...>(elementsOf: T...) where T: Sequence, T.Element == S.Element {}
}
```

Nested types of type parameter packs are themselves type parameter packs, with the associated types projected element-wise, so any of the above requirements may also be imposed on a nested type of a type parameter pack, as shown in the last example. However, associated types cannot themselves be variadic:

```swift
protocol P {
  associatedtype A... // error
}
```

#### Same-length requirement inference

If the pattern of a pack expansion type contains more than one type parameter pack, all type parameter packs must be known to have the same length. Same-length requirements are *automatically inferred* from pack expansion types that appear in the following positions:

* `where` clauses of generic declarations
* parameter lists and return types of generic functions, initializers, and subscripts

If a pack expansion type appears in any other context, all pack references occurring in the pattern type must be known to have the same length, otherwise an error is diagnosed. Re-stating an inferred same-length requirement is allowed for clarity.

For example, `zip` is a generic function, and the return type `((T, U)...)` is a pack expansion type, therefore the same-length requirement `length(T) == length(U)` is automatically inferred:

```swift
// Return type infers 'where length(T...) == length(U...)'
func zip<T..., U...>(firsts: T..., seconds: U...) -> ((T, U)...) {
  return ((firsts, seconds)...)
}

zip(firsts: 1, 2, seconds: "hi", "bye") // okay
zip(firsts: 1, 2, seconds: "hi") // error; length requirement is unsatisfied
```

Here is an example where the same-length requirement is not inferred:

```swift
func foo<T..., U...>(t: T..., u: U...) {
  let tup: ((T, U)...) = zip(firsts: t..., seconds: u...)
}
```

The type annotation of `tup` contains a pack expansion type `(T, U)...`, which is malformed because the requirement `length(T) == length(U)` is unsatisfied. (The call to `zip()` is also malformed, for the same reason).

#### Open questions

Representing pack lengths abstractly combined with same-type requirements poses some interesting questions. In the general case, same-type requirements on type parameter packs allows encoding arbitrary systems of integer linear equations:

```swift
// length(Q...) = 2*length(R...) + 1
// length(Q...) = length(S...) + 2
func solve<Q..., R..., S...>(q: Q..., r: R..., s: S...) 
    where (Q...) == (Int, R..., R...), 
          (Q...) == (S..., String, Bool) { }
```

While type-level linear algebra is interesting, we may not ever want to allow this in the language to avoid significant implementation complexity, and we definitely want to disallow this expressivity in this proposal.

However, how to impose restrictions on same-length and same-type requirements is an open question. One possibility is to disallow these requirements entirely, but doing so would likely be too limiting. Another possibility is to formalize the concept of the structure or “shape” of a pack, where a shape is one of:

* A single element, such as a non-pack type parameter or concrete type
* An abstract shape that is specific to a pack parameter
* A concrete shape that is composed of single elements and abstract shapes

For example, the pack `{Int, T..., U}` has a concrete shape that consists of two single elements and one abstract shape. We could impose restrictions where packs that are unified together must have the same shape, which may reduce the problem to “shape equivalence classes” rather than an arbitrary system of linear equations. Giving packs a statically known structure may also be useful for destructuring packs in generic contexts, which is a possible future direction.

This aspect of the language can evolve in a forward-compatible manner. To begin with, we can start with the simplest form of same-length requirements, where each type parameter pack has an abstract shape, and same-length requirements merge equivalence classes of abstract shapes. Any attempt to define a same-length requirement involving a concrete type can be diagnosed as a *conflict*, much like we reject conflicting requirements such as `where T == Int, T == String` today. Over time, some restrictions can be lifted, while others remain, as different use-cases for type parameter packs are revealed.

### Value parameter packs

A value parameter pack represents zero or more function arguments, and it is declared with a function parameter that has a pack expansion type. In the following declaration, the function parameter `values` is a value pack parameter that can be passed zero or more argument values at the call-site:

```swift
func tuplify<T...>(_ values: T...) -> (T...)

_ = tuplify() // T := {}
_ = tuplify(1) // T := {Int}
_ = tuplify(1, "hello", [MyType()]) // T := {Int, String, Array<MyType>}
```

Parameter lists can have multiple value parameter packs as long as they are separated by an argument label:

```swift
func concatenate<T..., U...>(firsts: T..., seconds: U...) -> (T..., U...) // okay

func noDelimiter<T..., U...>(firsts: T..., _ seconds: U...) // error!
```

Value parameter packs can be *expanded* into positions that naturally accept a comma-separated list of values. Like pack expansions of type parameter packs, an expansion of a value parameter pack is written with an expression followed by an ellipsis. The expression that the ellipsis is applied to is the *pattern* of the pack expansion, and the ellipsis is the expansion operator. A value pack expansion maps the component values from the packs it contains to the pattern expression. As such, the expression pattern of a pack expansion must contain a value pack.

A value pack reference must always appear within a pack expansion. Expansions of value packs can appear in the following contexts:

* Call arguments, e.g. `generic(values...)`
* Initializer arguments, e.g. `MyType(values...)`
* Subscript arguments, e.g. `subscriptable[indices...]`
* The elements of a tuple value, e.g. `(values...)`
* The source of a `for-in` loop, e.g. `for value in values...`

For example, value pack expansions can be used to forward packs to other functions with parameter packs:

```swift
func tuplify<T...>(_ t: T...) -> (T...) {
  return (t...)
}

func forward<U...>(u: U...) {
  let _ = tuplify(u...) //  T := {U...}
  let _ = tuplify(u..., 10) // T := {U..., Int}
  let _ = tuplify(u..., u...) // T := {U..., U...}
}
```

#### **Iteration**

Value packs can be expanded into the source of a `for-in` loop, allowing you to iterate over each element in the pack and bind each value to a local variable:

```swift
func allEmpty<T...>(_ arrays: [T]...) -> Bool {
  var result = true
  for array in arrays... {
    result = result && array.isEmpty
  }
  return result
}
```

The type of the local variable `array` in the above example is an `Array` of an opaque element type with the requirements that are written on `T`. For the `i`th iteration, the element type is the `i`th type parameter in the type parameter pack `T`.

Iteration over values constructed from packs is a future direction; see [Value expansion operator](#value-expansion-operator).

##### Open questions

When iterating over the values of a parameter pack, the type of the local variable at each iteration is not utterable. It is useful to be able to write this type, e.g. in a type annotation on the pattern binding, to call a static protocol requirement on that type, etc. Using `T` to express this type could lead to ambiguities if the type is mentioned in a pack expansion, so it may be useful to have some other way to write “the *i*th type in a type parameter pack”.

### Labels

How packs interact with labels is still an open question. The possible design decisions are:

1. Packs do not carry labels. This is the simplest approach, with a major downside that generic declarations with type parameter packs may only operate over labeled tuples through a subtype conversion.
2. Packs can carry labels, and labels must be explicitly dropped when used in positions that do not accept labels. This approach would make it clear which positions support labels and which do not, so labels would not be dropped unexpectedly. However, explicitly converting labeled packs to non-labeled packs would likely be onerous. This approach also requires a way to specify that packs are known to not have labels.

1. Packs can carry labels, and labels are silently dropped when used in positions that do not accept labels. This is more ergonomic than approach 2., but it could lead to unexpected behavior in cases where programmers wanted labels to be preserved.

### Ambiguities

#### Pack expansion vs non-pack variadic parameter

Using `...` for pack expansions in parameter lists introduces an ambiguity with the use of `...` to indicate a non-pack variadic parameter. This ambiguity can arise when expanding a type parameter pack into the parameter list of a function type. For example:

```
struct X<U...> { }

struct Ambiguity<T...> {
  struct Inner<U...> {
    typealias A = X<((T...) -> U)...>
  }
}
```

Here, the `...` within the function type `(T...) -> U` could mean one of two things:

1. The `...` defines a (non-pack) variadic parameter, so for each element `Ti` in the parameter pack, the function type has a single (non-pack) variadic parameter of type `Ti`, i.e., `(Ti...) -> Ui`. So, `Ambiguity<String, Character>.Inner<Float, Double>.A` would be equivalent to `X<(String...) -> Float, (Character...) -> Double>`.
2. The `...` expands the parameter pack `T` into individual parameters for the function type, and no pack parameters remain after expansion. Only `U` is expanded by the outer `...`. So, `Ambiguity<String, Character>.Inner<Float, Double>.A` would be equivalent to `X<(String, Character) -> Float, (String, Character) -> Double>`.

To resolve this ambiguity, the pack expansion interpretation of `...` is preferred in a function type. This corresponds with the second meaning above. It is still possible to write code that produces the first meaning, by abstracting the creation of the function type into a `typealias` that does not involve any parameter packs:

```swift
struct X<U...> { }

struct AmbiguityWithFirstMeaning<T...> {
  struct Inner<U...> {
    typealias VariadicFn<V, R> = (V...) -> R
    typealias A = X<VariadicFn<T, U>...>
  }
}
```

Note that this ambiguity resolution rule relies on the ability to determine which names within a type refer to parameter packs. Within this proposal, only generic parameters can be parameter packs and occur within a function type, so normal (unqualified) name lookup can be used to perform disambiguation fairly early. However, there are a number of potential extensions that would make this ambiguity resolution harder. For example, if associated types could be parameter packs, then one would have to reason about member type references (e.g., `A.P`) as potentially being parameter packs.

#### Pack expansion vs postfix closed-range operator

Using `...` as the value expansion operator introduces an ambiguity with the postfix closed-range operator. This ambiguity can arise when `...` is applied to a value pack in the pattern of a value pack expansion, and the values in the pack are known to have a postfix closed-range operator, such as in the following code which passes a list of tuple arguments to `acceptAnything`:

```swift
func acceptAnything<T...>(_: T...) {}

func ranges<T..., U...>(values: T..., otherValues: U...) where T: Comparable, length(T...) == length(U...) {
  acceptAnything((values..., otherValues)...) 
}
```

In the above code, `values...` in the expansion pattern could mean either:

1. The postfix `...` operator is called on each element in `values`, and the result is expanded pairwise with `otherValues` such that each argument has type `(PartialRangeFrom<T>, U)`
2. `values` is expanded into each tuple passed to `acceptAnything`, with each element of `otherValues` appended onto the end of the tuple, and each argument has type `(T... U)`

Like the ambiguity with non-pack variadic parameters, the pack expansion interpretation of `...` is preferred in expressions. This corresponds to the second meaning above. It is still possible to write code with the first meaning, by factoring out the call to the postfix closed-range operator into a function:

```swift
func acceptAnything<T...>(_: T...) {}

func ranges<T..., U...>(values: T..., otherValues: U...) where T: Comparable, length(Ts...) == length(Us...) {
  func range<C: Comparable>(from comparable: C) -> PartialRangeFrom<C> {
    return comparable...
  }
  
  acceptAnything((range(from: values), otherValues)...)
}
```

#### Pack expansion vs operator `...>`

Another ambiguity arises when a pack expansion type `T...` appears as the final generic argument in the generic argument list of a generic type in expression context:

```swift
let foo = Foo<T...>()
```

Here, the ambiguous parse is with the token `...>`. We propose changing the grammar so that `...>` is no longer considered as a single token, and instead parses as the token `...` followed by the token `>`.


## Effect on ABI stability

This is still an area of open discussion, but we anticipate the final model to resemble the following:

* Generic structs, enums and classes with type parameter packs will require runtime support, and will not backward deploy to previous OS versions on platforms that include the Swift runtime.
* Generic type aliases with type parameter packs are a purely compile-time construct, and will backward deploy.
* Generic functions and subscripts with type parameter packs will not require runtime support, and thus will backward deploy.

As work proceeds on the implementation, the above is subject to change.

## Alternatives considered

### Modeling packs as tuples with abstract elements

Under this alternative design, packs are just tuples with abstract elements. This model is attractive because it adds expressivity to all tuple types, but there are some significant disadvantages that make packs hard to work with:

* There is a fundamental ambiguity between forwarding a value pack and passing it as a single tuple value. This could be resolved by requiring an expansion operator `...` to forward a value pack, but it would still be valid in many cases to pass the tuple without flattening the elements. This may become a footgun, because you can easily forget to expand a pack, which will become more problematic when tuples can conform to protocols.
* Because of the above issue, there is no clear way to zip packs. Using a tuple in the pattern of a pack expansion means the entire tuple would appear in each element in the expansion. This could be solved by having an explicit builtin to treat a tuple as a pack, which leads us back to needing a distinction between packs and tuples.

The pack parameter design where packs are distinct from tuples also does not preclude adding flexibility to all tuple types. Converting tuples to packs and expanding tuple values are both useful features and are detailed in the future directions.

### Syntax alternatives to `...`

Choosing an alternative syntax may alleviate ambiguities with existing meanings of `...` in Swift. However, other syntax suggestions do not evoke “list of types or values” in the same way that `...` does. In linguistics, an ellipsis means that words were omitted because they are already understood from context. The use of ellipsis for parameter pack declarations and expansions fits into the linguistic meaning of `...`:

```swift
func prepend<First, Rest...>(first: First, to rest: Rest...) -> (First, Rest...) {
  return (first, rest...)
} 
```

In the above code, each appearance of `...` signals that values or types are omitted because the operand is understood to be a pack which has multiple elements. Finally, `...` will be familiar to programmers who have used variadic templates in C++, and Swift programmers already understand `...` to mean multiple arguments due to its existing use for non-pack variadic parameters.

The following sections outline the alternative spellings for parameter packs and pack expansions that were considered.

#### Another operator

One alternative is to use a different operator, such as `*`, instead of `...`

```swift
func zip<T*, U*>(firsts: T*, seconds: U*) -> ((T, U)*) {
  return ((firsts, seconds)*)
}
```

The downsides to postfix `*` include:

* `*` is extremely subtle
* `*` evokes pointer types / a dereferencing operator to programmers familiar with other languages including C/C++, Go, Rust, etc.
* Choosing another operator does not alleviate the ambiguities in expressions, because values could also have a postfix `*` operator or any other operator symbol, leading to the same ambiguity.

#### Pack declaration and expansion keywords

Another alternative is to use keywords for pack declarations and pack expansions, e.g.

```swift
func zip<pack T, pack U>(firsts: expand T, seconds: expand U) -> (expand (T, U)) {
  return (expand (firsts, seconds))
}
```

The downsides to introducing keywords are:

* Though the keywords are more verbose than an operator, using the `expand` keyword in expression context is still fairly subtle because it looks just like a function call rather than a built in expansion operation.
* Introducing a new keyword in expression context would break existing code that uses that keyword name, e.g. as the name of a function

#### Magic builtin `map` method

A previous design for variadic generics modeled packs as abstract tuples and used a magic `map` method for value pack expansions:

```swift
func wrap<T...>(_ values: T...) -> (Wrapped<T>...) {
  return values.map { Wrapped($0) }
}
```

The downsides of a magic `map` method are:

* There are two very different models for working with packs; the same conceptual expansion has very different spellings at the type and value level, `Wrapped<T>...` vs `values.map { Wrapped($0) }`.
* Magic map can only be applied to one pack at a time, leaving no clear way to zip packs without adding other builtins.
* The closure-like syntax is misleading because it’s not a normal closure that you can write in the language. This operation is also very complex over packs with any structure, including concrete types, because the compiler either needs to infer a common generic signature for the closure that works for all elements, or it needs to separately type check the closure once for each element type.

## Future directions

### Value expansion operator

This proposal only supports the expansion operator on pack patterns, but there are other values that represent a list of zero or more values that the expansion operator would be useful for, including tuples and arrays. Extending the expansion operator to values is also necessary for variadic generic types that store a pack into a tuple:

```swift
struct Generic<T...> {
  let values: (T...)
  
  func iterate() {
    for value in values... {
      // do something with value
    }
  }
}
```

### Local value packs

Similarly, it may be useful to convert a tuple to a pack in order to expand it in parallel with another pack. The language could support this by allowing local value pack declarations that tuples can be expanded into:

```swift
struct Tuple<T...> {
  let values: (T...)
  
  func packify() {
    let pack: T... = values...
    // do something with pack
  }
}
```

### Pack destructuring operations

In Swift’s variadic generics model, packs will necessarily have an abstract structure. However, if the structure of a pack is statically known, the compiler can allow that pack to be destructured. For example:

```swift
func prepend<First, Rest...>(first: First, to rest: Rest...) -> (First, Rest...) {
  return (first, rest...)
}
```

The above `prepend` function is known to return a tuple consisting of one element followed by a pack expansion. This information could be used to allow destructuring the result to pattern match the first element and the rest of the elements, e.g.:

```swift
func prependAndDestructure<First, Rest...>(first: First, to rest: Rest...) {
  let (first, rest...) = prepend(first: first, to: rest)...
}
```

### Tuple conformances

Parameter packs, the above future directions, and a syntax for declaring tuple conformances based on [parameterized extensions](https://github.com/apple/swift/blob/main/docs/GenericsManifesto.md#parameterized-extensions) over non-nominal types enable implementing custom tuple conformances:

```swift
extension<T...> (T...): Equatable where T: Equatable {
  public static func ==(lhs: Self, rhs: Self) -> Bool {
    let lhsPack: T... = lhs...
    let rhsPack: T... = rhs...
    for (l, r) in (lhsPack, rhsPack)... {
      guard l == r else { return false }
    }
    return true
  }
}

extension<T...> (T...): Comparable where T: Comparable {
  public static func <(lhs: Self, rhs: Self) -> Bool { 
    let lhsPack: T... = lhs...
    let rhsPack: T... = rhs...
    for (l, r) in (lhsPack, rhsPack)... {
      guard l < r else { return false }
    }
    return true
  }
}
```

## Acknowledgments

Thank you to Robert Widmann for exploring the design space of modeling packs as tuples, to John McCall for his insight on the various possibilities in the variadic generics design space, and to everyone who participated in earlier design discussions about variadic generics in Swift.