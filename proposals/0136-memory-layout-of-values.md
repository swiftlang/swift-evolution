# Memory layout of values

* Proposal: [SE-0136](0136-memory-layout-of-values.md)
* Author: [Xiaodi Wu](https://github.com/xwu)
* Review Manager: [Dave Abrahams](https://github.com/dabrahams)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160808/026164.html)
* Implementation: [apple/swift#4041](https://github.com/apple/swift/pull/4041)

## Introduction

This proposal is to introduce, as a bugfix, a replacement for `sizeofValue(_:)` and related functions.

Swift-evolution thread: [MemoryLayout for a value](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160801/025890.html)

## Motivation

Members of the core team, having seen a negative impact on the standard library and other code on implementation of [SE-0101](0101-standardizing-sizeof-naming.md), have expressed concern that removal of `sizeofValue(_:)` and related functions without replacement was a mistake. In the standard library, the current workaround makes use of an underscored API: `MemoryLayout._ofInstance(x).size`.

## Proposed solution

The proposed solution is to re-introduce `sizeofValue(_:)` and related functions as static methods on `MemoryLayout`. They would be expressed as follows:

```
MemoryLayout.size(ofValue: x)
MemoryLayout.stride(ofValue: x)
MemoryLayout.alignment(ofValue: x)
```

## Detailed design

The implementation will be as follows:

```
extension MemoryLayout {
  @_transparent
  public static func size(ofValue _: T) -> Int {
    return MemoryLayout.size
  }
  @_transparent
  public static func stride(ofValue _: T) -> Int {
    return MemoryLayout.stride
  }
  @_transparent
  public static func alignment(ofValue _: T) -> Int {
    return MemoryLayout.alignment
  }
}
```

## Impact on existing code

No applications will stop compiling due to this change. Standard library implementations that currently use the underscored `_ofInstance(_:)` will be migrated.

## Alternatives considered

### Autoclosure

Previously, it has been suggested that the parameter should have an `@autoclosure` attribute so that the argument is _not_ evaluated. However, such a use of the attribute would be unprecedented in the standard library.

Current uses of `@autoclosure` in the standard library such as `assert(_:_:file:line:)` do evaluate the autoclosure. Furthermore, in general, a reader expects `foo(bar(x))` to invoke both `bar(_:)` and `foo(_:)`.

In fact, during implementation of SE-0101, concern was raised that potential use of expressions such as `strideofValue(iter.next())` (where `iter` is an instance of an iterator), might rely on the side effect of evaluating the argument. By contrast, no use case has yet surfaced where it is necessary to obtain the memory layout stride for the result of an expression that also must not be evaluated.

### Making use of `type(of:)` 

Concerns about confusability of the `ofValue` functions and their "non-value" counterparts led to  the proposal that a spelling such as `MemoryLayout.of(type(of: x)).size` might be desirable. In that case, the method `of(_:)` would take an argument of type `T.Type` rather than `T`.

However, this alternative would produce the consequence that each use of `MemoryLayout<Int>.size` would be interchangeable with `MemoryLayout.of(Int.self).size`, potentially leading to confusion about why the standard library provides an apparently duplicative API.

Furthermore, Dmitri Gribenko points out that the use of `type(of:)` could increase confusion about these methods when the dynamic type of a value differs from the static type. Consider a protocol existential:

```
protocol P {}
extension Int : P {}
var x: P = 1
```

Even though `type(of:)` has the semantics of returning the dynamic type, `MemoryLayout.of(type(of: x)).size` computes the size of the existential box and not the size of an instance of type `Int`. This is because `type(of: x)` returns a value of `Int.self` statically typed as `P.Type`, with the result that `P` is the type deduced for the generic parameter of `MemoryLayout`.

### Subsuming `MemoryLayout` into a reflection API

The design of a reflection API would exceed the scope of a Swift 3 bugfix.

## Acknowledgments

Thanks to Dave Abrahams and Dmitri Gribenko.
