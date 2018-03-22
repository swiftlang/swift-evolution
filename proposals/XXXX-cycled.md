# Extending sequence functionality with cycles, batches, and concatenation

* Proposal: SE-TBD
* Author(s): [Erica Sadun](http://github.com/erica)
* Review manager: TBD
* Status: **Preliminary Implementation in Proposal** 

<!---
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
* -->

## Introduction

This proposal several methods on `Sequence`, adding commonly requested sequence functionality including sequence cycling, counted subsequence batches, and sequence concatenation.

Part of this proposal was requested in [SR-6864](https://bugs.swift.org/browse/SR-6864)

This proposal was discussed on-forum in 

* [\[Starter Pitch\] Introducing a `cycled` method to `Sequence`](https://forums.swift.org/t/starter-pitch-introducing-a-cycled-method-to-sequence/11254) 
* [Pitch: Sequence enhancements: chaining, repeating, batching](https://forums.swift.org/t/pitch-sequence-enhancements-chaining-repeating-batching/11635) 
* [What makes a good lazy procedure? And how to do it?](https://forums.swift.org/t/what-makes-a-good-lazy-procedure-and-how-to-do-it/7338/2) (about Collections, not Sequences)
* [Proposal: CollectionType.cycle property for an infinite sequence](https://forums.swift.org/t/proposal-collectiontype-cycle-property-for-an-infinite-sequence/798) thread introduced by [Kevin Ballard](https://github.com/kballard)

## Motivation

From [SR-6864](https://bugs.swift.org/browse/SR-6864):

It is often useful to cycle over a sequence indefinitely. For example, just like you can write `zip(repeatElement("foo", count: Int.max), myArray)` and `zip(1..., myArray)`, you could write `zip([.grey,.white].cycle(), myArray)`.

The spelling of `cycle` has been changed to `cycled` for this proposal. It further adds a counting component, enabling you to perform tasks like creating a 25% duty cycle:

```swift
// Create a 25% duty cycle rectangular wave, then play it
let naiveFlipFlop = [true].followed(by: repeatElement(false, count: 3))
let bandLimited = convolve(kernel, with: naiveFlipflop)
let wave = bandLimited.cycled(.forever)
play(wave)
```

--

Batching enables you to perform tasks related to scheduling, like grouping items or personnel into work units. When you have a large (or infinite) sequence to chew through in batches, it’s helpful to perform actions on subsequences. For example:

```swift
myHugeSequence
    .batched(by: Worker.batchSize)
    .forEach(schedule(batch))
```

--

Concatenation enables you to join sequences from various sources, append them together, and treat them as a single sequence.

```swift
firstSequence.appending(secondSequence)
```

## Detailed Design: Cycling

Introducing a new `SequenceCycle` type enables you to store a sequence, reconstructing it each time its elements are exhausted. 

```swift
/// Enumerate how often a sequence should cycle
public enum SequenceCycleDuration { case forever, times(Int) }

/// A sequence containing the same elements as `BaseSequence`
/// repeated infinitely or n times.
///
/// Construct using `sequence.cycled()`
public struct SequenceCycle<BaseSequence: Sequence> : Sequence, IteratorProtocol {
  
  public mutating func next() -> BaseSequence.Element? {
    guard _count != 0 else { return nil }
    if let nextElement = _iterator.next() {
      return nextElement
    }
    _iterator = _sequence.makeIterator()
    
    // If working through a count (positive numbers only)
    // reduce the count. When it hits zero, terminate
    // the sequence. A negative number never terminates.
    if _count > 0 {
      _count -= 1; if _count == 0 { return nil }
    }
    return _iterator.next()
  }
  
  /// Access only through `Sequence.cycled()`
  fileprivate init(_ sequence: BaseSequence, count: Int = -1) {
    _sequence = sequence
    _iterator = sequence.makeIterator()
    _count = count
  }
  
  private let _sequence: BaseSequence
  private var _iterator: BaseSequence.Iterator
  private var _count: Int
}


extension Sequence {
  /// Return a lazy sequence endlessly repeating the elements
  /// of `self` in an infinite or counted cycle.
  ///
  /// For example:
  ///
  ///     Array(zip(0...4, ["even", "odd"].cycled()))
  ///
  /// returns
  ///
  ///     [(0, "even"), (1, "odd"), (2, "even"), (3, "odd"), (4, "even")]
  ///
  /// and
  ///
  ///     Array(["even", "odd"].cycled(.times(2)))
  ///     // ["even", "odd", "even", "odd"]
  ///
  /// - Note: Passing a negative number to `.count(times)` is treated
  ///   as passing `.forever`
  ///
  /// - Remark: See [SR-6864](https://bugs.swift.org/browse/SR-6864)
  ///
  /// - parameter style: Supply `.forever` (the default) or `.times(n)`
  public func cycled(_ style: SequenceCycleDuration = .forever) -> SequenceCycle<Self> {
    switch style {
    case .forever: return SequenceCycle(self)
    case .times(let count):
      return SequenceCycle(self, count: count)
    }
  }
}
```

For example, you might zip a range of numbers with the words `["even", "odd"]`:

```swift
Array(zip(0...4, ["even", "odd"].cycled()))
// returns [(0, "even"), (1, "odd"), (2, "even"), (3, "odd"), (4, "even")]
```

The single-element 
```swift
repeatElement("foo", count: Int.max)
```
call evolves to
```swift
["foo"].cycled()
// or
CollectionOfOne("foo").cycled()
``` 

Although this forces you to place the string within square
brackets or use `CollectionOfOne`, the results remain readable and the intent clear.

No special checks are made for empty sequences. The result of the following code is `[]`.

```swift
Array(zip(myArray, Array<String>().cycled()))
```

You can specify how many times to cycle using the optional enumeration argument:

```swift
mySequence.cycled(.forever)
mySequence.cycled(.times(2))
```

* Supplying any negative number to `times(Int)` will cycle forever.
* Supplying zero returns an empty sequence

This design avoids `repeatElement`, which is limited to Int.max repeatitions and produces `FlattenSequence<Repeated<Self>>`. The efficiency of both approaches is essentially indistinguishable and the code for `repeatElement` is significantly shorter:

```swift
extension Sequence {
  /// Return a lazy sequence repeating the elements of
  /// `self` exactly n times
  public func cycled(_ duration: SequenceCycleDuration) -> FlattenSequence<Repeated<Self>> {
    var repetitions = Int.max
    if case .times(let howMany) = duration { repetitions = howMany }
    return repeatElement(self, count: repetitions).joined()
  }
}
```

Benchmarks showed that the primary approach is slightly more performant than the repeated version and allows desired "infinite sequence" characteristics:

```
'-[Test2Tests.CycleBenchmark testCycledRepeated]' passed (3.526 seconds).
'-[Test2Tests.CycleBenchmark testSequenceCycle]' passed (2.360 seconds).
Starting Test: Using cycledSequenceCycle()
Ending Test : Using cycledSequenceCycle()
Elapsed time: 0.496450918028131
Starting Test: Using cycledRepeated()
Ending Test : Using cycledRepeated()
Elapsed time: 0.509369512787089
```


## Detailed Design: Batching

Introducing a new `BatchedSequence` creates an iterator producing a series of subsequences batched to a maximum size supplied by the user:

```swift
/// A sequence containing the elements of a sequence
/// taken n at a time, with any remainder being greater
/// than one and less than n. Each group is returned as
/// a subsequence of the base sequence.
///
/// No guarantees are made that the sequence terminates.
///
/// Construct using `sequence.batched(by: _count_)`.
public struct BatchedSequence<BaseSequence: Sequence>: Sequence, IteratorProtocol {
  public mutating func next() -> BaseSequence.SubSequence? {
    defer { _sequence = _sequence.dropFirst(_count) }
    
    let batch = _sequence.prefix(_count)
    
    // Ensure non-empty guarantee.
    // FIXME: Surely there has to be a better solution
    var prefixIterator = batch.makeIterator()
    guard let _ = prefixIterator.next() else { return nil }
    return batch
  }
  
  fileprivate init(_ sequence: BaseSequence, count: Int) {
    (_sequence, _count) = (sequence.dropFirst(0), count)
  }
  
  private var _sequence: BaseSequence.SubSequence
  private var _count: Int
}

extension Sequence {
  /// Returns batched subsequences. A subsequence may not include
  /// a full count of items but it will include at least one.
  ///
  /// - Parameter maxCount: the maximum number of items to appear
  ///   within a batched subsequence.
  public func batched(by maxCount: Int) -> BatchedSequence<Self> {
    return BatchedSequence(self, count: maxCount)
  }
}
```

For example, you might return batches of 4, producing `"a", "b", "c", "a"`, `"b", "c", "a", "b"`, and `"c"`. You will never get an empty batch but the final batch count may fall below the maximum count requested.

```swift
let sequence = ["a", "b", "c"].cycled(.times(3))
let batchedSequence = sequence.batched(by: 4)
```

Under stress tests, the batch iterator test for nil tied with coersion to an array and testing for emptiness. Both ran significantly faster than testing for `batch.first(where: { _ in true }) == nil`.

## Detailed Design: Appending

The `ConcatenatedSequence` type produces the elements of one sequence followed by another. This approach avoids type erasure:

```swift
/// A sequence containing the elements of a sequence followed
/// by the elements of another sequence.
///
/// No guarantees are made that either sequence ever completes.
///
/// Construct using `sequence1.appending(sequence2)`
/// A sequence containing the elements of a sequence followed
/// by the elements of another sequence.
///
/// No guarantees are made that either sequence ever completes.
///
/// Construct using `sequence1.appending(sequence2)`
public struct ConcatenatedSequence<Sequence1: Sequence, Sequence2: Sequence>: Sequence, IteratorProtocol where Sequence1.Iterator.Element == Sequence2.Iterator.Element {
  
  public typealias Element = Sequence1.Iterator.Element
  
  // @Dante-Broggi: The problem with calling next() repeatedly on an iterator that has returned nil is that back in swift 1 it was a programmer error to do so. And then they realized that IIRC Zip2Iterator was violating this, and changed to “if it has returned nil it must return nil indefinitely”
  public mutating func next() -> Element? {
    return _iterator1.next() ?? _iterator2.next()
  }
  
  /// Access only through `Sequence.append(Sequence)`
  fileprivate init(_ s1: Sequence1, _ s2: Sequence2) {
    _iterator1 = s1.makeIterator()
    _iterator2 = s2.makeIterator()
  }
  
  private var _iterator1: Sequence1.Iterator
  private var _iterator2: Sequence2.Iterator
}

extension Sequence {
  /// Return a sequence composed of one sequence followed by another sequence
  public func appending<S: Sequence>(_ sequence: S ) -> ConcatenatedSequence<Self, S>
    where S.Iterator.Element == Self.Iterator.Element {
      return ConcatenatedSequence(self, sequence)
  }
}
```

The alternative design is simpler but may lose conditional conformance through type erasure:

```swift
/*
 
 @allevato: The key observation is that when you’ve concatenated two 
 sequences in this fashion, you don’t care about the original sequence
 types anymore—just the element type.
 
 @Karl: If you erase the sequences, you lose the ability to make the
 result conditionally conform to things like RandomAccessCollection. 
 You’ve basically remade “joined”.
 
 */

/// A sequence containing the elements of a sequence followed
/// by the elements of another sequence.
///
/// No guarantees are made that either sequence ever completes.
///
/// Construct using `sequence1.appending(sequence2)`
public struct ConcatenatedSequence<Element>: Sequence, IteratorProtocol {
  
  public mutating func next() -> Element? {
    return _firstIterator.next() ?? _secondIterator.next()
  }
  
  /// Access only through `Sequence.append(Sequence)`
  fileprivate init<First: Sequence, Second: Sequence>(_ s1: First, _ s2: Second)
    where First.Element == Element, Second.Element == Element {
      _firstIterator = AnyIterator(s1.makeIterator())
      _secondIterator = AnyIterator(s2.makeIterator())
  }
  
  private var _firstIterator: AnyIterator<Element>
  private var _secondIterator: AnyIterator<Element>
}

extension Sequence {
  /// Return a sequence composed of one sequence followed by another sequence
  public func appending<S: Sequence>(_ sequence: S ) -> ConcatenatedSequence<S.Element>
    where S.Element == Self.Element {
      return ConcatenatedSequence(self, sequence)
  }
}
```

## Source compatibility

This proposal is strictly additive.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect ABI resilience.

## Alternatives Considered

* Swift may want to consider further adopting Python-inspired iteration tools from the [itertools](https://docs.python.org/3/library/itertools.html) library. 

* A cycling approach using the built-in `sequence(first:,next:)` function was discarded as it does not support the case that repeats an empty sequence.