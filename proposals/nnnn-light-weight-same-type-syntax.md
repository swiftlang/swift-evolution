# Lightweight same-type requirements for primary associated types

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/main/proposal-templates/NNNN-filename.md)
* Authors: [Pavel Yaskevich](https://github.com/xedin), [Holly Borla](https://github.com/hborla), [Slava Pestov](https://github.com/slavapestov)
* Review Manager: TBD
* Status: Implemented on `main` behind the `-enable-parametrized-protocol-types` feature flag; primary associated types are declared with the interim `@_primaryAssociatedType` attribute rather than the proposed syntax.

## Introduction

As a step toward the goal of improving the UI of generics outlined in [Improving the UI of Generics](https://forums.swift.org/t/improving-the-ui-of-generics/22814#heading--directly-expressing-constraints), this porposal introduces a new syntax for conforming a generic parameter and constraining an associated type via a same-type requirement.

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

## Proposed Solution

We’d like to propose a new syntax for declaring a protocol conformance requirement together with a same-type requirement on the protocol's _primary associated type_. This new syntax looks like the application of a concrete generic type to a type argument, allowing you to write `AsyncSequence<String>` or `AsyncSequence<[Lines]>`. This builds on the user's previous intuition and understanding of generic types and is analogous to `Array<String>` and `Array<[Lines]>`.

Protocols can declare a primary associated type using a syntax similar to a generic parameter list of a concrete type:

```swift
protocol AsyncSequence<Element> {
   associatedtype Iterator : AsyncIteratorProtocol
     where Element == Iterator.Element
   ...
}
```

A protocol declaring a primary associated type can be written with a generic argument in angle brackets from any position where a protocol conformance requirement was previously allowed:

```swift
func readSyntaxHighlightedLines(_ file: String) -> some AsyncSequence<[Token]> {
    ...
}
```

Or the second example of the `concatenate()` function:

```swift
func concatenate<S : Sequence<String>>(_ lhs: S, _ rhs: S) -> S {
   ...
}
```

## Detailed design

At the protocol declaration, only a single primary associated type is allowed. The associated type name may be followed by an optional inheritance clause:

```swift
protocol SetProtocol<Element : Hashable> {
    ...
}
```

Additional requirements on the primary associated type can be written with a `where` clause on the protocol or another associated type; the inheritance clause syntax is equivalent to the following:

```swift
protocol SetProtocol<Element> where Element : Hashable {
    ...
}
```

Declaring a primary associated type on a protocol is a backwards-compatible change; the protocol can still be written without angle brackets as before. Once a primary associated type has been declared on a protocol `P`, the type representation `P<Arg>` can be used anywhere that a conformance requirement is written.

In the first set of cases, the new syntax is equivalent to the existing `where` clause syntax for constraining the primary associated type.

- The extended type of an extension, for example:

  ```swift
  extension Collection<String> { ... }
  
  // Equivalent to:
  extension Collection where Element : String { ... }
  ```

- The inheritance clause of another protocol, for example:

  ```swift
  protocol TextBuffer : Collection<String> { ... }
  
  // Equivalent to:
  protocol TextBuffer : Collection where Element : String { ... }
  ```
  
- The inheritance clause of a generic parameter, for example:

  ```swift
  func sortLines<S : Collection<String>>(_ lines: S) -> S

  // Equivalent to:
  func sortLines<S : Collection>(_ lines: S) -> S
    where S.Element : String
  ```
  
- The inheritance clause of an associated type, for example:

  ```swift
  protocol Document {
    associatedtype Lines : Collection<String>
  }
  
  // Equivalent to:
  protocol Document {
    associatedtype Lines : Collection
      where Lines.Element : String
  }
  ```
  
- The right-hand side of a conformance requirement in a `where` clause, for example:

  ```swift
  func mergeFiles<S : Sequence>(_ files: S)
    where S.Element : AsyncSequence<String>
  
  // Equivalent to:
  func mergeFiles<S : Sequence>(_ files: S)
    where S.Element : AsyncSequence, S.Element.Element : String
  ```

Formally, a conformance requirement `T : P<Arg>` desugars to a pair of requirements:

```swift
T : P
T.PrimaryType : Arg
```

The final location where the type representation `P<Arg>` may appear is in an opaque result type prefixed by the `some` keyword. In this case, the syntax actually allows you to express something that was previously not possible to write, since we do not allow `where` clauses on opaque result types:

```swift
func transformElements<S : Sequence<E>, E>(_ lines: S) -> some Sequence<E>
```

This example also demonstrates that the argument can itself depend on generic parameters from the outer scope.

## Alternatives considered

### Annotate regular `associatedtype` declarations with `primary`

Adding some kind of modifier to `associatedtype` declaration shifts complexity to the users of an API because it’s still distinct from how generic types declare their parameters, which goes against the progressive disclosure principle, and, if we choose to generalize this proposal to multiple primary associated types in the future, requires an understanding of ordering on the use-site.

### Use the first declared `associatedtype` as the primary associated type.

This would make source order load bearing in a way that hasn’t been in the past, and would only support one associated type, which might not be sufficient in the future.

### Require associated type names, e.g. `Collection<.Element == String>`

Explicitly writing associated type names to constrain them in angle brackets has a number of benefits:

* Doesn’t require any special syntax at the protocol declaration.
* Explicit associated type names allows constraining only a subset of the associated types.
* The constraint syntax generalizes for all kinds of constraints e.g. `<.Element: SomeProtocol>`

There are also a number of drawbacks to this approach:

* No visual clues at the protocol declaration about what associated types are useful.
* The use-site may become onerous. For protocols with only one primary associated type, having to specify the name of it is unnecessarily repetitive.
* This more verbose syntax is not as clear of an improvement over the existing syntax today, because most of the where clause is still explicitly written. This may also encourage users to specify most or all generic constraints in angle brackets at the front of a generic signature instead of in the `where` clause, which goes against [SE-0081](https://github.com/apple/swift-evolution/blob/main/proposals/0081-move-where-expression.md).

## Source compatibility

This proposal has no impact on existing source compatibility for existing code. For protocols that adopt this feature, removing or changing the primary associated type will be a source breaking change for clients.

## Effect on ABI stability 

This change does not impact ABI stability for existing code. The new feature does not require runtime support and can be backward-deployed to existing Swift runtimes.

## Effect on API resilience

This change does not impact API resilience. For protocols that adopt this feature, adding or removing a primary associated type is a binary-compatible change. Removing a primary associated type is also a binary-compatible change, but is not recommended since it is source-breaking.

## Future Directions

This proposal works together with the proposal for [Opaque types in parameters](https://github.com/apple/swift-evolution/pull/1527/files), allowing you to write:

```swift
func processStrings(_ lines: some Collection<String>)
```

Which is equivalent to:

```
func processStrings <S : Collection>(_ lines: S)
  where S.Element : String
```

Actually adopting primary associated types in the standard library is outside of the scope of this porposal. There are the obvious candidates such as `Sequence`, `Collection` and `AsyncSequence`, and no doubt others that will require additional discussion.

A natural generalization is to enable this syntax for existential types, e.g. `any Collection<String>`.

## Acknowledgments

Thank you to Joe Groff for writing out the original vision for improving generics ergonomics — which included the initial idea for this feature — and to Alejandro Alonso for implementing the lightweight same-type constraint syntax for extensions on generic types which prompted us to think about this feature again for protocols.
