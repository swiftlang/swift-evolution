# `Iterable`

* Proposal: [SE-0516](0516-borrowing-sequence.md)
* Authors: [Nate Cook](https://github.com/natecook1000), [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Active review (June 4 - June 30, 2026)**
* Implementation: [swiftlang/swift#86811](https://github.com/swiftlang/swift/pull/86811), [swiftlang/swift#87483](https://github.com/swiftlang/swift/pull/87483), [swiftlang/swift#89630](https://github.com/swiftlang/swift/pull/89630)
* Toolchain: [swift-PR-89630-2329-osx.tar.gz](https://download.swift.org/tmp/pull-request/89630/2329/xcode/swift-PR-89630-2329-osx.tar.gz)
* Review: ([pitch](https://forums.swift.org/t/pitch-borrowing-sequence/84332)) ([review](https://forums.swift.org/t/se-0516-borrowing-sequence/85122)) ([returned for revision](https://forums.swift.org/t/returned-for-revision-se-0516-borrowing-sequence/85846)) ([second pitch](https://forums.swift.org/t/revision-pitch-iterable-formerly-borrowingsequence/86834)) ([second review](https://forums.swift.org/t/second-review-se-0516-iterable/87106))
* Previous Revision: [1][prev1]

## Summary of changes

We propose a new protocol for iteration, `Iterable`, 
which provides a universal implementation point for synchronous iteration.
Types conforming to `Iterable` can be noncopyable or nonescapable,
can have noncopyable elements, 
and can throw during iteration. 
The Swift compiler will support use of this protocol via the familiar `for`-`in` syntax.

#### Changes from Original Version

This version of the proposal includes the following changes from the [original `BorrowingSequence` proposal][prev1]:

- *Renamed to `Iterable`:* The protocol and all associated types and methods have been renamed to reflect the protocol's more universal role.
- *Throwing iteration:* Both `Iterable` and `IterableIteratorProtocol` now include a `Failure: Error` associated type, enabling typed throws during iteration.

## Motivation

The `Sequence` protocol first appeared alongside collections like `Array` in the early
days of Swift, and has many appealing characteristics, allowing iteration and 
generic algorithms on sequences based on the simple `for`-`in` primitive.

However, it predates the introduction of `~Copyable` and `~Escapable`, and is fundamentally based 
around copyable elements, posing a limitation on working with `Span` types, inline arrays, and
other types that use the newer noncopyable and nonescapable features.

Protocols can have requirements loosened on them, such as with the introduction
of `~Copyable` to `Equatable` in [SE-0499][], 
or using the proposed 
[SE-0503][],
which would provide language support for associated types to be marked `~Copyable`
 or `~Escapable`.

The design challenge with `Sequence`, though, is more fundamental.
A sequence provides access to its elements through an `Iterator`, 
and an iterator's `next()` operation _returns_ an `Element?`. 
For a sequence of noncopyable elements, this operation could only 
be implemented by consuming the elements of the iterated sequence,
with the `for` loop taking ownership of the elements individually.

While consuming iteration is sometimes what you want, _borrowing_ iteration is
equally important, serves as a better default for noncopyable elements, 
and yet cannot be supported by the existing `Sequence`.

## Proposed solution

This proposal introduces a new `Iterable` protocol, with iteration based around
providing `Span`s of elements instead of individual elements, eliminating
the need to copy. This pattern is also more optimizable in many cases where an
iterated type is backed by contiguous memory.

## Detailed design

The `Iterable` protocol is defined as:

```swift
public protocol Iterable<Element, Failure>: ~Copyable, ~Escapable {
  /// A type representing the iterable type's elements.
  associatedtype Element: ~Copyable

  /// A type representing an error thrown during iteration.
  associatedtype Failure: Error = Never

  /// A type that provides the iteration interface and
  /// encapsulates its iteration state.
  associatedtype IterableIterator: IterableIteratorProtocol<Element, Failure> & ~Copyable & ~Escapable

  /// Returns a borrowing iterator over the elements of this sequence.
  @_lifetime(borrow self)
  func makeIterableIterator() -> IterableIterator
  
  /// A value less than or equal to the number of elements in the sequence,
  /// calculated nondestructively.
  var underestimatedCount: Int { get }
  
  /// Internal customization point for fast `contains(_:)` checks.
  func _customContainsEquatableElement(_ element: borrowing Element) -> Bool?
}

// Default implementations
extension Iterable where Self: ~Copyable & ~Escapable, Element: ~Copyable {
  public var underestimatedCount: Int { 0 }
  public func _customContainsEquatableElement(...) -> Bool? { nil }
}
```

This protocol shape is very similar to the current `Sequence`. It has a primary
associated type for the element, and a method
that hands you an iterator you can use to iterate the elements of the sequence.

The differences from the `Sequence` protocol are as follows:

- `Iterable` allows conformance by noncopyable and nonescapable types. 
Note that copyable and escapable types can also conform, but the protocol is designed to not require it.
- The `Element` type is also not required to be copyable.
- There is an `IterableIterator` associated type, and a `makeIterableIterator()`
method that returns one. These play a similar role to `Iterator` and `makeIterator()`
on `Sequence`.
- The iterator returned by `makeIterableIterator` is constrained to the lifetime
of the sequence. This allows the iterator to be implemented in terms of properties 
borrowed from the sequence or a `Ref` of the sequence itself.
- `Iterable` defines an associated `Failure` type that enables throwing during iteration.
Throwing iteration allows the broadest set of types to conform to `Iterable`, including
lazy transformations and types with elements that can throw during generation or access.

Note that the names of the associated type and iterator-providing method are specifically chosen to not conflict 
with existing names on `Sequence`, allowing a type to have different implementations 
for both `Iterable` and `Sequence`. The `underestimatedCount` and `_customContains...` requirements,
however, must have the same semantics between the two protocols, and therefore have the same names.

The `IterableIteratorProtocol` is similar to its analog, but differs a little more:

```swift
public protocol IterableIteratorProtocol<Element, Failure>: ~Copyable, ~Escapable {
  /// A type representing the iterated elements.
  associatedtype Element: ~Copyable
  
  /// A type representing an error thrown during iteration.
  associatedtype Failure: Error = Never
  
  /// Returns a span over the next group of contiguous elements, up to the
  /// specified maximum number.
  @_lifetime(&self)
  mutating func nextSpan(maximumCount: Int) throws(Failure) -> Span<Element>
  
  /// Advances this iterator by up to the specified number of elements and
  /// returns the number of elements that were actually skipped.
  mutating func skip(by maximumOffset: Int) throws(Failure) -> Int
}

// Default implementations
extension IterableIteratorProtocol where Element: ~Copyable {
  public mutating func nextSpan() throws(Failure) -> Span<Element> { ... }
  public mutating func skip(by maximumOffset: Int) throws(Failure) -> Int { ... }
}
```

Instead of returning individual elements from a `next()` method as `IteratorProtocol` does,
`IterableIteratorProtocol` offers up spans of elements. The iterator indicates there 
are no more elements to iterate by returning an empty `Span`.

As with `Sequence`, once an iterator returns an empty `Span`, 
every subsequent call to `nextSpan()` must return an empty `Span` as well.
An iterator's behavior after throwing an error is undefined:
some iterators may treat that as the end of the sequence,
some may continue to throw the same error or a different error,
and some may resume iteration on the next call. 
Generic code should therefore not assume any particular behavior,
with a recommendation that the error be propagated to the caller.

### Iterator and element lifetimes

For noncopyable and/or nonescapable types, the `Iterable` protocols provide lifetimes 
that are tightly scoped to the providing types. In general, the `IterableIterator`
of an iterable type is a nonescapable type with a lifetime borrowed from the
original type. For example, the iterator for `InlineArray` is `SpanIterator`,
a nonescapable type that provides access to the array's storage via a `Span`.

To support a broad range of iterator types, the `Span` returned from an iterator's `nextSpan(...)` method has an exclusive access dependency on the iterator (i.e. `@_lifetime(&self)`). This means that the elements accessed via that span also have an exclusive access dependency, with lifetimes ending on the next call to `nextSpan()` or another mutating call to the iterator.

For `Iterable` types with `~Copyable` element types, this means that some operations that are common in sequence iteration are not possible to implement:

- *Returning an element:* In the most general case, a method like `first(where:)` cannot be implemented in an extension on `Iterable`, because the selected element's lifetime is tied to the iterator created within the method. 
- *Escaping an element from a loop:* For the same reason, the functionality of `first(where:)` could not be coded in-place using a `for`-`in` loop to find an element and assign it to a variable outside the loop's scope.
- *Comparing elements across `Span` accesses:* A method like `allEqual()`, that checks whether every element in a sequence is equal to every other element, cannot be implemented in the most general case for `Iterable`. Because full iteration of an `Iterable` type requires calling `nextSpan()` an unknown number of times, the implementation would require preserving an element across those calls, violating exclusive access.

*None* of these restrictions apply when an `Iterable` type's element is `Copyable`, so these are not new restrictions compared to what `Sequence` provides. Only operations written to explicitly generalize the implicit `Copyable` constraint would be bound by the lifetimes.

### Span size

The number of elements in each span is determined by both the conforming type
and the caller. For the conforming type, the usual implementation will be to
provide the largest span possible for each call. In the case of `InlineArray`, or other
contiguously-stored types, this is just a single span for the entire collection.

Examples where `nextSpan` may be required to be called more than once include:
- *Types where elements are held in discontiguous storage,* such as a ring buffer.
A ring buffer would provide two spans: one from the first element to the end of the buffer,
followed by one from the start of the buffer to the last element.
- *Types that produce elements on demand,* such as a `Range`. Because the elements of a range
aren't stored directly in memory, the iterator would provide access to a span
of a single element at a time. Note that this is how any `Sequence` can be adapted to conform
to `Iterable` (see later in this proposal).
- *Callers that only process a certain number of elements at a time* would pass
their limit as `maximumCount`, with successive calls to `nextSpan` until the returned
span is empty.

Specifying a maximum number of elements is important for use cases where an 
iterator is passed `inout` to another function, which consumes only as many 
elements as it needs and no more. This is required as a result of the bulk iteration 
model, unlike `IteratorProtocol.next()`, which returns only one element at a time.

Additionally, the maximum parameter provides a convenience for the caller.
Because calling `nextSpan` is mutating, a caller that can only handle a specific number
of elements at a time would otherwise need to write complex code to manage
partial usage of a returned span.

The maximum count also gives signal to the iterator that only a specific number of
elements are needed, which can be used to produce results more efficiently. 
For example, a lazily filtered span might want to serve up "runs" of filtered-in 
elements from the original collection, in which case you really want to know how many 
the caller actually wants to consume.

### Throwing iteration

Both `Iterable` and `IterableIteratorProtocol` include a `Failure` associated type 
that defaults to `Never`. When iteration is simply providing access to a type's
storage, as with `InlineArray` and `UniqueArray`, the `Never` failure type allows
iteration without the `try` keyword or handling of throwing in the surrounding
contexts. However, for types that can fail during iteration, like a lazy filter
wrapper, using `for`-`in` syntax or calling an iterator's `nextSpan()` or `skip(by:)`
methods requires the `try` keyword.

To iterate over a throwing `Iterable` type, callers use `for try element in iterable`, 
similar to iterating over an `AsyncSequence`. The desugared form of a throwing loop 
follows the same structure shown in the non-throwing case above, 
with `try` added to the `nextSpan()` call.

Because `Failure` is a typed-throws associated type, generic algorithms can propagate
the failure type exactly. An algorithm declared as `throws(Failure)` will be 
non-throwing when the concrete `Iterable` has a `Failure` type equal to `Never`,
and will throw the specific error type otherwise. See the `example_reduce(into:_:)`
declaration below for an example.

### Use of the new protocols

To illustrate how these new protocols would be used, we can also look at the proposed
desugaring of the `for`-`in` syntax. The following familiar code:

```swift
for element in myIterable {
    f(element)
    g(element)
}
```

would cause the compiler to generate code similar to:

```swift
var iterator = myIterable.makeIterableIterator()
while true {
    let span = iterator.nextSpan(maximumCount: Int.max)
    if span.isEmpty { break }	  

    for i in span.indices {
        f(span[i])
        g(span[i])
    }
}
```

This automatic code generation is often referred to as "desugaring" the loop.

Note, the compiler will not necessarily generate this exact code,
but it is illustrative of how a user might use the methods directly.
The inner `for i in span.indices`, followed by access to the individual
elements by subscripting with `i` wherever you would previously have
used the loop variable, will be familiar to anyone who has
iterated spans of noncopyable elements as they exist today. It allows
noncopyable elements to be passed directly into functions like `f`
and `g` without the need for a temporary variable.

This desugared `while` loop is more complex than its `Sequence`
equivalent, but the day-to-day usage remains exactly the same, with
the added complexity left to the caller.

### Example `Iterable` algorithms

The following two examples, included in this proposal *only* for illustration, 
show how some `Iterable` operations 
will be as simple as their `Sequence` counterparts, while others 
will require more careful manual iteration.

The differences between an implementation of `reduce(into:_:)` for `Sequence` and 
`Iterable` are only in the parameters' ownership annotations, because 
we only need access to one element at a time. The implementation itself
is essentially identical:

```swift
extension Iterable where Element: ~Copyable {
   func example_reduce<T: ~Copyable>(
      into initial: consuming T,
      _ nextPartialResult: (inout T, borrowing Element) -> Void
   ) throws(Failure) -> T {
      var result = initial
      for try element in self {
         nextPartialResult(&result, element)
      }
      return result
   }
}
```

In order to properly implement `elementsEqual`, however, we must use manual 
iteration to compare spans of equal size between two `Iterable` types:

```swift
extension Iterable where Self: ~Escapable & ~Copyable, Element: ~Copyable & Equatable {
   func example_elementsEqual<S: Iterable<Element, Failure>>(
      _ rhs: borrowing S
   ) throws(Failure) -> Bool
      where S: ~Escapable & ~Copyable
   {
      var iter1 = makeIterableIterator()
      var iter2 = rhs.makeIterableIterator()
      while true {
         var span1 = try iter1.nextSpan(maximumCount: .max)
   
         if span1.isEmpty {
            // LHS is empty - sequences are equal iff RHS is also empty
            let span2 = try iter2.nextSpan(maximumCount: 1)
            return span2.isEmpty
         }
   
         while span1.count > 0 {
            let span2 = try iter2.nextSpan(maximumCount: span1.count)
            if span2.isEmpty { return false }
            for i in 0..<span2.count {
               if span1[i] != span2[i] { return false }
            }
            span1 = span1.extracting(droppingFirst: span2.count)
         }
      }
   }
}
```

### Standard Library adoption

`InlineArray` and the various `Span` types will conform to `Iterable`.

```swift
extension Span: Iterable
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @_lifetime(borrow self)
   func makeIterableIterator() -> SpanIterator<Element>
}

extension MutableSpan: Iterable
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @_lifetime(borrow self)
   func makeIterableIterator() -> SpanIterator<Element>
}

extension RawSpan: Iterable {
   @_lifetime(borrow self)
   func makeIterableIterator() -> SpanIterator<UInt8>
}

extension MutableRawSpan: Iterable {
   @_lifetime(borrow self)
   func makeIterableIterator() -> SpanIterator<UInt8>
}

extension InlineArray: Iterable
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @_lifetime(borrow self)
   func makeIterableIterator() -> SpanIterator<Element>
}
```

Each of these types use a new borrowing iterator type, `SpanIterator`,
that is suitable for types that store their elements in a single 
contiguous block of memory. The `SpanIterator` type stores both a
`Span` and the current offsets into the span, to allow flexibility for
future kinds of iteration.

```swift
/// A borrowing iterator type that provides access to the contents of a single
/// span of elements.
public struct SpanIterator<Element>: IterableIteratorProtocol, ~Copyable, ~Escapable
  where Element: ~Copyable
{
  public typealias Failure = Never

  @_lifetime(copy elements)
  public init(_ elements: Span<Element>)
  
  @_lifetime(&self)
  public mutating func nextSpan(maximumCount: Int) -> Span<Element>
  
  public mutating func skip(by offset: Int) -> Int
}
```

### Adapters for existing `Sequence` types

As mentioned above, it is possible given an implementation to `Sequence`
to implement the necessary conformance to `Iterable`. We propose
the following addition to the standard library:

```swift
// An adapter type that, given an IteratorProtocol instance, serves up spans
// of each element generated by `next` one at a time.
public struct IterableIteratorAdapter<Iterator: IteratorProtocol>: IterableIteratorProtocol {
  public typealias Failure = Never

  var iterator: Iterator
  var currentValue: Iterator.Element? = nil

  public init(iterator: Iterator) {
    self.iterator = iterator
  }

  @_lifetime(&self)
  public mutating func nextSpan(maximumCount: Int) -> Span<Iterator.Element> {
	// It may be surprising to some readers not used to Swift's ownership
	// model that currentValue is a stored property, not just a local variable.
	// This is because currentValue must be storage owned by the adapter
	// instance, in order to return a span of its contents with the specified lifetime.
    currentValue = iterator.next()
	// note Optional._span is a private method in the standard library
	// that creates an empty or 1-element span of the optional
    return currentValue._span
  }
}

extension Sequence {
  public func makeIterableIterator() -> IterableIteratorAdapter<Iterator> {
    IterableIteratorAdapter(iterator: makeIterator())
  }
}
```

Given this, it will be possible for all types conforming to `Sequence` to also
conform to `Iterable`. The conformance of existing sequence types,
like `Array`, `Dictionary`, and `UnfoldSequence`, will be included in a
future proposal. Some of these types (such as `Array`) will merit a custom
iterator exposing an underlying `Span`. For other types, the conformance
will trivially make use of the `IterableIteratorAdapter` shown above.


### Suppressed conformance of the `IterableIterator` associated type

Proposal [SE-0503](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md)
allows the suppression of `Copyable` and `Escapable` on associated types.

Since `Element` is a _primary_ associated type, users will be able to extend 
`Iterable` with algorithms that require copyability by default. For example, 
an algorithm to return the minimum element requires the ability to 
copy that minimum element in order to return it. Extensions on `Iterable`
without specifying otherwise will default to `Element` being copyable,
as specified by SE-0503. Swift users unaware of the concept of
noncopyable types can extend `Iterable` without being aware of that 
feature of the language.

The `IterableIterator` associated type is _not_ a primary associated type; rather
it's an implementation detail of an `Iterable` type. Therefore,
per SE-0503, it will _not_ default to being either copyable or escapable.

This is a highly desirable property. While `Sequence` iterators are copyable,
the actual behavior of a particular iterator when you iterate, copy it,
then iterate the copy, is very implementation dependent. 
The `Sequence` protocol gives no specifications for how an iterator should
behave when you do this in a generic context. As such,
writing generic code that relies on being able to copy an iterator is 
never appropriate.

Additionally, many types (like `Span` or `InlineArray`) will require
a nonescaping iterator. The preferred behavior for users, even
those not aware that noncopyable or nonescapable types exist, is
to allow extensions written against `Iterable` to "just work"
on those types, since needing to copy or escape an iterator is rarely bumped 
into when implementing most sequence algorithms.

### Use of `@_lifetime`

Both `Iterable` and `IterableIteratorProtocol` have methods that 
return a non-escapable type (the `IterableIterator` and a `Span`, respectively), 
with a lifetime tied to `self`. This will require conforming types to
enable the `Lifetimes` experimental feature.

_Using_ these types – either directly, or via the `for` syntax – will not
generally require use of lifetime annotations or enabling of the experimental
feature (unless the user intends to e.g. return the iterator out of a function).

Algorithms written as extensions on `Iterable` should similarly
not commonly need use of lifetime annotations.

### `for`-`in` loop desugaring when both protocols are available

In order to preserve the performance and semantics of existing code that
uses `for`-`in` loops, the generated code will only use borrowing iteration
for types that _only_ conform to `Iterable`, or in contexts where 
only `Iterable` conformance can be assured.

Existing code written with types that conform to both `Iterable` and 
`Sequence` will call the `makeIterator()` method and iterate over each element
using that approach.

In effect, this means that `InlineArray` and the span types will be the only
ones to use borrowing iteration. Types like `Array`, if given conformance
to `Iterable`, would continue to use the element-wise `Sequence`-based iteration
model for existing code that they use today.

## Source compatibility

This proposal introduces the new protocols `Iterable` and `IterableIteratorProtocol`,
as well as additional supporting types. Existing conformers to `Sequence` can 
also implement `Iterable` by simply declaring their conformance. 
This is entirely source compatible.

## ABI compatibility

This proposal adds two new protocols, the `SpanIterator` and `IterableIteratorAdapter` types,
and  conformances for the span and `InlineArray` types to the standard library ABI.

## Future directions

### Other forms of iteration

While this proposal focuses on borrowing iteration, there are multiple other kinds of 
iteration that are equally important. Future proposals may take up alternative designs
for the following kinds of iteration:

- *Consuming iteration:* A container may want to provide consuming iteration of its 
  elements. For example, a container of noncopyable elements would need to be consumed
  when appended to a different container.
- *"Draining" iteration:* Similar to consuming iteration, but preserving the existence
  and allocation of the original container. This can be thought of as consuming the
  elements, but not the container itself.
- *Mutating iteration:* A mutable collection or a container of noncopyable elements
  may want to provide in-place mutation of its elements during iteration.
- *Generative iteration:* Certain types generate their elements during iteration, rather
  than storing them in memory, like iterating an `UnfoldSequence` or the key-value pairs
  in a dictionary. For those types, particularly those that generate noncopyable values, a 
  different iteration model would be more performant than the borrowing iteration 
  proposed here.
  
### `Container` and other protocols

As [prototyped][container-prototype] in the [`swift-collections` package][collections], 
a future `Container` protocol models types that store their elements in memory. 
In the same way `Iterable` functions like a generalized `Sequence`, 
`Container` functions like a generalized `Collection`, 
providing indexed access to its elements. 
Importantly, because `Container` types store their elements in memory, 
the element accesses can have lifetimes that are borrowed 
against the container that stores them,
a much broader lifetime than accesses via the `Iterable` protocol.

The following is a draft of the `Container` protocol and its requirements:

```swift
protocol Container<Element>: Iterable, ~Copyable, ~Escapable {
  associatedtype Element: ~Copyable
  associatedtype Index: Equatable, Hashable

  var count: Int { get }

  var startIndex: Index { get }
  var endIndex: Index { get }
  
  func index(after index: Index) -> Index
  func formIndex(after index: inout Index)
  func index(_ index: Index, offsetBy n: Int) -> Index
  func formIndex(
    _ index: inout Index, offsetBy n: inout Int, limitedBy limit: Index
  )
  func index(alignedDown index: Index) -> Index
  func index(alignedUp index: Index) -> Index

  func distance(from start: Index, to end: Index) -> Int

  @_lifetime(borrow self)
  func nextSpan(after index: inout Index, maximumCount: Int) -> Span<Element>

  subscript(index: Index) -> Element { 
    @_lifetime(borrow self) borrow { get }
  }
}
```

Other protocols support some of the different kinds of iteration described above, enabling the consuming behavior required for moving noncopyable elements from container to container.

- The `Producer` protocol models types that supply their values by populating a client-supplied series of `OutputSpan` instances.
- The `Drain` protocol models types that can provide an in-place consumable sequence through a series of `InputSpan` instances, allowing direct consumption of elements from some container's storage, in bulk, without requiring them to be moved into any temporary buffer.


## Alternatives considered

### `BorrowingSequence` naming

A previous version of this proposal used `BorrowingSequence` and similar names
for a less universal version of iteration functionality. The `Iterable` name
was selected instead, to help communicate the goal of providing iterative access 
to as broad a range of types as possible.

### Modifying `Sequence` to extend `Iterable`

A previous version of this proposal described allowing the re-parenting of the
existing `Sequence` protocol to make it extend the new `Iterable` protocol proposed here.
The insertion of `Iterable` into the existing `Sequence` protocol hierarchy
would allow for algorithms that target both copyable and noncopyable sequences.
While re-parenting at this time is not directly planned, usage and future
evaluation may lead to a proposal to make this change.

### Only support sequences with direct storage

The current proposal allows any type that conforms to the current `Sequence`
protocol to conform to the new `Iterable` protocol. Sequences can conform
to the new protocol in basically one of two ways: 
- a sequence that directly stores all of its elements can yield one or more spans
providing access to those directly stored elements, and
- a sequence that does not store its elements can generate one or more elements as needed, 
store them in the iterator, and yield a span providing access to the elements stored
in the iterator.

In order to support this second method of conformance, the span returned by a borrowing 
iterator's `nextSpan()` method has a lifetime that depends on the iterator 
(using the `@_lifetime(&self)` annotation). 
This places a limitation on what algorithms can be written for `Iterable`, 
since the borrow of the sequence's elements does persist beyond the lifetime of the iterator, 
which is typically created and used within a sequence method. 
For example, a `first(where:)` method can't return a borrow of an individual element;
that borrow would only be valid inside the body of the function.

As an alternative, `Iterable` could _only_ support sequences that directly store their elements. 
In that case, the iterator would only be in charge of managing access to the sequence's storage, 
not storing and yielding elements itself. The spans returned from `nextSpan()` 
could have a lifetime dependent on the sequence instead of the iterator
(in which case the `nextSpan()` method would be marked with `@_lifetime(copy self)`).
With the spans of elements tied to the lifetime of the sequence, 
a borrow of an element can outlive the iterator, and be returnable from a method like `first(where:)`.

Future refinements of `Iterable` could help resolve this limitation 
by adding `Collection`-like indices, allowing referential access to elements.

### Basing `~Copyable` iteration on `IteratorProtocol`

Another direction for enabling borrowing iteration, and other kinds of iteration
in the future, is to move to using iterators as the primary type for iterative
algorithms. With this direction, `IteratorProtocol` would be generalized to
allow both noncopyable/nonescapable types and/or elements, and instead of the proposed
`Iterable` design, the new protocol could look like the following:

```swift
public protocol BorrowingSequence<BorrowedElement>: ~Copyable & ~Escapable {
  associatedtype BorrowedElement: ~Copyable
  associatedtype BorrowingIterator: IteratorProtocol<BorrowedElement>
    & ~Copyable & ~Escapable

  @_lifetime(borrow self)
  borrowing func makeBorrowingIterator() -> BorrowingIterator
}
```

With this approach, the `BorrowedElement` type that a sequence would declare as
the element iterated over during borrowing iteration is not constrained to be
equal to the sequence's "actual" element type. A type that can only provide
borrowing access to its elements could therefore have `Ref<Element>` as the
iterated element type, like `Span`, for example:

```swift
extension Span: BorrowingSequence where Self: ~Escapable, Element: ~Copyable {
  @_lifetime(borrow self)
  borrowing func makeBorrowingIterator() -> BorrowingIterator { ... }
  
  struct BorrowingIterator: IteratorProtocol {
      @_lifetime(copy self)
      mutating func next() -> Ref<Element> { ... }
  }
}
```

Iterative algorithms would then be written for `IteratorProtocol`, and be 
accessible whether the `BorrowedElement` type is the expected `Element` type
(as for types like `Array`) or `Ref<Element>` (for types that support
iteration of noncopyable elements). Because the `BorrowedElement` type has
its lifetime linked to the iterator-providing sequence (copied from the
iterator), iterative algorithms can return those elements without issue.

```swift
extension IteratorProtocol
  where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
  @_lifetime(copy self)
  consuming func first(
    where predicate: (borrowing Element) -> Bool
  ) -> Element? {
    while let el = next() {
      if predicate(el) { return el }
    }
    return nil
  }
}
```

After prototyping this model, we still feel that the proposed direction is
the best way forward for Swift. Primarily, the bulk iteration aspect of the
proposed `Iterable` protocol is a critical part of improving performance
when working with a wide variety of collections. Our experience with
the existing `Sequence` and `Collection` protocol hierarchy has been instructive
in how having fundamental functionality defined in the most basic, underlying
protocol is important for predictable performance as the protocol hierarchy
grows. We expect `Iterable` to play a similar role as `Sequence`
in an upcoming hierarchy of container protocols, in which bulk iteration
will continue to be a critical feature.

In addition, the different element types used in this alternative design
lead to awkward usage at the call site. For example, when used with a
`Span<NoncopyableInt>`, the `first(where:)` method declared above would have
a signature like the following, with a `(borrowing Ref<NoncopyableInt>) -> Bool` 
predicate parameter. Forcing interaction with the element a user actually
wants work with to go through a wrapper type in such a common case doesn't
meet our usability expectations.

### Adding noncopyable support to `Sequence`

Another approach for providing iteration and sequential algorithms 
to noncopyable types added defaulted requirements to the existing `Sequence`
protocol. However, this design requires several `Sequence`-specific workarounds
in the compiler, as well as additional undesirable API.

### Different lifetime relationships

For some types that implement `Iterable`, it would be possible to have
the spans returned from their iterator's `nextSpan` method to tie their lifetime to 
the overlying sequence type instead of the iterator. For example, the spans provided by a
deque implementation would be memory-managed by the deque, not its iterator. 

However, for sequence types that generate their elements as needed, 
the iterator must store the element as it's being borrowed, which 
requires the lifetime dependency on the iterator. 
This is the design chosen in order to allow maximum flexibility 
for conforming sequence types.

### Using an opaque iterator type

As a way to mitigate the challenge of customizing the borrowing iterator in ABI-stable
frameworks, `Iterable` could declare `makeIterableIterator()` as returning
an opaque iterator type instead of giving the protocol an associated type. However,
using an opaque type in this position creates barriers to optimization that render 
this approach unworkable.

### Using `Span` as an iterator

An earlier version of this proposal used `Span` as a self-consuming iterator type.
This added API that seemed out of place on `Span` (e.g. `nextSpan()`) and limited
the flexibility of types to provide bidirectional or random-access iteration in the
future.

### Using borrowing iteration for all `for`-`in` loops

In the case of collections with contiguous storage, notably `Array`, the new 
iteration model results in much less overhead the optimizer to eliminate. 
Iterating over a `Span` is a lot closer to the "ideal" model of advancing a
pointer over a buffer and accessing elements directly. It is therefore expected 
that this design will result in better performance in some cases where today 
the optimizer is unable to eliminate the collection type's overhead.

However, there are performance and semantic caveats to switching all iteration
to the new model.

For an example of potential performance issues, imagine using `UnfoldSequence` 
to generate strings that are being streamed into an `Array<String>`:
- with `Sequence`, the strings are produced by the `UnfoldSequence`, returned by `next()`,
and consumed into the `Array` with no logical copies
- with `Iterable`, the strings are produced, stored in the `currentValue` variable,
**copied** out of the `Span` of that variable into the `Array`, and then the value in
`currentValue` is destroyed.

From the perspective of semantics, changing to a borrowing access of the collection
type while iterating would change the meaning of some existing code, in particular
in cases where an array is modified during iteration. (While this is usually ill-advised, 
this code is perfectly valid.) Such cases could fail to compile if converted to 
borrowing iteration, or, in some cases, continue to compile but result in a 
runtime exclusivity violation.

For these reasons, this proposal chooses to only use borrowing iteration in cases
where `Sequence`-based iteration is not available: in `Iterable`-constrained
generic contexts and for types that conform only to `Iterable`, but not
`Sequence`. Any switch from this default is left to future proposals. 

## Acknowledgments

Many thanks to Karoy Lorentey, Kavon Favardin, Joe Groff, Tony Parker, and Alejandro Alonso, for their input into this proposal.

[SE-0499]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md
[SE-0503]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md
[prev1]: https://github.com/swiftlang/swift-evolution/commit/230fb0e4ace8ddf8e4867233251aa2e32bfe0a66
[collections]: https://github.com/apple/swift-collections/
[container-prototype]: https://github.com/apple/swift-collections/blob/main/Sources/ContainersPreview/Protocols/Container/Container.swift
