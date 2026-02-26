# Borrowing Sequence

* Proposal: [SE-0516](0516-borrowing-sequence.md)
* Authors: [Nate Cook](https://github.com/natecook1000), [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Holly Borla](https://github.com/hborla)
* Status: **Active review (March 2 - March 16)**
* Implementation: [swiftlang/swift#86811](https://github.com/swiftlang/swift/pull/86811), [swiftlang/swift#87483](https://github.com/swiftlang/swift/pull/87483)
* Review: ([pitch](https://forums.swift.org/t/pitch-borrowing-sequence/84332))

## Summary of changes

We propose a new protocol for iteration, `BorrowingSequence`, which 
will work with noncopyable types and provide more efficient iteration
in some circumstances for copyable types. The Swift compiler will
support use of this protocol via the familiar `for`-`in` syntax.

## Motivation

The `Sequence` protocol first appeared alongside collections like `Array` in the early
days of Swift, and has many appealing characteristics, allowing iteration and 
generic algorithms on sequences based on the simple `for`-`in` primitive.

However, it predates the introduction of `~Copyable` and `~Escapable`, and is fundamentally based 
around copyable elements, posing a limitation on working with `Span` types, inline arrays, and
other types for collections of noncopyable elements.

Protocols can have requirements loosened on them, such as with the introduction
of `~Copyable` to `Equatable` in [SE-0499](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md), 
or using the proposed 
[SE-0503](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md),
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

This proposal introduces a new `BorrowingSequence`, with iteration based around
serving up `Span`s of elements, rather than individual elements, eliminating
the need to copy. This pattern is also more optimizable in many cases where an
iterated type is backed by contiguous memory.

## Detailed design

The `BorrowingSequence` protocol is defined as:

```swift
public protocol BorrowingSequence<Element>: ~Copyable, ~Escapable {
  /// A type representing the sequence's elements.
  associatedtype Element: ~Copyable

  /// A type that provides the sequence's iteration interface and
  /// encapsulates its iteration state.
  associatedtype BorrowingIterator: BorrowingIteratorProtocol<Element> & ~Copyable & ~Escapable

  /// Returns a borrowing iterator over the elements of this sequence.
  @lifetime(borrow self)
  func makeBorrowingIterator() -> BorrowingIterator
  
  /// A value less than or equal to the number of elements in the sequence,
  /// calculated nondestructively.
  var underestimatedCount: Int { get }
  
  /// Internal customization point for fast `contains(_:)` checks.
  func _customContainsEquatableElement(_ element: borrowing Element) -> Bool?
}

// Default implementations
extension BorrowingSequence where Self: ~Copyable & ~Escapable, Element: ~Copyable {
  public var underestimatedCount: Int { 0 }
  public func _customContainsEquatableElement(...) -> Bool? { nil }
}
```

This protocol shape is very similar to the current `Sequence`. It has a primary
associated type for the element, and just one method
that hands you an iterator you can use to iterate the elements of the sequence.

The differences from the `Sequence` protocol are as follows:

- `BorrowingSequence` allows conformance by noncopyable and nonescapable types. Note that copyable and escapable types can also conform, but the protocol is designed to not require it.
- The `Element` type is also not required to be copyable.
- There is a `BorrowingIterator` associated type, and a `makeBorrowingIterator()`
method that returns one. These play a similar role to `Iterator` and `makeIterator()`
on `Sequence`.
- The iterator returned by `makeBorrowingIterator` is constrained to the lifetime
of the sequence. This allows the iterator to be implemented in terms of properties 
borrowed from the sequence (often a span of the sequence).

Note that the names of the associated type and method are specifically chosen to not conflict 
with the existing names on `Sequence`, allowing a type to have different implementations 
for both `BorrowingSequence` and `Sequence`.

The `BorrowingIteratorProtocol` is similar to its analog, but differs a little more:

```swift
public protocol BorrowingIteratorProtocol<Element>: ~Copyable, ~Escapable {
  associatedtype Element: ~Copyable
  
  /// Returns a span over the next group of contiguous elements, up to the
  /// specified maximum number.
  @lifetime(&self)
  mutating func nextSpan(maximumCount: Int) -> Span<Element>
  
  /// Advances this iterator by up to the specified number of elements and
  /// returns the number of elements that were actually skipped.
  mutating func skip(by maximumOffset: Int) -> Int
}

// Default implementations
extension BorrowingIteratorProtocol where Element: ~Copyable {
  public mutating func skip(by maximumOffset: Int) -> Int { ... }
}
```

Instead of offering up individual elements via `next()` as `IteratorProtocol` does,
`BorrowingIteratorProtocol` offers up spans of elements. The iterator indicates there 
are no more elements to iterate by returning an empty `Span`.

How many elements are in each span is determined both by the conforming type
and the caller. For the conforming type, the usual implementation will be to
offer up the largest span possible for each call. In the case of `Array`, or other
contiguously-stored types, this is just a single span for the entire collection.

Examples where `nextSpan` may be required to be called more than once include:
- *Types where elements are held in discontiguous storage,* such as a ring buffer.
A ring buffer would provide two spans: one from the first element to the end of the buffer,
followed by one from the start of the buffer to the last element.
- *Types that produce elements on demand,* such as a `Range`. Because the elements of a range
aren't stored directly in memory, the iterator would provide access to a span
of a single element at a time. Note that this is how any `Sequence` can be adapted to conform
to `BorrowedSequence` (see later in this proposal).
- *Callers that only process a certain number of elements at a time* would pass
their limit as `maximumCount`, with successive calls to `nextSpan` until the returned
span is empty.

Specifying a maximum number of elements is important for use cases where an 
iterator is passed `inout` to another function, which consumes only as many 
elements as it needs and no more. This is required as a result of the bulk iteration 
model, unlike `IteratorProtocol.next()` which returns only one element at a time.

Additionally, it provides a convenience for the caller.
Because calling `nextSpan` is mutating, a caller that can only handle a specific number
of elements at a time would otherwise need to write quite complex code to manage
partial usage of a returned span.

The maximum count also gives signal to the iterator that only a specific number of
elements are needed, which can be used to produce results more efficiently. 
For example, a lazily filtered span might want to serve up "runs" of filtered-in 
elements from the original collection, in which case you really want to know how many 
the caller actually wants to consume.

### Use of the new protocols

To illustrate how these new protocols would be used, we can also look at the proposed
desugaring of the `for...in` syntax. The following familiar code:

```swift
for element in borrowingSequence {
    f(element)
    g(element)
}
```

would cause the compiler to generate code similar to:

```swift
var iterator = borrowingSequence.makeBorrowingIterator()
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
use the loop variable, will be familiar to anyone who has
iterated spans of noncopyable elements as they exist today. It allows
noncopyable elements to be passed directly into functions like `f`
and `g` without the need for a temporary variable.

This desugared `while` loop is more complex than its `Sequence`
equivalent, but the day-to-day usage remains exactly the same, with
the added complexity left to the caller.

### Example `BorrowingSequence` algorithms

*Note:* The addition of appropriate algorithms aligning with those on `Sequence`
will be specified in an upcoming proposal. 

The following two examples, included in this proposal only for illustration, 
show how some `BorrowingSequence` operations 
will be as simple as their `Sequence` counterparts, while others 
will require more careful manual iteration.

The differences between an implementation of `reduce(into:_:)` for `Sequence` and 
`BorrowingSequence` are only in the parameters' ownership annotations, because 
we only need access to one element at a time. The implementation itself
is essentially identical:

```swift
extension BorrowingSequence {
   func example_reduce<T: ~Copyable>(
      into initial: consuming T,
      _ nextPartialResult: (inout T, borrowing Element) -> Void
   ) -> T {
      var result = initial
      for element in self {
         nextPartialResult(&result, element)
      }
      return result
   }
}
```

In order to properly implement `elementsEqual`, however, we must use manual 
iteration to compare spans of equal size between two `BorrowingSequence` types:

```swift
extension BorrowingSequence where Self: ~Escapable & ~Copyable, Element: ~Copyable & Equatable {
   func example_elementsEqual<S: BorrowingSequence<Element>>(
      _ rhs: borrowing S
   ) -> Bool
      where S: ~Escapable & ~Copyable
   {
      var iter1 = makeBorrowingIterator()
      var iter2 = rhs.makeBorrowingIterator()
      while true {
         var span1 = iter1.nextSpan(maximumCount: .max)
   
         if span1.isEmpty {
            // LHS is empty - sequences are equal iff RHS is also empty
            let span2 = iter2.nextSpan(maximumCount: 1)
            return span2.isEmpty
         }
   
         while span1.count > 0 {
            let span2 = iter2.nextSpan(maximumCount: span1.count)
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

`InlineArray` and the various `Span` types will conform to `BorrowingSequence`.

```swift
extension Span: BorrowingSequence
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> SpanIterator<Element>
}

extension MutableSpan: BorrowingSequence
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> SpanIterator<Element>
}

extension RawSpan: BorrowingSequence {
   @lifetime(borrow self)
   func makeBorrowingIterator() -> SpanIterator<UInt8>
}

extension MutableRawSpan: BorrowingSequence {
   @lifetime(borrow self)
   func makeBorrowingIterator() -> SpanIterator<UInt8>
}

extension InlineArray: BorrowingSequence
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> SpanIterator<Element>
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
public struct SpanIterator<Element>: BorrowingIteratorProtocol, ~Copyable, ~Escapable
  where Element: ~Copyable
{
  /// Creates a new iterator over the given span.
  @_lifetime(copy elements)
  public init(_ elements: Span<Element>)
  
  /// Returns a span over the next group of contiguous elements, up to the
  /// specified maximum number.
  @_lifetime(&self)
  public mutating func nextSpan(maximumCount: Int) -> Span<Element>
  
  /// Advances this iterator by up to the specified number of elements and
  /// returns the number of elements that were actually skipped.
  public mutating func skip(by offset: Int) -> Int
}
```

### Adaptors for existing `Sequence` types

As mentioned above, it is possible given an implementation to `Sequence`
to implement the necessary conformance to `BorrowingSequence`. We propose
the following addition to the standard library:

```swift
// An adaptor type that, given an IteratorProtocol instance, serves up spans
// of each element generated by `next` one 
public struct BorrowingIteratorAdapter<Iterator: IteratorProtocol>: BorrowingIteratorProtocol {
  var iterator: Iterator
  var currentValue: Iterator.Element? = nil

  public init(iterator: Iterator) {
    self.iterator = iterator
  }

  @lifetime(&self)
  public mutating func nextSpan(maximumCount: Int) -> Span<Iterator.Element> {
	// It may be surprising to some readers not used to Swift's ownership
	// model that currentValue is a stored property, not just a local variable.
	// This is because currentValue must be storage owned by the BorrowingIteratorAdapter
	// instance, in order to return a span of its contents with the specified lifetime.
    currentValue = iterator.next()
	// note Optional._span is a private method in the standard library
	// that creates an empty or 1-element span of the optional
    return currentValue._span
  }
}

extension Sequence {
  public func makeBorrowingIterator() -> BorrowingIteratorAdapter<Iterator> {
    BorrowingIteratorAdapter(iterator: makeIterator())
  }
}
```

Given this, it will be possible for all types conforming to `Sequence` to also
conform to `BorrowingSequence`. The conformance of existing sequence types,
like `Array`, `Dictionary`, and `UnfoldSequence`, will be included in an
upcoming proposal. Some of these types (such as `Array`) will merit a custom
conformance exposing an underlying `Span`. For other types, the conformance
will trivially make use of the `BorrowingIteratorAdaptor` shown above:

```swift
// all requirements fulfilled by BorrowingIteratorAdaptor
extension UnfoldSequence: BorrowingSequence { }
```

### Suppressed conformance of the `BorrowingIterator` associated type

Proposal [SE-0503](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md)
allows the suppression of `Copyable` and `Escapable` on associated types.

Since `Element` is a _primary_ associated type, users will be able to extend 
`BorrowingSequence` with algorithms that require copyability. For example, 
an algorithm to return the minimum element requires the ability to 
copy that minimum element in order to return it. Extensions on `BorrowingSequence`
without specifying otherwise will default to `Element` being copyable, as
specified by SE-0503. Swift users unaware of the concept of noncopyable
types can extend `BorrowingSequence` without being aware of that feature of 
the language.

The `BorrowingIterator` associated type is _not_ a primary associated type; rather
it's an implementation detail of a `BorrowingSequence`. Therefore
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
to allow extensions written against `BorrowingSequence` to "just work",
on those types, since needing to copy or escape an iterator is rarely bumped 
into when implementing most sequence algorithms.

### Use of `@lifetime`

Both `BorrowingSequence` and `BorrowingIteratorProtocol` have methods that 
return a non-escapable type (the `BorrowingIterator` and a `Span`, respectively), 
with a lifetime tied to `self`. This will require conforming types to
enable the `Lifetimes` experimental feature.

_Using_ these types – either directly, or via the `for` syntax – will not
generally require use of lifetime annotations or enabling of the experimental
feature (unless the user intends to e.g. return the iterator out of a function).

Algorithms written as extensions on `BorrowingSequence` should similarly
not commonly need use of lifetime annotations.

### `for`-`in` loop desugaring when both protocols are available

In order to preserve the performance and semantics of existing code that
uses `for`-`in` loops, the generated code will only use borrowing iteration
for types that _only_ conform to `BorrowingSequence`, or in contexts where 
only `BorrowingSequence` conformance can be assured.

Existing code written with types that conform to both `BorrowingSequence` and 
`Sequence` will call the `makeIterator()` method and iterate over each element
using that approach.

In effect, this means that `InlineArray` and the span types will be the only
ones to use borrowing iteration. Types like `Array`, if given conformance
to `BorrowingSequence`, would continue to use the element-wise 
`Sequence`-based iteration model that they use today.

## Source compatibility

This proposal introduces a new protocol, `BorrowingSequence`.
Existing conformers to `Sequence` can also implement `BorrowingSequence`
by simply declaring their conformance. This is entirely source compatible.

## ABI compatibility

This proposal adds two new protocols, the `BorrowingIteratorAdapter` type, and 
conformances for the span and `InlineArray` types to the standard library ABI.
An [upcoming proposal][reparenting] will provide a language feature allowing re-parenting
of the `Sequence` protocol with `BorrowingSequence`, and a follow-up proposal to this
one will include that re-parenting and additional standard library API.

## Future directions

### Modifying `Sequence` to extend `BorrowingSequence`

A future proposal will provide the details of allowing re-parenting of
a protocol in an ABI compatible way, along with a modification of the existing 
`Sequence` proposal to make it extend the new `BorrowingSequence` protocol proposed here.
The insertion of `BorrowingSequence` into the existing `Sequence` protocol hierarchy
will allow for algorithms that target both copyable and noncopyable sequences.

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
  in a dictionary. A different iteration model could be more performant than the
  borrowing iteration proposed here.

## Alternatives considered

### Adding noncopyable support to `Sequence`

Another approach for providing iteration and sequential algorithms 
to noncopyable types added defaulted requirements to the existing `Sequence`
protocol. 

### Different lifetime relationships

For some types that implement `BorrowingSequence`, it would be possible to have
the spans returned from their iterator's `nextSpan` method to tie their lifetime to 
the overlying sequence type instead of the iterator. For example, the spans provided by a
deque implementation would be over memory managed by the deque, not its iterator. 

However, for sequence types that generate their elements as needed, the iterator must store the element as it's being borrowed, which requires the lifetime dependency on
the iterator. This is the design chosen in order to allow maximum flexibility for
conforming sequence types.

### Using an opaque iterator type

As a way to mitigate the challenge of customizing the borrowing iterator in ABI-stable
frameworks, `BorrowingSequence` could declare `makeBorrowingIterator()` as returning
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
- with `BorrowingSequence`, the strings are produced, stored in the `currentValue` variable,
**copied** out of the `Span` of that variable into the `Array`, and then the value in
`currentValue` is destroyed.

From the perspective of semantics, changing to a borrowing access of the collection
type while iterating would change the meaning of some existing code, in particular
in cases where an array is modified during iteration. (While this is usually ill-advised, 
this code is perfectly valid.) Such cases could fail to compile if converted to 
borrowing iteration, or, in some cases, continue to compile but result in a 
runtime exclusivity violation.

For these reasons, this proposal chooses to only use borrowing iteration in cases
where `Sequence`-based iteration is not available: in `BorrowingSequence`-constrained
generic contexts and for types that conform only to `BorrowingSequence`, but not
`Sequence`. Any switch from this default is left to future proposals. 

### Nonescapable elements

While there are use cases for modeling sequences of nonescapable elements (such as a
`Span<Span<Int>>`, crafting such types isn't possible under the currently proposed 
model for annotating lifetimes. The authors are confident that the current design could
be modified to support nonescapable elements in the event that Swift were to gain the
capability to model them.

## Acknowledgments

Many thanks to Karoy Lorentey, Kavon Favardin, Joe Groff, Tony Parker, and Alejandro Alonso, for their input into this proposal.

[SE-0499]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md
[SE-0503]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md
[reparenting]: https://forums.swift.org/t/pitch-reparenting-resilient-protocols/84189
