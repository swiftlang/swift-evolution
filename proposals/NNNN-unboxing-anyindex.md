# Enable Unboxing/Unwrapping of AnyIndex

* Proposal: [SE-NNNN](NNNN-unboxing-anyindex.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal seeks to expose unboxing/unwrapping capabilities in the `AnyIndex` type in order to avoid having to reimplement it for custom collection wrappers.

Swift-evolution thread: [Discussion thread](http://thread.gmane.org/gmane.comp.lang.swift.evolution/20007)

## Motivation

Before the Swift indexing model for collections changed, it was possible for a collection wrapper to avoid exposing an underlying index type by simply wrapping it inside an `AnyIndex`, as the methods acting directly upon an index remain accessible through it.

However, under the new Swift indexing model the situation isn't as simple, as index manipulation requires passing the underlying index back to the collection that created it. This means that wrapping with `AnyIndex` is no longer sufficient, as there is currently no way to unwrap the original index to do this.

As a result, the only way to properly type-erase an index, but remain able to use it, is to reimplement `AnyIndex`, which results in duplicated code that may be inferior (as `AnyIndex` uses a few tricks not possible outside of the stdlib).

## Proposed solution

Internally the `AnyIndex` type uses a boxing mechanism to hide its underlying index type, but is able to unbox it in order to perform comparisons. I would like to see this capability exposed in a public method in order to enable collection wrappers to retrieve an underlying index when its type is known.

## Detailed design

This proposal suggests new methods on `AnyIndex` resembling the following:

```
public struct AnyIndex : Comparable {
  …
  // Unwraps this index as type `T` if that was the underlying type, otherwise returns `nil`.
  func unwrapped<T:Comparable>() -> T? { … }
  // Unwraps this index as type `T` if that was the underlying type, otherwise produces an error.
  func unsafeUnwrapped<T:Comparable>() -> T { … }
}
```

These enable the original type to be unwrapped by any code that knows what that type should be, with the former method allowing this to be done safely (by returning `nil` instead of producing an error when the cast is impossible). For example:

```
struct MyIncompleteWrapper<Base:Collection> : Collection {
  let base:Base
  
  // Simply wrap all outgoing indices with AnyIndex to type-erase them
  public var startIndex:AnyIndex { return AnyIndex(self.base.startIndex) }
  // Here we know the type of Base.Index, so we can attempt to unwrap it. For speed we will use the unsafe method.
  public subscript(position:AnyIndex) -> Iterator.Element { return self.base[position.unsafeUnwrap()] }
}
```

## Impact on existing code

This change does not require existing code to be changed, however it provides a solution to existing Swift 2 code that used `AnyIndex`, but which may no longer be able to do-so under the new indexing model, so in this respect it enables a necessary change to support Swift 3 fully without having to reimplement our own type-erased index wrappers.

## Alternatives considered

My preferred solution would have been to define these new methods as a protocol like so:

```
public protocol Unwrappable {
  associatedtype Base
  func unwrapped<T:Base>() -> T?
  func unsafeUnwrapped<T:Base>() -> T
}
```

However this does not currently appear to be possible. So far `AnyIndex` is the only type that I've identified as definitely needing this new unwrapping capability, so the addition of a protocol could be done as a later addition once more types are known.

It is currently possible to use a protocol for this by removing the associatedtype, however this would also lose a valuable hint for the type-checker; in the case of `AnyIndex` knowing that the unwrapped type must at least be `Comparable` allows it to be passed directly into a collection subscript without ambiguity (it cannot be mistaken for a range, or a key on a Dictionary etc.), for this reason it seems preferable to restrict the change to `AnyIndex` only for the time being.
