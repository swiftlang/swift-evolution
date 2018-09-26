# Ownership Annotations

* Proposal: [SE-XXXX](XXXX-ownership-annotations.md)
* Authors: [Robert Widmann](https://github.com/Codafi)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

This proposal adds the `borrow`† type annotation.  With it, Swift users will be able to opt in to 
value-type and ARC optimizations safely, easily, and reliably.  To complement `borrow`, we are also proposing the
`consume`† type annotation and the `consuming`† member function attribute that signal a parameter will be 
passed with the existing parameter-passing convention.

As it stands, Swift has one user-facing parameter passing convention: `owned`.  Under the rules of this
convention, a function's arguments must be retained or copied before being passed.  It is then the
responsibility of that function to balance the +1 reference count or destroy the copied value.  Naturally,
if this is done for the arguments of every function, a large amount of ARC traffic and copies are generated
for values that, more often than not, have lifetimes that extend through the function call anyway.

Though the optimizer is capable of detecting and eliding some of this unnecessary ownership balancing,
it cannot catch every case, or worse, may make the decision not to perform the optimization at all after
a change has occured.  Providing these ownership annotations gives Swift users deterministic performance
guarantees that are safe and easy to adopt wherever they see fit.

This proposal is a core part of the Ownership feature described in the 
[ownership manifesto](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md). 

## Motivation

### Shared

The semantics of `borrow` parameters first appeared in languages like [Mezzo](http://protz.github.io/mezzo/)
and [Rust](https://www.rust-lang.org/en-US/) where they are used in conjunction with
type system extensions and ownership systems to check that an aliasable reference
is read-only.  By providing this kind of control over ownership, a class of data races
on these values is provably impossible and an avenue for performance wins immediately opens up.

Swift already provides a number of optimizations for function parameters involving value
types.  Among these, the compiler is capable of eliding a copy by taking an immutable 
reference to the memory associated with a value - the convention currently in use for
the `self` parameter of non-`mutating` functions.  Providing a `borrow` type annotation
allows users a way to explicitly request copy elision for particular parameters.  In many
cases, providing a marked speedup for function calls and a strong hint to the optimizer
that helps it streamline the body of functions themselves.

For reference types, `borrow` provides a guarantee that a reference will survive for the
duration of a call.  Additionally, because the reference is immutable for that period,
and with help of the [Law of Exclusivity](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md#the-law-of-exclusivity), we have a guarantee that the reference will not be mutated out from under us.  Using this, 
we can elide a retain-release pair for the argument that would otherwise be necessary to 
guarantee its lifetime, providing an overall reduction in ARC traffic.

### Owned

For the times when `borrow` access to a value would be inappropriate, or when ownership of a value 
should be an explicit part of the interface, we provide the `consume` annotation on parameter types 
and the `consuming` attribute on function declarations.  `consume` function parameters are 
"consumed" by that function; the existing default for function parameters.  For value types, this means
the function must recieve a copy and is responsible for destroying that copy when it exits.  For reference
types, the function must recieve the value +1 and is responsible for decrementing the reference count at
exit.

The `consuming` attribute on member functions indicates that the function accepts the `self` parameter using this
`consume` convention.  In the future, for `moveonly` types, this can be used to provide behaviors like guaranteed 
resource destruction for value types.

## Proposed solution

The compiler shall be modified to accept the `borrow` and `consume` parameter type annotations and the 
`consuming` member function attribute.

## Detailed design

### Grammatical Changes

The Swift language will be amended to support the addition of the `borrow` and `consume` type annotations.

```diff
GRAMMAR OF A TYPE ANNOTATION

type-annotation → : attributes(opt) inout(opt) type
+type-annotation → : attributes(opt) borrow(opt) type
+type-annotation → : attributes(opt) consume(opt) type
```

In addition, the grammar of function declarations will be amended to support the `consuming` attribute.

```diff
-mutation-modifier → mutating | nonmutating
+self-ownership-convention → mutating | nonmutating | consuming
```

### Semantic Changes

From a semantic perspective, parameters marked `borrow` behave similarly to existing `consume` 
parameters and are mostly transparent to type checking.  For this reason, and to encourage
users to easily experiment with the addition and removal of `borrow` from parameter types,
we do not allow overloading on the presence or absence of the `borrow` attribute.  This also
means that protocol requirements cannot be satisfied by functions that mix `borrow` and `consume`
versions of parameters that would otherwise have the same type.

Similarly, functions marked `consuming` behave like existing `nonmutating` functions but
may not be mixed in protocol requirements.  For the same reason it is also not a vector
for overloading.

In the interest of progressive disclosure, if no parameter convention is specified, a 
compiler-provided default will be selected - currently the `owned` convention, corresponding to
the `consume ` annotation.  Unannotated witnesses to a protocol requirement that specifies ownership
shall inherit the ownership annotations of the requirement.  In short, a protocol vendor is free 
to change ownership annotations without fear of an API-breaking change for clients that did not
explicitly opt-in to working with ownership annotations.

### SIL

Parameters marked `borrow` will be lowered to the `@guaranteed` calling convention.  The
mangling will be updated to account for the `borrow` attribute in function types.

## Source compatibility

No change.  This proposal is purely additive.

## Effect on ABI stability

The addition of the `borrow` type annotation to function type signatures
necesarily means it needs a place in the function type mangling.  The `consume`
attribute, being the existing default, has no effect.

## Effect on API resilience

Adding and removing `borrow` on a parameter type, like adding and removing
`inout` on a parameter type, is not an ABI-compatible change.  Unlike
adding and removing `inout`, in most cases it is an API-compatible change.

Replacing a `nonmutating` function by an equivalent `consuming` function is similarly
an API compatible change unless it changes a protocol requirement.

## Future directions

Ownership annotations are a critical part of the future goals of the [Ownership Manifesto](https://github.com/apple/swift/blob/master/docs/OwnershipManifesto.md).  In particular, the
need for a non-owning ownership annotation is required to correctly model non-consuming
interactions with `moveonly` types and contexts.  They also form a crucial part of a
potentially more efficient semantics for local variables, coroutines, and iterators. See
the manifesto for further details.

## Alternatives considered

Continuing to let the optimizer transparently make this decision for users instead
of giving them tools to control ownership.

### Naming†

To concretize discussion of names, some alternatives are provided below.  The end goal is
a name the accurately conveys the semantics of each of the annotations, while also maintaining
consistency with the existing modifiers (`mutating` and `nonmutating`) and type annotations (`inout`).

borrow   | consuming    | consume
-------- | -------------| --------
share[d] | owning       | own[ed]
ref      | taking       | take
byref    | in           | transfer

### Mixing Ownership In Protocol Witnesses

The compiler is capable of automatically forming the thunks necessary to allow mixing of ownership conventions between
protocol requirements and their witnesses.  This means that the restriction on ownership-annotation mismatches
could be lifted.  However, we believe that this would be detrimental in a number of ways:

- Though the user's annotation specifies *their* expectation of the ownership-convention of a given parameter, a
  protocol with explicit ownership annotations indicates the API vendor expects a certain kind of usage to follow
  naturally from its definition.  Allowing user overrides dilutes that expectation.
- Mixing ownership annotations introduces thunking - thunking is not free.  If a requirement is annotated `borrow` and
  its witness annotated `consume` the compiler will emit a thunk between these conventions that copies anyways.  In addition
  to the overhead of the copy, if you are in a non-inlineable context, you also incur the cost of the thunk.
- Mixing ownership annotations will cause headaches in a future world where `moveonly` types play a role.  If a witness
  that mixes ownership annotations comes under the scope of a `moveonly` context, an API and ABI-breaking change is
  required to correct it.  If we allow for this transparently, it would enable users to void the consumption contract
  with `moveonly` types accidentally.
