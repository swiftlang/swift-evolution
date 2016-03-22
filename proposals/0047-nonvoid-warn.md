# Defaulting non-Void functions so they warn on unused results

* Proposal: [SE-0047](proposals/0047-nonvoid-warn.md)
* Author(s): [Erica Sadun](http://github.com/erica), [Adrian Kashivskyy](https://github.com/akashivskyy)
* Status: **Scheduled for review** March 16...21, 2016
* Review manager: [Chris Lattner](https://github.com/lattner)

## Introduction
In Swift's current incarnation, annotating methods and functions with `@warn_unused_result` informs the compiler that a non-void return type *should be consumed*. It is an affirmative declaration. In its absence, ignored results do not raise warnings or errors.

In its present form, this declaration attribute primarily differentiate between mutating and non-mutating pairs. It  offers an optional `mutable_variant` for when an expected return value is not consumed. For example, when `sort` is called with an unused result, the compiler suggests using `sortInPlace` for unused results.

```swift
@warn_unused_result(mutable_variant="sortInPlace")
public func sort() -> [Self.Generator.Element]
```

This proposal flips this default behavior. Unused results are more likely to indicate programmer error than confusion between mutating and non-mutating function pairs. This proposal makes "warn on unused result" the *default* behavior for Swift methods and functions. Developers must override this default to enable the compiler to ignore unconsumed values.

This proposal was discussed on-list in a variety of threads, most recently [Make non-void functions <at> warn_unused_result	by default](http://article.gmane.org/gmane.comp.lang.swift.evolution/8417).

## Motivation

In current Swift, the following code compiles and run without warning:

```swift
import Darwin

sin(M_PI_4)
```

Outside of a playground, where evaluation results are of interest in and of themselves, it's unlikely any programmer would write this code intending to execute a Sine function and then discard the result.

It is exceedingly rare to find a real world example where it makes sense from a compiler point of view to discard non-Void results. I was able to track down discardable results in application code in `NSUserDefaults`' `synchronize` function (returns `Bool`) and, to stretch a little, `printf` (returns an `int`). Many collection methods return elements upon removing them, whether those elements are needed by a receiver or not:

```swift
/// Remove an element from the end of the ArraySlice in O(1).
///
/// - Requires: `count > 0`.
public mutating func removeLast() -> Element
```

Some APIs return opaque objects, including tokens, that aren't always needed. `NSNotificationCenter` returns an observer object when you call its `addObserverForName(_:object:queue:usingBlock:)` method. For short-lived observers, you save the reference and later call `removeObserver(_:)`. When the observer lasts the lifetime of an application, the return value may not ever be used.

The proposed change forces developers to *intentionally* allow discarded results by annotating their declarations for those rare times when discarded results are explicitly allowed by the API. This should significantly reduce real-world bugs due to the accidental omission of code that consumes results.

Consumers can work around unaudited APIs by introducing a `_ = *some call*` pattern when they truly do not wish to handle a return value. In such cases, this proposal recommends a general policy of copious commenting. Any further nagging is left as an exercise for third party linters. This is an easily recognizable pattern.

In the four examples mentioned here, this proposal makes the following recommendations:

* `NSUserDefaults` example: probably (but not absolutely) marked as a discardable result. The highly conventional use of this call never checks that state. It does, however, return an error state. Whether one *should* call `synchronize` or not lies outside the scope of this proposal. 
* `NSObservervationCenter` example: should not be marked. Most observer lifetimes will be shorter than the application's lifetime and view controllers should clean up after themselves when dismissed, hidden, or otherwise put away. The compiler should emit warnings about this use that the developer must override.
* Collections example: This could be argued either way. In such a situation, should be left unmarked. Leaving the implementation unmarked encourages an act from the consumer to either handle the result or actively dimiss the warning.
* `printf` example: importing C calls is left as an exercise for the Swift team

*Note: This proposal does not ignore the positive utility of pairing in-place/procedural and value-returning/functional implementations and retains the ability to enable Xcode system to cross reference between the two. We propose that the declaration attribute surrenders that responsibility and passes it to the rich documentation comment system.*

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

### Mutating Variants
The Swift [master change log](https://github.com/apple/swift/blob/master/CHANGELOG.md) notes 
the introduction of doc comment fields that engage with the code completion engine to 
deliver better results:

> Three new document comment fields, namely - keyword:, - recommended: and - recommendedover:, allow Swift users to cooperate with code completion engine to deliver more effective code completion results. The - keyword: field specifies concepts that are not fully manifested in declaration names. - recommended: indicates other declarations are preferred to the one decorated; to the contrary, - recommendedover: indicates the decorated declaration is preferred to those declarations whose names are specified.

This proposal recommends introducing two further comment fields, specifically `mutatingVariant` and `nonmutatingVariant` to take over the role of the former `mutable_variant:` argument and offer recommendations in both directions. It's worth noting the disadvantage of this approach in that this excludes compile-time verified method/function signatures for alternative implementations.

The `message` argument that formerly provided a textual warning when a function or method was called with an unused result will be discarded entirely and subsumed by document comments. Under this scheme, whatever attribute name is chosen to modify function names or return types will not use arguments.

## Alternative Names Considered

Alternative names considered included names were considered: `@allowUnusedResult`, `@optionalResult`, `@suppressUnusedResultWarning`, `@noWarnUnusedResult`, `@ignorableResult`, `@incidentalResult`, and `@discretionaryResult`.

## Future directions

The Swift Evolution community also discussed decorating the type rather than the declaration. 
Decorating the return type makes it clear that it's the result that can be optionally treated as discardable rather than the function whose role it is to police its use.

```swift
func f() -> @discardable T {} // may be called as a procedure as f() 
                              // without emitting a compiler warning
```

This approach was discarded to reduce the type system impact and complexity of the proposal.  When not coordinated with the base function type, currying or "taking the address" of a function could effectively remove the @discardableResult attribute. This means some use of an otherwise `@discardable` function value would have to use `_ =`.  While this approach was considered more elegant, the additional implementation costs means that it's best to delay adopting type decoration 
until such time as there's a strong motivation to use such an approach.

Keywords considered for decorating the type included: `@discardable`, `@ignorable`, `@incidental`, `@elective`, `@discretionary`, `@voluntary`, `@voidable`, `@throwaway`, and `@_` (underscore).

## Unconventional Alternatives

David Owens suggests introducing a non-attribute solution for unwarned results, by overloading based on return-type. The
approach goes like this:

```swift
// Create a normal version with a return type
func removeLast() -> Self.Generator.Element { ... }

// Create a Void version that consumes the return value
func removeLast() { _ = removeLast() }

// If you do not use the return value, there's no warning
// because a Void variation exists
foo.removeLast()

// The original, non-Void version continues to work as well
let item = foo.removeLast()
```

This alternative requires no custom attributes and enables developers to customize any 
side-effects for Void versions of their functions However, as Owens notes, "Of the problems 
[of Swift] is that it's just not good at picking the one you want". If this obstacle could be 
surmounted, this would offer a simple, elegant solution.

## Snake Case

It should be noted that this proposal, if accepted, removes two of the last remaining instances of snake_case in the Swift language. This further brings the language into a coherent and universal use of lowercase and camel case variants.

## Acknowledgements

Changing the behavior of non-void functions to use default warnings for unused results was initially introduced by Adrian Kashivskyy. Additional thanks go out to Chris Lattner, Gwendal Roué, Dmitri Gribenko, Jeff Kelley, David Owens, 
Stephen Cellis, Ankit Aggarwal, Paul Ossenbruggen,
for their feedback on this topic.