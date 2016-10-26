# Implement The Pipeline Operator

* Proposal: [SE-0145](0145-implement-the-pipeline-operator.md)
* Authors: [Matheus Albuquerque](https://github.com/ythecombinator)
* Review Manager: TBD
* Status: **Awaiting review**

## Sidenote

I do think that implementing a **Function Composition Operator** - e.g.
`>>` - would be in the very same scope of this proposal but, in order to make
this proposal more *atomic*, changes here are concerned only to the
**Pipeline Operator**.

The composition operators take two functions and return a function; by contrast,
the pipeline operators take a function and an argument and return a value.

## Introduction

This proposal introduces a new operator `|>` - found in many other languages
such as 
[F#](https://en.wikibooks.org/wiki/F_Sharp_Programming/Higher_Order_Functions#The_.7C.3E_Operator), 
[OCaml](http://caml.inria.fr/pub/docs/manual-ocaml/libref/Pervasives.html#VAL%28|%3E%29), 
[Elixir](https://www.safaribooksonline.com/library/view/programming-elixir/9781680500530/f_0057.html)
and many others; as well as UNIX pipes. It's a simple - yet 
**backwards-compatible** - way of streamlining chained function calls in a 
**readable**, **functional** manner.

## Motivation

Using the `.` operator is the most common - and clean as well - way to chain together instance method calls.

However, it does not help when we want to chain together method calls between distinct entities or stand-alone functions.

Let's say we have the following simple function definitions:

```swift
// Takes a single value of type `Int` and increments it:

func increment(x: Int) -> Int {
    return x + 1
}

// Takes a single value of type `Int` and squares it:

func square(x: Int) -> Int {
    return x * x
}
``` 

To increment and afterwards square a value, we would do something like this:

```swift
let myValue: Int = 66

let myNewValue: Int = square(increment(myValue))
``` 

We have to read the function applications **inside-out**. First, 
`increment(myValue)` is evaluated, and then the result of that expression is 
passed to the `square` function. Yet, from left to right, we write square before
increment, **messing the application order**.

## Proposed solution

Describe your solution to the problem. Provide examples and describe
how they work. Show how your solution is better than current
workarounds: is it cleaner, safer, or more efficient?

## Detailed design

Describe the design of the solution in detail. If it involves new
syntax in the language, show the additions and changes to the Swift
grammar. If it's a new API, show the full API and its documentation
comments detailing what it does. The detail in this section should be
sufficient for someone who is *not* one of the authors to be able to
reasonably implement the feature.

## Source compatibility

Relative to the Swift 3 evolution process, the source compatibility
requirements for Swift 4 are *much* more stringent: we should only
break source compatibility if the Swift 3 constructs were actively
harmful in some way, the volume of affected Swift 3 code is relatively
small, and we can provide source compatibility (in Swift 3
compatibility mode) and migration.

Will existing correct Swift 3 or Swift 4 applications stop compiling
due to this change? Will applications still compile but produce
different behavior than they used to? If "yes" to either of these, is
it possible for the Swift 4 compiler to accept the old syntax in its
Swift 3 compatibility mode? Is it possible to automatically migrate
from the old syntax to the new syntax? Can Swift applications be
written in a common subset that works both with Swift 3 and Swift 4 to
aid in migration?

## Effect on ABI stability

Does the proposal change the ABI of existing language features? The
ABI comprises all aspects of the code generation model and interaction
with the Swift runtime, including such things as calling conventions,
the layout of data types, and the behavior of dynamic features in the
language (reflection, dynamic dispatch, dynamic casting via `as?`,
etc.). Purely syntactic changes rarely change existing ABI. Additive
features may extend the ABI but, unless they extend some fundamental
runtime behavior (such as the aforementioned dynamic features), they
won't change the existing ABI.

Features that don't change the existing ABI are considered out of
scope for [Swift 4 stage 1](README.md). However, additive features
that would reshape the standard library in a way that changes its ABI,
such as [where clauses for associated
types](https://github.com/apple/swift-evolution/blob/master/proposals/0142-associated-types-constraints.md),
can be in scope. If this proposal could be used to improve the
standard library in ways that would affect its ABI, describe them
here.

## Effect on API resilience

API resilience describes the changes one can make to a public API
without breaking its ABI. Does this proposal introduce features that
would become part of a public API? If so, what kinds of changes can be
made without breaking ABI? Can this feature be added/removed without
breaking ABI? For more information about the resilience model, see the
[library evolution
document](https://github.com/apple/swift/blob/master/docs/LibraryEvolution.rst)
in the Swift repository.

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.
