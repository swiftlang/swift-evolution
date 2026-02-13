# Borrowing Sequence

* Proposal: [SE-NNNN](NNNN-borrowing-sequence.md)
* Authors: [Nate Cook](https://github.com/natecook1000), [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#86066](https://github.com/swiftlang/swift/pull/86066)
* Upcoming Feature Flag: TBD
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

We propose a new protocol for iteration, `BorrowingSequence`, which 
will work with noncopyable types and provide more efficient iteration
in some circumstances for copyable types. The Swift compiler will
support use of this protocol via the familiar `for...in` syntax.

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
}
```

This protocol shape is very similar to the current `Sequence`. It has a primary
associated type for the element, and just one method
that hands you an iterator you can use to iterate the elements of the sequence.

The differences being:

- It allows conformance by noncopyable types. Note that copyable and escapable
types can also conform---but the protocol is designed to not require it.
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

extension BorrowingIteratorProtocol where Element: ~Copyable {
  // default implementation
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

This desugared `while` loop is a lot more complex than its `Sequence`
equivalent. But the day-to-day usage remains exactly the same, with
the added complexity left to the caller.

Note that in the case of `Array`, the new protocol results in much less overhead
for the optimizer to eliminate. Iterating a `Span` in the inner loop is a lot
closer to the "ideal" model of advancing a pointer over a buffer and accessing
the elements directly. It is therefore expected that this design will result
in better performance in some cases where today the optimizer is unable
to eliminate the overhead of Swift's `Array`.

### Borrowing sequence operations

The addition of appropriate algorithms matching those on `Sequence` will be specified 
in an upcoming proposal. Much like `Sequence` operations, these will be written as 
extensions on the `BorrowingSequence` protocol. The following two examples demonstrate 
how some operations will be as simple as their `Sequence` counterparts, while others 
will require more careful manual iteration over spans.

The differences between `Sequence.reduce(into:_:)` and `BorrowingSequence.reduce(_:_:)` 
are only in the parameters' ownership annotations, because we only need a borrowing 
access to one element at a time. The implementation itself is essentially identical:

```swift
extension BorrowingSequence {
   func reduce<T: ~Copyable>(
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

For `elementsEqual`, however, we use manual iteration to compare spans of equal size between two `BorrowingSequences`:

```swift
extension BorrowingSequence where Self: ~Escapable & ~Copyable, Element: Equatable {
   func elementsEqual<S: BorrowingSequence<Element>>(
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

`InlineArray` and the various `Span` types will conform to `BorrowingSequence`,
with `Span` also conforming to `BorrowingIteratorProtocol` and acting as the iterator
for all these types.

```swift
extension Span: BorrowingSequence, BorrowingIteratorProtocol
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> Self

   @lifetime(&self)
   mutating func nextSpan(maximumCount: Int) -> Self
    
   mutating func skip(by maximumOffset: Int) -> Int
}

extension MutableSpan: BorrowingSequence
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> Span<Element>
}

extension RawSpan: BorrowingSequence {
   @lifetime(borrow self)
   func makeBorrowingIterator() -> Span<UInt8>
}

extension MutableRawSpan: BorrowingSequence {
   @lifetime(borrow self)
   func makeBorrowingIterator() -> Span<UInt8>
}

extension InlineArray: BorrowingSequence
   where Self: ~Copyable & ~Escapable, Element: ~Copyable
{
   @lifetime(borrow self)
   func makeBorrowingIterator() -> Span<Element>
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

### `for` loop desugaring when both protocols are available

Note that in this case, it is likely that using `BorrowingSequence` to iterate
`UnfoldSequence` will be slightly _less_ efficient than using its `Sequence`
conformance, depending on the element type, given the overhead of moving the
element into the `currentValue` storage. If the element is non-trivial, this
may result in additional copies being made with the new borrowing iteration 
model, where with the existing `next()` operation, the element can be returned 
and consumed directly into its destination.

For example, imagine using `UnfoldSequence` to generate strings that are being streamed
into an `Array<String>`:
- with `Sequence`, the strings are produced by the `UnfoldSequence`, returned by `next()`,
and consumed into the `Array` with no logical copies
- with `BorrowingSequence`, the strings are produced, stored in the `currentValue` variable,
**copied** out of the `Span` of that variable into the `Array`, and then the value in
`currentValue` is destroyed.

For this reason, it may not be appropriate to switch all `for` iteration to use
`BorrowingSequence` when `Sequence` is available. How to determine which cases are
better (such as `Array` is expected to be) and which are worse (such as the `UnfoldSequence`
example above) needs further investigation. 

An experimental feature, `BorrowingForLoopByDefault`, will be made available
to allow switching of the compiler to default to always use the new desugaring,
to allow for experimentation with the impact on performance.

Regardless, types that _do not_ offer a `Sequence` conformance today (noncopyable types, 
`InlineArray`, and `Span` itself) will use the new desugaring.  Making that switch is left
to future proposals. For now, if a `Sequence` conformance is available, it will be used
even if `BorrowingSequence` is also available.

## Source compatibility

This proposal introduces a new protocol, `BorrowingSequence`.
Existing conformers to `Sequence` can also implement `BorrowingSequence`. This is
entirely source compatible.

As discussed above, switching to use the new `BorrowingSequence` protocol
by default could impact runtime performance, and so while source compatible,
needs further control.

There is an additional source compatibility edge case that would be caused
by changing `for` loops to :

```swift
var array: [Int] = // ...
for element in array {
  // when used with BorrowingSequence, this
  // would cause a compile time error
  array[0] = 1
}
```

This is similar to a simpler example where the reason is clearer:

```swift
var array: [Int] = // ...
let span = array.span
// error: Overlapping accesses to 'array', but modification requires exclusive access
array[0] = 99
```

Now, it is usually unwise or unintentional to modify a collection while iterating over it.
Often the user does not realize that this triggers copy-on-write for the collection
they are iterating. But this potential source of breakage that should be considered.

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

## Acknowledgments

Many thanks to Karoy Lorentey, Kavon Favardin, Joe Groff, Tony Parker, and Alejandro Alonso, for their input into this proposal.

[SE-0499]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0499-support-non-copyable-simple-protocols.md
[SE-0503]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0503-suppressed-associated-types.md
[reparenting]: https://forums.swift.org/t/pitch-reparenting-resilient-protocols/84189
