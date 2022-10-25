- [Value and Type Parameter Packs](#value-and-type-parameter-packs)
  - [Proposed solution](#proposed-solution)
  - [Detailed design](#detailed-design)
    - [Type parameter packs](#type-parameter-packs)
    - [Pack expansion type](#pack-expansion-type)
    - [Type substitution](#type-substitution)
    - [Type matching](#type-matching)
      - [Label matching](#label-matching)
      - [Type sequence matching](#type-sequence-matching)
      - [One-element tuples](#one-element-tuples)
    - [Member type parameter packs](#member-type-parameter-packs)
    - [Generic requirements](#generic-requirements)
      - [Same-shape requirements](#same-shape-requirements)
      - [Open questions](#open-questions)
    - [Value parameter packs](#value-parameter-packs)
    - [Local value packs](#local-value-packs)
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
    - [Variadic generic types](#variadic-generic-types)
    - [Value expansion operator](#value-expansion-operator)
    - [Pack destructuring operations](#pack-destructuring-operations)
    - [Tuple conformances](#tuple-conformances)
  - [Acknowledgments](#acknowledgments)

# Value and Type Parameter Packs

Generic functions currently require a fixed number of type parameters. It is not possible to write a generic function that accepts an arbitrary number of arguments with distinct types, instead requiring one of the following workarounds:

* Erasing all of the types involved, e.g. using `Any...`
* Using a single tuple type argument instead of separate type arguments
* Overloading for each argument length with an artificial limit

One example in the Swift Standard Library is the 6 overloads for each tuple comparison operator:

```swift
func < (lhs: (), rhs: ()) -> Bool

func < <A, B>(lhs: (A, B), rhs: (A, B)) -> Bool where A: Comparable, B: Comparable

func < <A, B, C>(lhs: (A, B, C), rhs: (A, B, C)) -> Bool where A: Comparable, B: Comparable, C: Comparable

// and so on, up to 6-element tuples
```

With language support for a variable number of type parameters, this API could be expressed more naturally and concisely as a single function declaration:

```swift
func < <T...>(lhs: (T...), rhs: (T...)) -> Bool where T: Comparable
```

## Proposed solution

This proposal adds support for generic functions which abstract over a variable number of type parameters. While this proposal is useful on its own, there are many future directions that build upon this concept. This is the first step toward equipping Swift programmers with a set of tools that enable variadic generic programming.

Here are the key concepts introduced by this proposal:

- Under the new model, all existing types and values in the language become _scalar types_ and _scalar values_.
- A _type pack_ is a new kind of type which represents a list of scalar types. Type packs do not have syntax in the surface language, but we will write them as `{T1, ..., Tn}` where each `Ti` is a scalar type. Type packs cannot be nested; type substitution is defined to always flatten type packs.
- A _type parameter pack_ is a type parameter which can abstract over a type pack. These are declared in a generic parameter list using the syntax `T...`, and referenced with `T`.
- A _pack expansion type_ is a new kind of scalar type which flattens a set of type packs in a context where a comma-separated list of types may appear. The syntax for a pack expansion type is `P...`, where `P` is a type containing one or more type parameter packs.
- A _value pack_ is a list of scalar values. The type of a value pack is a type pack, where each element of the type pack is the scalar type of the corresponding scalar value. Value packs do not have syntax in the surface language, but we will write them as `{x1, ..., xn}` where each `xi` is a scalar value. Value packs cannot be nested; evaluation is always defined to flatten value packs.
- A _value parameter pack_ is a function parameter or local variable declared with a pack expansion type.
- A _pack expansion expression_ is a new kind of expression whose type is a pack expansion type. Written as `expr...`, where `expr` is an expression referencing one or more value parameter packs.

The following example demonstrates these concepts:

```swift
// Construct a new tuple by prepending an element to beginning of the given tuple
func prepend<First, Rest...>(value: First, to rest: Rest...) -> (First, Rest...) {
  return (value, rest...)
}

let value = prepend(value: 1, rest: 2.0, "hello")
// value is (1, 2.0, "hello")
```

The function declares two type parameters, `First` and `Rest`. `Rest` is a type parameter pack declaration. The value parameter pack `rest` has the pack expansion type `Rest...`. The return type `(First, Rest...)` is a tuple type with two elements, where the second element is again the pack expansion type `Rest...`.

Inside the body of `prepend()`, `rest...` is a pack expansion expression referencing the value parameter pack `rest`.

The call to `prepend()` substitutes `Int` for `First`, and the type pack `{Double, String}` for `Rest`. These substitutions are deduced by the _type matching rules_, described below. The function is called with two arguments, `value` is the value `1`, and `rest` is the value pack `{2.0, "hello"}`.

The substituted return type is the tuple type with three elements `(Int, Double, String)`, and the returned value is the tuple value with three elements `(1, 2.0, "hello")`.

## Detailed design

**Note:** While this proposal talks about "generic functions", everything also applies to initializers and subscripts nested inside types. With closure expressions, the situation is slightly more limited. Closure expressions support value parameter packs, however since closure expressions do not have polymorphic types in Swift, they're limited to referencing type parameter packs from outer scopes and cannot declare type parameter packs of their own. Also, the value parameter packs of closures cannot have argument labels, because as usual only named declarations have argument labels in Swift.

### Type parameter packs

The generic parameter list of a generic function can contain one or more _type parameter pack declarations_, written as an identifier followed by `...`:

```swift
func variadic<T..., U...>() {}
```

When referenced from type context, this identifier resolves to a _type parameter pack_. References to type parameter packs can only appear in the following positions:

* The base type of a member type parameter pack, which is again subject to these rules
* The pattern type of a pack expansion type, where it stands for the corresponding scalar element type
* The pattern expression of a pack expansion expression, where it stands for the metatype of the corresponding scalar element type and can be used like any other scalar metatype, e.g. to call a static method, call an initializer, or reify the metatype value
* The subject type of a conformance, superclass, layout or same-type requirement
* The constraint type of a same-type requirement

### Pack expansion type

A pack expansion type, written as `P...`, has a *pattern type* `P` and a non-empty set of _captured_ type parameter packs.

**Syntactic validity:** Pack expansion types can appear in the following positions:

* The type of a parameter in a function declaration, e.g. `func foo<T...>(values: T...) -> Bool`
* The type of a parameter in a function type, e.g. `(T...) -> Bool`
* The type of an unlabeled element in a tuple type, e.g. `(T...)`

The restriction where only unlabeled elements of a tuple type may have a pack expansion type is motivated by ergonomics. If you could write `(t: T...)`, then after a substitution `T := {Int, String}`, the substituted type would be `(t: Int, String)`. This would be strange, because projecting the member `t` would only produce the first element. When an unlabeled element has a pack expansion type, like `(T...)`, then after the above substitution you would get `(Int, String)`. You can still write `0` to project the first element, but this is less surprising to the Swift programmer.

**Capture:** A type _captures_ a type parameter pack if the type parameter pack appears inside the pattern type, without any intervening pack expansion type. For example, if `T` and `U` are type parameter packs, then `Array<(T) -> U>...` captures both `T` and `U`. However, `Array<(T) -> (U...)>` captures `T`, but *not* `U`. Only the inner pack expansion type `U...` captures `U`. (Indeed, in a valid program, every reference to a type parameter pack is captured by exactly one pack expansion type.)

The captures of the pattern type are a subset of the captures of the pack expansion type itself. In some situations (described in the next section), the pack expansion type might capture a type parameter pack that does not appear in the pattern type.

**Typing rules:** A pack expansion type is _well-typed_ if the pattern type would be well-typed if the captured type parameter packs were replaced by references to scalar type parameters with the same constraints.

For example, if `T` is a type parameter pack subject to the conformance requirement `T: Hashable`, then `Set<T>...` is well-typed.

However, if `T` were not subject to this conformance requirement, then `Set<T>...` would not be well-typed; the user might substitute `T` with a type pack containing types that do not conform to `Hashable`, like `T := {AnyObject, Int}`, and the substituted type sequence `Set<AnyObject>, Set<Int>` is not well-typed because `Set<AnyObject>` is not well-typed.

### Type substitution

Recall that a reference to a generic function from expression context always provides an implicit list of *generic arguments* which map each of the function's type parameters to a *replacement type*. The type of the expression referencing a generic declaration is derived by substituting each type parameter in the declaration's type with the corresponding replacement type.

The replacement type of a type parameter pack is always a type pack. Since type parameter packs always occur inside the pattern type of a pack expansion type, we need to define what it means to perform a substitution on a type that contains pack expansion types.

Recall that pack expansion types appear in function parameter types and tuple types. The comma-separated list of types that can contain a pack expansion type is called a _type sequence_. Substitution replaces each pack expansion type with a replacement type sequence, which is flattened into the outer type sequence.

**Intuition:** The substituted type sequence is formed by replacing the captured type parameter pack references with the corresponding elements of each replacement type pack.

For example, consider the declaration:

```swift
func variadic<T..., U...>(t: T..., u: U...) -> (Int, ((T) -> U)...)
```

Suppose we reference it with the following substitutions:

```swift
T := {String, V..., Float}
U := {NSObject, Array<W>..., NSString}
```

The substituted return type of `variadic` becomes a tuple type with 4 elements:

```swift
(Int, (String) -> NSObject, ((V) -> Array<W>)..., (Float) -> NSString)
```

**Formal algorithm:** Suppose `P...` is a pack expansion type with pattern type `P`, that captures a list of type parameter packs `Ti`, and let `S[Ti]` be the replacement type pack for `Ti`. We require that each `S[Ti]` has the same length; call this length `N`. If the lengths do not match, the substitution is malformed. Let `S[Ti][j]` be the `j`th element of `S[Ti]`, where `0 ≤ j < N`.

The `j`th element of the replacement type sequence is derived as follows:

1. If each `S[Ti][j]` is a scalar type, the element type is obtained by substituting each `Ti` with `S[Ti][j]` in the pattern type `P`.
2. If each `S[Ti][j]` is a pack expansion type, then `S[Ti][j]` = `Pij...` for some pattern type `Pij`. The element type is the pack expansion type `Qij...`, where `Qij` is obtained by substituting each `Ti` with `Pij` in the pattern type `P`.
3. Any other combination means the substitution is malformed.

When the lengths or structure of the replacement type packs do not match, the substitution is malformed. This situation is diagnosed with an error by checking generic requirements, as discussed below.

For example, the following substitutions are malformed because the lengths do not match:

```swift
T := {String, Float}
U := {NSObject}
```

The following substitutions are malformed because the replacement type packs have incompatible structure, hitting Case 3 above:

```swift
T := {V..., Float}
U := {NSObject, W...}
```

To clarify what it means for a type to capture a type parameter pack, consider the following:

```swift
func variadic<T..., U...>(t: T..., u: U...) -> ((T) -> (U...)...)
```

The pack expansion type `(T) -> (U...)...` captures `T`, but not `U`. If we apply the following substitutions:

```swift
T := {Int, String}
U := {Float, Double, Character}
```

Then the substituted return type becomes a pair of function types:

```swift
((Int) -> (Float, Double, Character), (String) -> (Float, Double, Character)>
```

Note that the entire replacement type pack for `U` was flattened in each repetition of the pattern type; we did not expand "across" `U`.

**Concrete pattern type:**  It is possible to construct an expression with a pack expansion type whose pattern type does not capture any type parameter packs. This is called a pack expansion type with a _concrete_ pattern type. For example, consider this declaration:

```swift
func counts<T: Collection>(_ t: T...) {
  let x = (t.count...)
}
```

The `count` property on the `Collection` protocol returns `Int`, so the type of the expression `(t.count...)` is written as the one-element tuple type `(Int...)` whose element is the pack expansion type `Int...`. While the pattern type `Int` does not capture any type parameter packs, the pack expansion type must still capture `T` to represent the fact that after expansion, the resulting tuple type has the same length as `T`. This kind of pack expansion type can arise during type inference, but it cannot be written in source.

### Type matching

Recall that the substitutions for a reference to a generic function are derived from the types of call argument expressions together with the contextual return type of the call, and are not explicitly written in source. This necessitates introducing new rules for _matching_ types containing pack expansions.

There are two separate rules:

- For call expressions where the callee is a named function declaration, _label matching_ is performed.
- For everything else, _type sequence matching_ is performed.

#### Label matching

Here, we use the same rule as the "legacy" variadic parameters that exist today. If a function declaration parameter has a pack expansion type, the parameter must either be the last parameter, or followed by a parameter with a label. A diagnostic is produced if the function declaration violates this rule.

Given a function declaration that is well-formed under this rule, type matching then uses the labels to delimit type packs. For example, the following is valid:

  ```swift
  func concat<T..., U...>(t: T..., u: U...) -> (T..., U...)

  // T := {Int, Double}
  // U := {String, Array<Int>}
  concat(t: 1, 2.0, u: "hi", [3])
  
  // substituted return type is (Int, Double, String, Array<Int>)
  ```

  while the following is not:

  ```swift
  func bad<T..., U...>(t: T..., U...) -> (T..., U...)
  // error: 'T...' followed by an unlabeled parameter

  bad(1, 2.0, "hi", [3])  // ambiguous; where does T... end and U... start?
  ```

#### Type sequence matching

In all other cases, we're matching two type sequences. If either type sequence contains two or more pack expansion types, the match remains _unsolved_, and the type checker attempts to derive substitutions by matching other types before giving up. (This allows a call to `concat()` as defined above to succeed, for example; the match between the contextual return type and `(T..., U...)` remains unsolved, but we are able to derive the substitutions for `T` and `U` from the call argument expressions.)

Otherwise, we match the common prefix and suffix as long as no pack expansion types appear on either side. After this has been done, there are three possibilities:

1. Left hand side contains a single pack expansion type, right hand size contains zero or more types.
2. Left hand side contains zero or more types, right hand side contains a single pack expansion type.
3. Any other combination, in which case the match fails.

For example:

```swift
func variadic<T...>(_: T...) -> (Int, T..., String) {}

let fn = { x in variadic(x) as (Int, Double, Float, String) }
```

Case 3 covers the case where one of the type sequences has a pack expansion, but the other one is too short; for example, matching `(Int, T..., String, Float)` against `(Int, Float)` leaves you with `(T..., String)` vs `()`, which is invalid.

If neither side contains a pack expansion type, Case 3 also subsumes the current behavior as implemented without this proposal, where type sequence matching always requires the two type sequences to have the same length. For example, when matching `(Int, String)` against `(Int, Float, String)`, we end up with `()` vs `(Float)`, which is invalid.

The type checker derives the replacement type for `T` in the call to `variadic()` by matching the contextual return type `(Int, Double, Float, String)` against the declared return type `(Int, T..., String)`. The common prefix `Int` and common suffix `String` successfully match. What remains is the pack expansion type `T...` and the type sequence `Double, Float`. This successfully matches, deriving the substitution `T := {Double, Float}`.

While type sequence matching is positional, the type sequences may still contain labels if we're matching two tuple types. We require the labels to match exactly when dropping the common prefix and suffix, and then we only allow Case 1 and 2 to succeed if the remaining type sequences do not contain any labels.

For example, matching `(x: Int, T..., z: String)` against `(x: Int, Double, y: Float, z: String)` drops the common prefix and suffix, and leaves you with the pack expansion type `T...` vs the type sequence `Double, y: Float`, which fails because `Double: y: Float` contains a label.

However, matching `(x: Int, T..., z: String)` against `(x: Int, Double, Float, z: String)` leaves you with `T...` vs `Double, Float`, which succeeds with `T := {Double, Float}`, because the labels match exactly in the common prefix and suffix, and no labels remain once we get to Case 1 above.

#### Open questions

It is still undecided if a substitution that would produce a one-element tuple type should instead produces the element type as a scalar, treating the tuple as if it were merely parentheses.

For example, the following could produce either the one-element tuple `(_: Int)` or the element type `Int`:
- Substituting `T := {Int}` into `(T...)`.
- Substituting `T := {}` into `(Int, T...)`.

Both approaches have pros and cons.

One downside to exposing one-element tuples is that it increases the surface area of the language to handle this strange edge case. One-element tuples would need to be manually unwrapped, with `.0` or pattern matching, in order to make use of their contents. This unwrapping would clutter up code.

On the other hand, automatically unwrapping one-element tuples in type substitution complicates type matching. If a substitution that would otherwise produce a one-element tuple instead produces the element type, matching a one-element tuple containing a pack expansion against a non-tuple type would introduce an ambiguity.

For example, while matching `(T...)` against `Int` would unambiguously bind `T := {Int}`, consider what happens if we match  `(T...)` against the empty tuple type `()`. There are two possible solutions, `T := {}` where the `T` is bound to the empty type pack, or `T := {()}` where `T` is bound to a one-element type pack containing the empty tuple.

### Member type parameter packs

If a type parameter pack `T` is subject to a protocol conformance requirement `P`, and `P` declares an associated type `A`, then `T.A` is a valid pattern type for a pack expansion type, called a _member type parameter pack_.

Under substitution, a member type parameter pack projects the associated type from each element of the replacement type pack.

For example:

```swift
func variadic<T: Sequence>(_: T...) -> (T.Element...)
```

After the substitution `T := {Array<Int>, Set<String>}`, the substituted return type of this function becomes the tuple type `(Int, String)`.

We will refer to `T` as the _root type parameter pack_ of the member type parameter packs `T.A` and `T.A.B`.

### Generic requirements

All existing kinds of generic requirements generalize to type parameter packs. Same-type requirements generalize in multiple different ways, depending on whether one or both sides involve a type parameter pack.

1. Conformance, superclass, and layout requirements where the subject type is a type parameter pack are interpreted as constraining each element of the replacement type pack:

  ```swift
  func variadic<S...>(_: S...) where S: Sequence { ... }
  ```

  A valid substitution for the above might replace `S` with `{Array<Int>, Set<String>}`.

2. A same-type requirement where one side is a type parameter pack and the other type is a concrete type that does not capture any type parameter packs is interpreted as constraining each element of the replacement type pack to _the same_ concrete type:

  ```swift
  func variadic<S...: Sequence, T>(_: S...) where S.Element == Array<T> {}
  ```

  This is called a _concrete same-element requirement_.

  A valid substitution for the above might replace `S` with `{Array<Int>, Set<Int>}`, and `T` with `Int`.

3. A same-type requirement where one side is a type parameter pack and the other type is a scalar type parameter is interpreted as constraining each element of the replacement type pack to the type parameter:

  ```swift
  func variadic<S...: Sequence, T...>(_: S...) where S.Element == T {}
  ```

  This is called an _abstract same-element requirement_.

  A valid substitution for the above might replace `S` with `{Array<Int>, Set<String>}`, and `T` with `{Int, String}`.

3. A same-type requirement where one side is a type parameter pack and the other side is a concrete type capturing at least one type parameter pack is interpreted as expanding the concrete type and constraining each element of the replacement type pack to the concrete element type:

  ```swift
  func variadic<S...: Sequence, T...>(_: S...) where S.Element == Array<T> {}
  ```
  
  This is called a _concrete same-type pack requirement_.

  A valid substitution for the above might replace `S` with `{Array<Array<Int>>, Set<Array<String>>}`, and `T` with `{Int, String}`.

3. A same-type requirement where both sides are type parameter packs constrains the elements of the replacement type pack element-wise:

  ```swift
  func append<S...: Sequence, T...: Sequence>(_: S..., _: T...) where T.Element == S.Element {}
  ```
  
  This is called an _abstract same-type pack requirement_.

  A valid substitution for the above would replace `S` with `{Array<Int>, Set<String>}`, and `T` with `{Set<Int>, Array<String>}`.

There is an additional kind of requirement called a _same-shape requirement_. There is no surface syntax for spelling a same-shape requirement; they are always inferred, as described in the next section.

**Symmetry:** Recall that same-type requirements are symmetrical, so `T == U` is equivalent to `U == T`. Therefore some of the possible cases above are not listed, but the behavior can be understood by first transposing the same-type requirement.

**Constrained protocol types:** A conformance requirement where the right hand side is a constrained protocol type `P<T0, ..., Tn>` may reference type parameter packs from the generic arguments `Ti` of the constrained protocol type. In this case, the semantics are defined in terms of the standard desugaring. Independent of the presence of type parameter packs, a conformance requirement to a constrained protocol type is equivalent to a conformance requirement to `P` together with one or more same-type requirements that constrain the primary associated types of `P` to the corresponding generic arguments `Ti`. After this desugaring step, the induced same-type requirements can then be understood by Case 2, 3, 4 or 5 above.

#### Same-shape requirements

A same-shape requirement states that two type parameter packs have the same number of elements, with pack expansion types occurring at identical positions.

At this time, we are not proposing a spelling for same-shape requirements in the surface language, since we do not believe it is necessary given the inference behavior outlined below. However, we will use the notation `shape(T) == shape(U)` to denote same-shape requirements in this proposal.

A same-shape requirement always relates two root type parameter packs. Member types always have the same shape as the root type parameter pack, so `shape(T.A) == shape(U.B)` reduces to `shape(T) == shape(U)`.

**Inference:** Same-shape requirements are inferred in one of three ways:

1. An abstract same-type requirement implies a same-shape requirement between two type parameter packs.

2. A concrete same-type requirement implies a same-shape requirement between the type parameter packs on the left hand side and all type parameter packs captured by the concrete type on the right hand side.

3. Finally, a same-shape requirement is inferred between each pair of type parameter packs captured by a pack expansion type appearing in certain positions.

The following positions are subject to the same-shape requirement inference in Case 3:

* all types appearing in the requirements of a trailing `where` clause of a generic function
* the parameter types and return type of a generic function

Recall that if the pattern of a pack expansion type contains more than one type parameter pack, all type parameter packs must be known to have the same shape, as outlined in the [Type substitution](#type-substitution) section. Same-shape requirement inference ensures that these invariants are satisfied when the pack expansion type occurs in one of the two above positions.

If a pack expansion type appears in any other position, all type parameter packs captured by the pattern type must already be known to have the same shape, otherwise an error is diagnosed.

For example, `zip` is a generic function, and the return type `((T, U)...)` is a pack expansion type, therefore the same-shape requirement `shape(T) == shape(U)` is automatically inferred:

```swift
// Return type infers 'where length(T...) == length(U...)'
func zip<T..., U...>(firsts: T..., seconds: U...) -> ((T, U)...) {
  return ((firsts, seconds)...)
}

zip(firsts: 1, 2, seconds: "hi", "bye") // okay
zip(firsts: 1, 2, seconds: "hi") // error; length requirement is unsatisfied
```

Here is an example where the same-shape requirement is not inferred:

```swift
func foo<T..., U...>(t: T..., u: U...) {
  let tup: ((T, U)...) = /* whatever */
}
```

The type annotation of `tup` contains a pack expansion type `(T, U)...`, which is malformed because the requirement `count(T) == count(U)` is unsatisfied. This pack expansion type is not subject to requirement inference because it does not occur in one of the above positions.

#### Open questions

While type packs cannot be written directly, a requirement where both sides are concrete types is desugared using the type matching algorithm, therefore it will be possible to write down a requirement that constraints a type parameter pack to a concrete type pack, unless some kind of restriction is imposed:

```swift
func append<S...: Sequence>(_: S..., _: T...) where (S.Element...) == (Int, String) {}
```

Furthermore, since the same-type requirement implies a same-shape requirement, we've actually implicitly constrained `T` to having a length of 2 elements, without knowing what those elements are.

This introduces theoretical complications. In the general case, same-type requirements on type parameter packs allows encoding arbitrary systems of integer linear equations:

```swift
// shape(Q...) = 2 * shape(R...) + 1
// shape(Q...) = shape(S...) + 2
func solve<Q..., R..., S...>(q: Q..., r: R..., s: S...) 
    where (Q...) == (Int, R..., R...), 
          (Q...) == (S..., String, Bool) { }
```

While type-level linear algebra is interesting, we may not ever want to allow this in the language to avoid significant implementation complexity, and we definitely want to disallow this expressivity in this proposal.

However, how to impose restrictions on same-shape and same-type requirements is an open question. One possibility is to disallow these requirements entirely, but doing so would likely be too limiting. Another possibility is to formalize the concept of the structure or “shape” of a pack, where a shape is one of:

* A single scalar type element; all scalar types have a singleton ``scalar shape''
* An abstract shape that is specific to a pack parameter
* A concrete shape that is composed of the scalar shape and abstract shapes

For example, the pack `{Int, T..., U}` has a concrete shape that consists of two single elements and one abstract shape. We could impose restrictions where packs that are unified together must have the same shape, which may reduce the problem to “shape equivalence classes” rather than an arbitrary system of linear equations. Giving packs a statically known structure may also be useful for destructuring packs in generic contexts, which is a possible future direction.

This aspect of the language can evolve in a forward-compatible manner. To begin with, we can start with the simplest form of same-shape requirements, where each type parameter pack has an abstract shape, and same-shape requirements merge equivalence classes of abstract shapes. Any attempt to define a same-shape requirement involving a concrete type can be diagnosed as a *conflict*, much like we reject conflicting requirements such as `where T == Int, T == String` today. Over time, some restrictions can be lifted, while others remain, as different use-cases for type parameter packs are revealed.

### Value parameter packs

A _value parameter pack_ represents zero or more function arguments, and it is declared with a function parameter that has a pack expansion type. In the following declaration, the function parameter `values` is a value parameter pack that receives a _value pack_ consisting of zero or more argument values from the call site:

```swift
func tuplify<T...>(_ values: T...) -> (T...)

_ = tuplify() // T := {}, values := {}
_ = tuplify(1) // T := {Int}, values := {1}
_ = tuplify(1, "hello", [Foo()]) // T := {Int, String, [Foo]}, values := {1, "hello", [Foo()]}
```

**Syntactic validity:** A value parameter pack can only be referenced from a pack expansion expression. A pack expansion expression is written as `expr...`, where `expr` is an expression containing one or more value parameter packs or type parameter packs. Pack expansion expressions can appear in any position that naturally accepts a comma-separated list of expressions. This includes the following:

* Call arguments, e.g. `generic(values...)`
* Subscript arguments, e.g. `subscriptable[indices...]`
* The elements of a tuple value, e.g. `(values...)`
* The elements of an array literal, e.g. `[values...]`

Pack expansion expressions can also appear in an expression statement at the top level of a brace statement. In this case, the semantics are the same as scalar expression statements; the expression is evaluated for its side effect and the results discarded.

Note that pack expansion expressions can also reference _type_ pack parameters, as metatypes.

**Capture:** A pack expansion expression _captures_ a value (or type) pack parameter the value (or type) pack parameter appears as a sub-expression without any intervening pack expansion expression.

Furthermore, a pack expansion expression also captures all type parameter packs captured by the types of its captured value parameter packs.

For example, say that `x` and `y` are both value parameter packs and `T` is a type parameter pack, and consider the pack expansion expression `foo(x, T.self, (y...))...`. This expression captures both the value parameter pack `x` and type parameter pack `T`, but it does not capture `y`, because `y` is captured by the inner pack expansion expression `y...`. Additionally, if `x` has the type `Foo<U, (V...)>`, then our expression captures `U`, but not `V`, because again, `V` is captured by the inner pack expansion type `V...`.

**Typing rules:** For a pack expansion expression to be well-typed, two conditions must hold:

1. The types of all value parameter packs captured by a pack expansion expression must be related via same-shape requirements.

2. After replacing all value parameter packs with non-pack parameters that have equivalent types, the pattern expression must be well-typed.

Assuming the above hold, the type of a pack expansion expression is defined to be the pack expansion type whose pattern type is the type of the pattern expression.

**Evaluation semantics:** At runtime, each value (or type) pack parameter receives a value (or type) pack, which is a concrete list of values (or types). The same-shape requirements guarantee that all value (and type) packs have the same length, call it `N`. The evaluation semantics are that for each successive `i` such that `0 ≤ i < N`, the pattern expression is evaluated after substituting each occurrence of a value (or type) pack parameter with the `i`th element of the value (or type) pack. The evaluation proceeds from left to right according to the usual evaluation order, and the sequence of results from each evaluation forms the argument list for the parent expression.

For example, pack expansion expressions can be used to forward value parameter packs to other functions:

```swift
func tuplify<T...>(_ t: T...) -> (T...) {
  return (t...)
}

func forward<U...>(u: U...) {
  let _ = tuplify(u...) //  T := {U...}
  let _ = tuplify(u..., 10) // T := {U..., Int}
  let _ = tuplify(u..., u...) // T := {U..., U...}
  let _ = tuplify([u]...) // T := {Array<U>...}
}
```

### Local value packs

The notion of a value parameter pack readily generalizes to a local variable of pack expansion type, for example:

```swift
func variadic<T...>(t: T...) {
  let tt: T... = t...
}
```

References to `tt` have the same semantics as references to `t`, and must only appear inside other pack expansion expressions.

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

func ranges<T..., U...>(values: T..., otherValues: U...) where T: Comparable, shape(T...) == shape(U...) {
  acceptAnything((values..., otherValues)...) 
}
```

In the above code, `values...` in the expansion pattern could mean either:

1. The postfix `...` operator is called on each element in `values`, and the result is expanded pairwise with `otherValues` such that each argument has type `(PartialRangeFrom<T>, U)`
2. `values` is expanded into each tuple passed to `acceptAnything`, with each element of `otherValues` appended onto the end of the tuple, and each argument has type `(T... U)`

Like the ambiguity with non-pack variadic parameters, the pack expansion interpretation of `...` is preferred in expressions. This corresponds to the second meaning above. It is still possible to write code with the first meaning, by factoring out the call to the postfix closed-range operator into a function:

```swift
func acceptAnything<T...>(_: T...) {}

func ranges<T..., U...>(values: T..., otherValues: U...) where T: Comparable, shape(Ts...) == shape(Us...) {
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

This is still an area of open discussion, but we anticipate that generic functions with type parameter packs will not require runtime support, and thus will backward deploy. As work proceeds on the implementation, the above is subject to change.

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

### Variadic generic types

This proposal only supports type parameter packs on functions. A complementary proposal will describe type parameter packs on generic structs, enums and classes.

### Value expansion operator

This proposal only supports the expansion operator on type parameter packs and value parameter packs, but there are other values that represent a list of zero or more values that the expansion operator would be useful for, including tuples and arrays. It would be desirable to introduce a new kind of expression that receives a scalar value and produces a value of pack expansion type.

There are two possible interpretations, which will probably require two syntaxes; here, we're going to use the straw-man `.expand` and `.expand...`:

```swift
func foo<T, U...>(T, U...) {}

func bar1<T..., U...>(t: (T...), u: (U...)) {
  foo(t.expand, u.expand)...
}

func bar2<T..., U...>(t: (T...), u: (U...)) {
  foo(t.expand, u.expand...)...
}
```

Here, `bar1(t: 1, 2, u: "a", "b")` will evaluate:

```swift
foo(1, "a")
foo(2, "b")
```

While `bar2(t: 1, 2, u: "a", "b")` will evaluate:

```swift
foo(1, "a", "b")...
foo(2, "a", "b")...
```

The distinction can be understood in terms of our notion of _captures_ in pack expansion expressions.

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