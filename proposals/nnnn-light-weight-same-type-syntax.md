# Lightweight same-type requirements for primary associated types

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/main/proposal-templates/NNNN-filename.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Holly Borla](https://github.com/hborla), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: TBD
* Status: Implemented on `main` behind the `-enable-parameterized-protocol-types` feature flag.

## Introduction

As a step toward the goal of improving the UI of generics outlined in [Improving the UI of Generics](https://forums.swift.org/t/improving-the-ui-of-generics/22814#heading--directly-expressing-constraints), this proposal introduces a new syntax for conforming a generic parameter and constraining an associated type via a same-type requirement.

## Motivation

Consider a function that returns an `AsyncSequence` of lines in a source file:

```swift
struct LinesAsyncSequence : AsyncSequence {
  struct AsyncIterator : AsyncIteratorProtocol {
    mutating func next() async -> String? { ... }
  }
  
  func makeAsyncIterator() -> AsyncIterator {
    return AsyncIterator()
  }
}

func readLines(_ file: String) -> LinesAsyncSequence { ... }
```

Suppose you are implementing a syntax highlighting library. You might define another function which wraps the result in a `SyntaxTokensAsyncSequence`, whose element type is `[Token]`, representing an array of syntax-highlighted tokens on each line:

```swift
func readSyntaxHighlightedLines(_ file: String)
  -> SyntaxTokensAsyncSequence<LinesAsyncSequence> {
  ...
}
```

At this point, the concrete result type is rather complex, and we might wish to hide it behind an opaque result type using the `some` keyword:

```swift
func readSyntaxHighlightedLines(_ file: String) -> some AsyncSequence {
  ...
}
```

However, the resulting definition of `readSyntaxHighlightedLines()` is not as useful as the original, because the requirement that the `Element` associated type of the resulting `AsyncSequence` is equal to `[Token]` cannot be expressed.

As another example, consider a global function `concatenate` that operates on two arrays of `String`:

```swift
func concatenate(_ lhs: Array<String>, _ rhs: Array<String>) -> Array<String> {
  ...
}
```

To generalize this function to arbitrary sequences, one might write:

```swift
func concatenate<S : Sequence>(_ lhs: S, _ rhs: S) -> S where S.Element == String {
  ...
}
```

However, while `where` clauses are very general and allow complex generic requirements to be expressed, they also introduce cognitive overhead when reading and writing the declaration, and looks quite different than the concrete implementation where the type was simply written as `Array<String>`. It would be nice to have a simpler solution for cases where there is only a single same-type requirement, as above.

## Proposed solution

We’d like to propose a new syntax for declaring a protocol conformance requirement together with one or more same-type requirements on the protocol's _primary associated types_. This new syntax looks like the application of a concrete generic type to a list of type arguments, allowing you to write `AsyncSequence<String>` or `AsyncSequence<[Lines]>`. This builds on the user's previous intuition and understanding of generic types and is analogous to `Array<String>` and `Array<[Lines]>`.

Protocols can declare one or more primary associated types using a syntax similar to a generic parameter list of a concrete type:

```swift
protocol AsyncSequence<Element> {
  associatedtype Iterator : AsyncIteratorProtocol
    where Element == Iterator.Element
  ...
}

protocol DictionaryProtocol<Key : Hashable, Value> {
  ...
}
```

A protocol with primary associated types can be referenced from any position where a protocol conformance requirement was previously allowed, with a list of type arguments in angle brackets. 

For example, an opaque result type can now constrain the primary associated type:

```swift
func readSyntaxHighlightedLines(_ file: String) -> some AsyncSequence<[Token]> {
  ...
}
```

The `concatenate()` function shown earlier can now be written like this:

```swift
func concatenate<S : Sequence<String>>(_ lhs: S, _ rhs: S) -> S {
  ...
}
```

Primary associated types are intended to be used for associated types which are usually provided by the caller. These associated types are often witnessed by generic parameters of the conforming type. For example, `Element` is a natural candidate for the primary associated type of `Sequence`, since `Array<Element>` and `Set<Element>` both conform to `Sequence`, with the `Element` associated type witnessed by a generic parameter. This introduces a clear analogy between the type `Sequence<Int>` on one hand and the types `Array<Int>`, `Set<Int>` on the other hand.

## Detailed design

At the protocol declaration, an optional _primary associated types list_ delimited by angle brackets can follow the protocol name. When present, at least one primary associated type must be declared. Multiple primary associated types are separated by commas. Each primary associated type may optionally declare an inheritance clause. The formal grammar is amended as follows, adding an optional **primary-associated-type-list** production to **protocol-declaration**:

- **protocol-declaration** → attributes<sub>opt</sub> access-level-modifier<sub>opt</sub> `protocol` protocol-name primary-associated-type-list<sub>opt</sub> type-inheritance-clause<sub>opt</sub> generic-where-clause<sub>opt</sub> protocol-body
- **primary-associated-type-list** → `<` primary-associated-type | primary-associated-type `,` primary-associated-type-list `>`
- **primary-associated-type** → type-name typealias-assignment<sub>opt</sub>
- **primary-associated-type** → type-name `:` type-identifier typealias-assignment<sub>opt</sub>
- **primary-associated-type** → type-name `:` protocol-composition-type default-witness<sub>opt</sub>
- **default-witness** → `=` type

Some examples:

```swift
protocol SetProtocol<Element : Hashable> {
  ...
}

protocol PersistentSortedMap<Key : Comparable & Codable, Value : Codable> {
  ...
}
```

A default type witness can be provided, as with ordinary associated type declarations:

```swift
protocol GraphProtocol<Vertex : Equatable = String> {}
```

Additional requirements on the primary associated type can be written with a `where` clause on the protocol or another associated type; the inheritance clause syntax is equivalent to the following:

```swift
protocol SetProtocol<Element> where Element : Hashable {
  ...
}
```

At the usage site, a _constrained protocol_ may now be written with one or more type arguments, like `P<Arg1, Arg2...>`. Specifying fewer type arguments than the number of primary associated types is allowed; subsequent primary associated types remain unconstrained. Adding a list of primary associated types to a protocol is a source-compatible change; the protocol can still be referenced without angle brackets as before.

Note that default associated type witnesses pertain to the conformance, and do not provide a default at the usage site. For example, with `GraphProtocol` above, the constraint type `GraphProtocol` leaves `Vertex` unspecified, instead of constraining it to `String`.

### Constrained protocols in desugared positions

An exhaustive list of positions where the constrained protocol syntax may appear follows. In the first set of cases, the new syntax is equivalent to the existing `where` clause syntax with a same-type requirement constraining the primary associated types.

- The extended type of an extension, for example:

  ```swift
  extension Collection<String> { ... }
  
  // Equivalent to:
  extension Collection where Element == String { ... }
  ```

- The inheritance clause of another protocol, for example:

  ```swift
  protocol TextBuffer : Collection<String> { ... }
  
  // Equivalent to:
  protocol TextBuffer : Collection where Element == String { ... }
  ```
  
- The inheritance clause of a generic parameter, for example:

  ```swift
    func sortLines<S : Collection<String>>(_ lines: S) -> S

    // Equivalent to:
    func sortLines<S : Collection>(_ lines: S) -> S
      where S.Element == String
  ```
  
- The inheritance clause of an associated type, for example:

  ```swift
    protocol Document {
      associatedtype Lines : Collection<String>
    }
  
    // Equivalent to:
    protocol Document {
      associatedtype Lines : Collection
        where Lines.Element == String
    }
  ```
  
- The right-hand side of a conformance requirement in a `where` clause, for example:

  ```swift
    func mergeFiles<S : Sequence>(_ files: S)
      where S.Element : AsyncSequence<String>
  
    // Equivalent to:
    func mergeFiles<S : Sequence>(_ files: S)
      where S.Element : AsyncSequence, S.Element.Element == String
  ```

- An opaque parameter declaration (see [Opaque Parameter Declarations](0341-opaque-parameters.md)):

  ```swift
    func sortLines(_ lines: some Collection<String>)

    // Equivalent to:
    func sortLines <S : Collection<String>>(_ lines: S)

    // In turn equivalent to:
    func sortLines <S : Collection>(_ lines: S)
      where S.Element == String
  ```

- The protocol arguments can contain nested opaque parameter declarations. For example,

  ```swift
  func sort(elements: inout some Collection<some Equatable>) {}
  ```

When referenced from one of the above positions, a conformance requirement `T : P<Arg1, Arg2...>` desugars to a conformance requirement `T : P` followed by one or more same-type requirements:

```swift
T : P
T.PrimaryType1 : Arg1
T.PrimaryType2 : Arg2
...
```

### Constrained protocols in opaque result types

The final location where a constrained protocol may appear is in an opaque result type prefixed by the `some` keyword. In this case, the syntax actually allows you to express something that was previously not possible to write, since we do not allow `where` clauses on opaque result types:

```swift
func transformElements<S : Sequence<E>, E>(_ lines: S) -> some Sequence<E>
```

This example also demonstrates that the argument can itself depend on generic parameters from the outer scope.

Note that since an inheritance clause on a concrete type is not sugar for a generic requirement, we do not allow protocols with generic arguments there, because there is no base type to apply the implied same-type requirement to. For example, the following is not valid:

```swift
struct Lines : Collection<String> { ... }
```

It might be possible to assign some alternate meaning to this, for example introduction of an implied typealias, but that is outside of the scope of this proposal:

```swift
struct Lines : Collection {
  typealias Element = String
}
```

## Alternatives considered

### Annotate regular `associatedtype` declarations with `primary`

Adding some kind of modifier to `associatedtype` declaration shifts complexity to the users of an API because it’s still distinct from how generic types declare their parameters, which goes against the progressive disclosure principle, and, if we choose to generalize this proposal to multiple primary associated types in the future, requires an understanding of ordering on the use-site.

This would also make declaration order significant, in a way that is not currently true for the members of a protocol definition.

Annotation of associated type declarations could make it easier to conditionally declare a protocol which defines primary associated types in newer compiler versions only. The syntax described in this proposal applies to the protocol declaration itself. As a consequence, a library wishing to adopt this feature in a backwards-compatible manner must duplicate entire protocol definitions behind `#if` blocks:

```swift
#if swift(>=5.7)
protocol SetProtocol<Element : Hashable> {
  var count: Int { get }
  ...
}
#else
protocol SetProtocol {
  associatedtype Element : Hashable

  var count: Int { get }
  ...
}
#endif
```

With a hypothetical `primary` keyword, only the primary associated types must be duplicated:

```swift
protocol SetProtocol {
#if swift(>=5.7)
  primary associatedtype Element : Hashable
#else
  associatedtype Element : Hashable
#if

  var count: Int { get }
  ...
}
```

However, duplicating the associated type declaration in this manner is still an error-prone form of code duplication, and it makes the code harder to read. We feel that this use case should not unnecessarily hinder the evolution of the language syntax. The concerns of libraries adopting new language features while remaining compatible with older compilers is not unique to this proposal, and would be best addressed with a third-party pre-processor tool.

### Require associated type names, e.g. `Collection<.Element == String>`

Explicitly writing associated type names to constrain them in angle brackets has a number of benefits:

* Doesn’t require any special syntax at the protocol declaration.
* Explicit associated type names allows constraining arbitrary associated types.
* The constraint syntax generalizes to non-same type requirements e.g. `<.Element: SomeProtocol>`

There are also a number of drawbacks to this approach:

* No visual clues at the protocol declaration about what associated types are useful.
* The use-site may become onerous. For protocols with only one primary associated type, having to specify the name of it is unnecessarily repetitive.
* The syntax can be confusing when the constrained associated type has the same name as a generic parameter of the declaration. For example, the following:

  ```swift
    func adjacentPairs<Element>(_: some Sequence<Element>,
                                _: some Sequence<Element>)
      -> some Sequence<(Element, Element)> {}
  ```
  
  reads better than the hypothetical alternative:
  
  ```swift
    func adjacentPairs<Element>(_: some Sequence<.Element == Element>,
                                _: some Sequence<.Element == Element>)
      -> some Sequence<.Element == (Element, Element)> {}
   ```
   
* This more verbose syntax is not as clear of an improvement over the existing syntax today, because most of the where clause is still explicitly written. This may also encourage users to specify most or all generic constraints in angle brackets at the front of a generic signature instead of in the `where` clause, which goes against [SE-0081](https://github.com/apple/swift-evolution/blob/main/proposals/0081-move-where-expression.md).

Note that nothing in this proposal _precludes_ adding the above syntax in the future; the presence of a leading dot (or some other signifier) should allow unambiguous parsing in either case.

### Generic protocols

This proposal uses the angle-bracket syntax for constraining primary associated types, instead of a hypothetical "generic protocols" feature modeled after Haskell's multi-parameter typeclasses or Rust's generic traits. The idea is that such a "generic protocol" can be parametrized over multiple types, not just a single `Self` conforming type:

```swift
protocol ConvertibleTo<Other> {
  static func convert(_: Self) -> Other
}

extension String : ConvertibleTo<Int> {
  static func convert(_: String) -> Int
}

extension String : ConvertibleTo<Double> {
  static func convert(_: String) -> Double
}
```

We believe that constraining primary associated types is a more generally useful feature than generic protocols, and using angle-bracket syntax for constraining primary associated types gives users what they generally expect, with the clear analogy between `Array<Int>` and `Collection<Int>`.

Nothing in this proposal precludes introducing generic protocols in the future under a different syntax, perhaps something that does not privilege the `Self` type over other types to make it clear there is no functional dependency between the type parameters like there is with associated types:

```swift
protocol Convertible(from: Self, to: Other) {
  static func convert(_: Self) -> Other
}

extension Convertible(from: String, to: Int) {
  static func convert(_: String) -> Int
}

extension Convertible(from: String, to: Double) {
  static func convert(_: String) -> Int
}
```

## Source compatibility

This proposal has no impact on existing source compatibility for existing code. For protocols that adopt this feature, removing or changing the primary associated type will be a source breaking change for clients.

## Effect on ABI stability 

This change does not impact ABI stability for existing code. The new feature does not require runtime support and can be backward-deployed to existing Swift runtimes.

## Effect on API resilience

This change does not impact API resilience. For protocols that adopt this feature, adding or removing a primary associated type list is a binary-compatible change. Changing or removing a primary associated type list is also a binary-compatible change, but is not recommended since it is source-breaking.

## Future Directions

### Standard library adoption

Actually adopting primary associated types in the standard library is outside of the scope of this proposal. There are the obvious candidates such as `Sequence`, `Collection` and `AsyncSequence`, and no doubt others that will require additional discussion.

### Constrained existentials

A natural generalization is to enable this syntax for existential types, e.g. `any Collection<String>`. This is a larger feature that needs careful consideration of type conversion behaviors. It will also require runtime support for metadata and dynamic casts. For this reason it should be covered by a separate proposal.

### Named opaque result types and `where` clauses

A future generalization would add named "output generic parameters" that can be referenced from a `where` clause. If this capability were introduced, then constrained protocol types appearing in opaque result type position would desugar to requirements in a `where` clause, just like they do in all other positions:

```swift
func readLines(_ file: String) -> some AsyncSequence<String> { ... }

// Equivalent to:
func readLines(_ file: String) -> <S> S
  where S : AsyncSequence, S.Element == String { ... }
```

## Acknowledgments

Thank you to Joe Groff for writing out the original vision for improving generics ergonomics — which included the initial idea for this feature — and to Alejandro Alonso for implementing the lightweight same-type constraint syntax for extensions on generic types which prompted us to think about this feature again for protocols.
