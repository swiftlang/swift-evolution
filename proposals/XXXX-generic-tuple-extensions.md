# Tuple Extensions

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/XXXX-generic-tuple-extensions.md)
* Author: [Robert Widmann](https://github.com/codafi)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

In Swift, the compiler treats tuples as magic objects and automatically
generates the necessary machinery to allow for safe indexing, destructuring
in `var` and `let` bindings, etc.  As of
[SE-0015](https://github.com/apple/swift-evolution/blob/master/proposals/0015-tuple-comparison-operators.md)
the standard library also privileges a certain class of lower-arity tuples by
giving them comparison operator implementations.  This proposal is about
formalizing that pattern in the language itself by allowing for tuples to be
extended as though they were plain Swift datatypes.

Swift-evolution thread: [link to the discussion thread for this proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160502/016446.html)

## Motivation

Because Swift is not a curried-by-default language things like the root data
structure for most declarations down to the look and feel of syntax is either
directly or indirectly related to tuples.  The compiler has already privileged
tuples by automatically generating the proper accessors for their respective
indexes, or generating named member accessors to elements.  Yet tuples remain
opaque to the end user - they are not declared anywhere in the standard library,
nor are they extensible in any sense.  For a language where tuples are already
treated so well, it seems a shame that this is the case, especially when many
protocols that operate on regular nominal types have implementations that scale
intuitively to tuples of arbitrary arity.  

For a more concrete example, a portion of the Complete Generics Manifesto and
SE-0015 expounds on conditional conformances to protocols.  In the interest of
preparing for the proposal that implements that, allowing tuples to be extended
means the existing machinery that makes tuples comparable can be lifted into a
proper instance of `Equatable` and `Comparable` for those tuples when the time
comes.

## Proposed solution

The following will now be valid extension declarations (with a nod to Rust
for the outline of the syntax):

```swift
extension () : Equatable { }

func == (_ : () , _ : ()) -> Bool {
  return true
}
```

```swift
extension (A, B) {
  func mapFst<C>(f : A -> C) -> (C, B) {
    return (f(self.0), self.1)
  }

  func mapSnd<C>(f : B -> C) -> (A, C) {
    return (self.0, f(self.1))
  }

  func bimap<C, D>(f : A -> C, _ g : B -> D) -> (C, D) {
    return self.mapFst(f).mapSnd(g)
  }
}
```

```swift
extension (A, B, C, D, E, F, G, H, I, J) {
  func jumble() -> (J, A, E, F, H, I, B, C, D, G) {
    return (self.9, self.0, self.4, self.5, self.7, self.8, self.1, self.2, self.3, self.6)
  }
}
```

In future, the following will be enabled

```swift
extension (A, B) : Equatable where A : Equatable, B : Equatable {}

func == <A : Equatable, B : Equatable>(l : (A, B), r : (A, B)) -> Bool {
  return l.0 == r.0
      && l.1 == r.1
}

extension (A, B, C) : Equatable where A : Equatable, B : Equatable, C : Equatable {}

func == <A : Equatable, B : Equatable, C : Equatable>(l : (A, B, C), r : (A, B, C)) -> Bool {
  return l.0 == r.0
      && l.1 == r.1
      && l.2 == r.2
}

/// Etc.
```

## Detailed design

The grammar for protocol extensions will be amended to allow tuple extensions
of any (non-singular) arity as valid `extension-declaration`s

```diff

GRAMMAR OF A GENERIC PARAMETER CLAUSE
‌+ generic-tuple-clause → () | ( generic-parameter , generic-parameter-list )

GRAMMAR OF AN EXTENSION DECLARATION
+ extension-declaration → access-level-modifier (opt) extension generic-tuple-clause requirement-clause (opt) extension-body
```

Care has been taken in the grammar to remove ambiguity around extensions to
single-argument tuples, which are invalid as they would allow extension to
every type simultaneously.  An undesirable feature to say the least.  

Members of extensions to tuples of a specific arity and protocol conformance
will function as though they were members of all conforming tuples of that
arity.

## Impact on existing code

Because this is a purely additive change, this will not affect existing code.

## Alternatives considered

A tuple is not an opaque object in most modern programming languages, but in
lowering them out of the realm of compiler magic those same languages have
resorted to nasty hacks. For example:

- In Haskell, one should theoretically be able to declare a
typeclass instance for a tuple of any arity.  In practice, tuple declarations
larger than 62 elements crash GHC and so a hard limit exists (though one a
"reasonable programmer" shouldn't hit).  

- In Scala, they chose to implement TupleN for tuples of arity 1-22.  In doing
so, they must have artificially limited themselves to that particular arity.  
They cite the same "reasonable programmer" excuse as above.  

- In Rust, their implementation of generic tuple extensions seems most fleshed
out, yet is artificially limited by their type system implementation.

In Swift, we could very well follow a combination of the above and force tuples
to be implemented in the standard library. But, we would be stuck implementing N
different structures over each type for something that can easily be, and has
demonstrably been, automated.  

With Higher Kinded Types and an implementation of Kind Polymorphism it would be
possible to bring a clean implementation of a variadic tuple down into the
Swift Standard Library.  Because such language features have yet to
materialize in proposals in any practical sense they are, unfortunately,
orthogonal to the discussion at hand.

-------------------------------------------------------------------------------

# Rationale

On Smarch 13, 20XX, the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
