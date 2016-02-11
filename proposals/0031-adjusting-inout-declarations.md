# Adjusting `inout` Declarations for Type Decoration

* Proposal: [SE-0031](https://github.com/apple/swift-evolution/blob/master/proposals/0031-adjusting-inout-declarations.md)
* Author(s): [Joe Groff](https://github.com/jckarter), [Erica Sadun](http://github.com/erica)
* Status: **Under review** (February 11...February 15, 2016)
* Review manager: [Chris Lattner](https://github.com/lattner)

## Introduction

The `inout` keyword indicates copy-in/copy-out argument behavior. In its current implementation the keyword prepends argument names. We propose to move the `inout` keyword to the right side of the colon to decorate the type instead of the parameter label.

*The initial Swift-Evolution discussion of this topic took place in the "[Replace 'inout' with &](http://comments.gmane.org/gmane.comp.lang.swift.evolution/2751)" thread.*

## Motivation

In Swift 2, the `inout` parameter lives on the label side rather than the type side of the colon
although the keyword isn't modifying the label but its type. Decorating
types instead of labels offers identifiable advantages:

* It enables the `inout` keyword to properly integrate into full type syntax, for example: 

    ```swift
    (x: inout T) -> U // => (inout T) -> U
    ```

* It avoids notational similarity with arguments labeled `inout`, for example:

    ```swift
    func foo(inOut x: T) // foo(inOut:), type (T) -> Void
    func foo(inout x: T) // foo(_:), type (inout T) -> Void
    ```

* Moving it would allow `inout` to be used as a parameter label.  While this
  isn't a particularly strong motivation by itself, currently `inout` is the 
  *only* keyword not allowed as a parameter label in Swift 3.  Removing this
  restriction would simplify the language.

* It better matches similar patterns in other languages such as borrowing in Rust, that may be later introduced back to Swift

## Detailed design

```
parameter → external-parameter-name optlocal-parameter-name : type-annotation
type-annotation → inout type-annotation
```

## Alternatives Considered

Decorations using `@inout` (either `@inout(T)` or `@inout T`) were considered and discarded