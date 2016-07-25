# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Michael Gottesman](https://github.com/gottesmm)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Iterators are very important for performance since we use them for for loops. By default collections if they do not provide a custom iterator use IndexingIterator as an iterator. IndexingIterator, while only supporting forward movement, is based on indices which possess the ability to go backwards and forwards. For some indices, backwards iteration adds unnecessary cost/complexity. In order to preserve future flexibility, we want to change certain of the types to use custom types that are essentially just IndexingIterator<T>. Then later on when we want to implement these optimizations, we can do it on the custom type underneath the hood without changing the API/ABI.

Swift-evolution thread: [[Proposal] Change some collection iterators to use custom types instead of IndexIterator<T>](http://article.gmane.org/gmane.comp.lang.swift.evolution/24822)

## Motivation

Describe the problems that this proposal seeks to address. If the
problem is that some common pattern is currently hard to express, show
how one can currently get a similar effect and describe its
drawbacks. If it's completely new functionality that cannot be
emulated, motivate why this new functionality would help Swift
developers create better Swift code.

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

## Impact on existing code

Describe the impact that this change will have on existing code. Will some
Swift applications stop compiling due to this change? Will applications still
compile but produce different behavior than they used to? Is it
possible to migrate existing Swift code to use a new feature or API
automatically?

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

