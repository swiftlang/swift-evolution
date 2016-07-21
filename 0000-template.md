# Feature name

* Proposal: [SE-NNNN](NNNN-filename.md)
* Author: [Swift Developer](https://github.com/swiftdev)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

A short description of what the feature is. Try to keep it to a
single-paragraph "elevator pitch" so the reader understands what
problem this proposal is addressing.  

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution)

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

## Backward Compatibility

Describe the impacts that this change will have on existing code, in both
source and binary form.

- New versions of the Swift compiler should maintain a source compatibility
  window with earlier versions. Does this proposal require breaking
  compatibility with or changing the behavior of existing source? Is there
  existing behavior that should be deprecated in favor of new behavior
  established by this proposal? How can existing code be mechanically
  migrated from the broken or deprecated behavior to the new behavior?
- New versions of the Swift runtime and standard library must maintain
  long-term ABI compatibility with deployed applications. How can the
  implementation maintain binary compatibility with existing binaries while
  supporting the new behavior?

## Alternatives considered

Describe alternative approaches to addressing the same problem, and
why you chose this approach instead.

