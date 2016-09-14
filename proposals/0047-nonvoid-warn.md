# Defaulting non-Void functions so they warn on unused results

* Proposal: [SE-0047](0047-nonvoid-warn.md)
* Authors: [Erica Sadun](http://github.com/erica), [Adrian Kashivskyy](https://github.com/akashivskyy)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000075.html)
* Bug: [SR-1052](https://bugs.swift.org/browse/SR-1052)


## Introduction
In Swift's current incarnation, annotating methods and functions with `@warn_unused_result` informs the compiler that a non-void return type *should be consumed*. It is an affirmative declaration. In its absence, ignored results do not raise warnings or errors.

In its present form, this declaration attribute primarily differentiate between mutating and non-mutating pairs. It  offers an optional `mutable_variant` for when an expected return value is not consumed. For example, when `sort` is called with an unused result, the compiler suggests using `sortInPlace` for unused results.

```swift
@warn_unused_result(mutable_variant="sortInPlace")
public func sort() -> [Self.Generator.Element]
```

This proposal flips this default behavior. Unused results are more likely to indicate programmer error than confusion between mutating and non-mutating function pairs. This proposal makes "warn on unused result" the *default* behavior for Swift methods and functions. Developers must override this default to enable the compiler to ignore unconsumed values.

This proposal was discussed on-list in a variety of threads, most recently [Make non-void functions @warn_unused_result by default](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/010926.html).

#### Acceptance Notes

The Core Team and much of the community agreed that this proposal directly aligns with the spirit of the Swift language, enabling the compiler to warn about obvious omissions in code that may be bugs. 

The `@discardableResult` attribute enables API authors to indicate when their functions and methods produce a non-essential result and should not produce a warning. Clients of unannotated APIs may employ the simple and local solution to silence the warning and willfully ignore the result. This code (the `_ =` pattern) expresses thoughtful intent and communicates this intent to future maintainers of a codebase.

The Core Team requested the proposal be revised to update the Detail Design section to add the default import scheme for the Clang importer. "Once the basic pure-Swift implementation of this lands, we can evaluate extending these rules to imported declarations as well, but that discussion should include empirical evidence that evaluates the impact on real-world code."

## Motivation

In current Swift, the following code compiles and runs without warning:

```swift
4 + 5
```

Outside of a playground, where evaluation results are of interest in and of themselves, it's unlikely any programmer would write this code intending to execute an addition and then discard the result.  Inverting Swift's default warning polarity ensures that developers can locate and inspect unconventional uses. If they approve the code, they can silence warnings by adding a `_=` pattern. This should significantly reduce real-world bugs due to the accidental omission of code that consumes results. 

Real world situations where it makes sense from a compiler point of view to discard non-Void results are rare. Examples of these API calls include `NSUserDefaults`' `synchronize` function (returns `Bool`) and mutating collection methods that return elements upon removing them. These examples belongs to a subset of methods that are primarily executed for their side effects although they also provide a return value. These methods should not generate a warning or require `_=` as  return value use is truly optional. 

```swift
/// Remove an element from the end of the ArraySlice in O(1).
///
/// - Requires: `count > 0`.
public mutating func removeLast() -> Element
```

To solve this problem, we propose introducing a `@discardableResult` attribute to automatically silence compiler warnings, enabling calling functions for side effects.  The proposed change enables developers to *intentionally* permit discarded results by annotating their declarations. 

## Detail Design

Under this proposal, the Swift compiler emits a warning when any method or function that returns a non-void value is called without using its result. To suppress this warning, the developer must affirmatively mark a function or method, allowing the result to be ignored. It can be argued that adding an override is unnecessary as Swift offers a mechanism to discard the result:

```swift
_ = discardableResult()
```

While this workaround makes it clear that the consumption of the result is intentionally discarded, it offers no traceable intent as to whether the API designer meant for this use to be valid.  Including an explicit attribute ensures the discardable return value use is one that has been considered and approved by the API author.

The approach takes the following form:

```swift
@discardableResult func f() -> T {} // may be called as a procedure as f()
                                    // without emitting a compiler warning
func g() -> T {} // defaults to warn on unused result
func h() {} // Void return type, does not fall under the umbrella of this proposal
```

The following examples demonstrate the `@discardableResult` behavior:

```swift
let c1: () -> T = f    // no compiler warning
let c2: () -> Void = f // compiler error, invalid conversion
let c3 = f // assignment does not preserve @discardableResult attribute
c3()       // compiler warning, unused result
_ = c3()   // no compiler warning
```


#### Review Period Notes

* During the review period on Swift Evolution, the term `@discardable` was preferred over `@discardableResult`. Community members encouraged picking a shorter keyword.
* Alternative names considered included: `@allowUnusedResult`, `@optionalResult`, `@suppressUnusedResultWarning`, `@noWarnUnusedResult`, `@ignorableResult`, `@incidentalResult`,  `@discretionaryResult`, `@discardable`, `@ignorable`, `@incidental`, `@elective`, `@discretionary`, `@voluntary`, `@voidable`, `@throwaway`, and `@_` (underscore).


#### Mutating Variants

The original design for `@warn_unused_result` provides optional arguments 
for `message` and `mutable_variant` parameters. These parameters customize warnings
when a  method or function is called without consuming a result.
This proposal introduces two new document comment fields, 
`MutatingCounterpart` and `NonmutatingCounterpart`. 
These replace the roles of the former `mutable_variant` and `message` arguments. 
Under this scheme, `@discardableResult` will not use arguments.
Documentation comment fields will, instead, supply usage recommendations in both directions. 
We hope these keywords will cooperate with the code completion engine the [same way](https://github.com/apple/swift/blob/master/CHANGELOG.md) 
that Swift currently handles `Recommended` and `RecommendedOver`.

Documentation-based cross referencing provides a valuable tool for developers seeking 
correspondence between two related functions. By adding a highlighted field to documentation, 
both the mutating and non-mutating variations can direct developer attention to their counterpart.
Named keywords instantly identify why the documentation is calling these items
out rather than establishing some general relationship with the more generic `SeeAlso` documentation field. 
QuickHelp highlighted keywords support the expert and guide the beginner. Mutation pair keywords add value in a way `SeeAlso` cannot.

**Being a documentation expansion, this approach excludes compile-time verification of method/function signatures.**

#### Default Migration Behavior

While `@discardableResult` and a "warn on unused result" default seems like a great direction for the standard library and other pure-Swift code, its impact on imported C and Objective-C APIs remains less clear.  The Core Team expressed significant concern that warnings would be widespread and overwhelm users with a flurry of confusing, useless cautions.  

__As such, the Core Team decided that the Clang importer will default to _automatically add_ the `@discardableResult` attribute to all non-Void imported declarations (specifically, ones that are not marked with the Clang `((warn_unused_result))` attribute) upon adoption of this proposal.__

Once the basic pure-Swift implementation of this lands, the Core Team and the extended Swift community can evaluate extending these rules to imported declarations as well. That discussion should and will include empirical evidence that evaluates impact on real-world code. 

## Future directions

#### Decorating Type
The Swift Evolution community discussed decorating the type rather than the declaration. 
Decorating the return type makes it clear that it's the result that can be optionally treated as discardable rather than the function whose role it is to police its use.

```swift
func f() -> @discardable T {} // may be called as a procedure as f() 
                              // without emitting a compiler warning
```

This approach was discarded to reduce the type system impact and complexity of the proposal.  When not coordinated with the base function type, currying or "taking the address" of a function could effectively remove the @discardableResult attribute. This means some use of an otherwise `@discardable` function value would have to use `_ =`.  While this approach was considered more elegant, the additional implementation costs means that it's best to delay adopting type decoration 
until such time as there's a strong motivation to use such an approach.

#### Objective-C Annotation

During review, some community members requested a new attribute enabling exceptional imported functions to be properly annotated from Objective-C source.

#### Swift Type Annotation

Another topic raised during review requested that the attribute annotate types as well as functions. This would allow "the default behavior to be changed on a per-type basis, as this would be useful for types that are specifically designed with method chaining for example (where most results are discardable as standard). While the choice of default will never satisfy everyone, this would make it easy to tweak for your own needs."

## Snake Case

Upon acceptance, this proposal removes two of the last remaining instances of snake_case in the Swift language. This further brings the language into a coherent and universal use of lowercase and camel case variants.

## Acknowledgements

Changing the behavior of non-void functions to use default warnings for unused results was initially introduced by Adrian Kashivskyy. Additional thanks go out to Chris Lattner, Gwendal Roué, Dmitri Gribenko, Jeff Kelley, David Owens, Jed Lewison, Stephen Cellis, Ankit Aggarwal, Paul Ossenbruggen,Brent Royal-Gordon, Tino Heth, Haravikk, Félix Cloutier,Yuta Koshizawa, 
for their feedback on this topic.
