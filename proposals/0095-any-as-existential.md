# Replace `protocol<P1,P2>` syntax with `Any<P1,P2>`

* Proposal: [SE-0095](0095-any-as-existential.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist), [Austin Zheng](https://github.com/austinzheng)
* Status: **Returned for Revision** [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000182.html)
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

The current `protocol<>` construct, which defines an existential type consisting of zero or more protocols, should be renamed `Any<>`.

[Discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/018109.html)

## Motivation

A stated goal for Swift 3.0 is making breaking changes to prepare the way for features to be introduced in future features, especially those involving the enhancements to the generics system detailed in [*Completing Generics*](https://github.com/apple/swift/blob/master/docs/GenericsManifesto.md).

One such change described in *Completing Generics* is renaming `protocol<>` to `Any<>` in order to allow it to serve as a syntactic foundation for more generalized existential types. This is a straightforward change which will allow a later version of Swift to introduce better handling for existential types without making breaking changes, or changes whose functionality overlaps with that of existing features.

## Proposed solution

The `protocol<...>` construct should be replaced with the `Any<...>` construct, where one or more protocol names can be inserted between the angle brackets to denote protocol composition. There will be no changes to the behavior of `Any<...>` relative to `protocol<...>`.

`Any` will retain the same function and behavior as it did prior to Swift 3.0. `Any<>` will be forbidden. An error message can direct users to use `Any` instead of `Any<>`.

Trivial example:

```swift
protocol A { }
protocol B { }

struct Foo : A, B { }

let a : Any<A, B> = Foo()
```

## Impact on existing code

Programmers will need to update any code using `protocol<...>` (this can be done with a simple find and replace operation). Code that uses `Any`, but no protocol composition, will be unaffected. Code that happens to use `protocol<>` must be changed to use `Any` instead.

## Alternatives considered

A couple of alternative options for proposal details follow.

* The original proposal allowed both `Any<>` and `Any`. However, community members brought up concerns regarding the fact that there were two nearly-identical representations for the 'any type' existential, and that there could possibly be issues cleanly defining the grammar or implementing the parser to properly handle both cases.

### `Any` vs `any`

A discussion took place among swift-evolution participants as to whether or not the keyword for this feature should be `Any` or `any`. This proposal presents `Any`, but also lists reasons provided in favor of both options below, with the hope that the proposal review discussion and core team can choose the best option.

**For `Any<P1, P2>`**:

* The convention is to capitalize types. `Any<A, B>` is immediately apparent as a type, and looks like a type when used in places where types would be used (like function signatures).
* Having `Any<A, B>` allows us to keep the well-established `Any` without having to typealias to `any` or `any<>` forms.
* `any` is a keyword, but an argument can be made that keywords that fit into a particular syntactic slot should be capitalized like normal members of that slot. `Any<...>` fits into the slot of identifiers used as types, so it should be named like a type.
* In the future, `AnySequence` and similar type-erased wrappers can be replaced with, e.g. `Any<Sequence>`. This increases discoverability of existential features, like a future `Any<Sequence where .Element == String>`. It's possible this will increase awareness and use of `Any<...>` over that of `protocol<>`, which is difficult to discover.

**For `any<P1, P2>`**:

* `any<...>`'s lower case 'a' distinguishes it from other generic types that use similar syntax, such as `Array<Int>`. Perhaps developers, especially those new to Swift, will be confused as to why `Any<A, B>` isn't a generic type, but `Dictionary<A, B>` is. Even without considering new developers, it can be jarring to have to mentally make the context switch between `Any<A, B>` as an existential, and `AnythingButAny<A, B>` as a generic type.
* `any<...>`'s lower case 'a' makes it clear to users it is not equivalent to a standard user-defined type, but rather a construction that can be used as a type in some cases, and can't be used everywhere a user-defined type can.
* `any<...>` isn't a specific type - it's a kind of type (an existential), and this spelling fits better with the other 'kind' names: `class`, `struct`, `enum`, `protocol`
* `any` is a keyword, and a convention has been established that keywords are lower case without initial or CamelCase-style capitalization. It is important to be consistent in this matter.

### Alternatives to entire proposal

A couple alternatives to this entire proposal follow.

* Leave `protocol<>` as-is, and decide whether to change it after Swift 3.0 ships. This has the disadvantage of introducing a breaking source change.

* Decide before Swift 3.0 ships that generalized existentials should be defined using a syntax besides the `protocol<>` or `Any<>` syntaxes, and adopt that syntax instead. Disadvantages: core team has no bandwidth to consider changes of this scope at the current time.

## Acknowledgements

[Matthew Johnson](https://github.com/anandabits) and [Brent Royal-Gordon](https://github.com/brentdax) provided valuable input which helped shape this proposal.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
