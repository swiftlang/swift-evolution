public protocol CollectionSearcher {
  associatedtype C: Collection

  associatedtype State = ()

  func preprocess(_: C) -> State

  func search(_: C, from: C.Index, _: inout State) -> Range<C.Index>?
}

extension CollectionSearcher where State == () {
  public func preprocess(_: C) -> State { return () }

  public func search(_ c: C, from: C.Index) -> Range<C.Index>? {
    var state: () = ()
    return self.search(c, from: from, &state)
  }
}

public protocol BidirectionalCollectionSearcher: CollectionSearcher
where C: BidirectionalCollection {
  func searchBack(_ c: C, endingAt idx: C.Index, _: inout State) -> Range<C.Index>?
}

extension BidirectionalCollectionSearcher where State == () {
  func searchBack(_ c: C, endingAt idx: C.Index) -> Range<C.Index>? {
    var state: () = ()
    return searchBack(c, endingAt: idx, &state)
  }
}

// TODO: Consider a subprotocol for StatelessCollectionSearcher, so that conformers don't
// have to have () in their signatures.

extension CollectionSearcher {
  public func searchFirst(_ c: C) -> Range<C.Index>? {
    var state = preprocess(c)
    return self.search(c, from: c.startIndex, &state)
  }

  // FIXME(SR-11100): Remove
  internal func _searchFirstSR11100<Other: Collection>(_ c: Other) -> Range<Other.Index>? {
    let selfResult = searchFirst(c as! C)
    let result = selfResult as! Range<Other.Index>?
    return result
  }
}

extension BidirectionalCollectionSearcher {
  public func searchLast(_ c: C) -> Range<C.Index>? {
    var state = preprocess(c)
    return self.searchBack(c, endingAt: c.endIndex, &state)
  }

  // FIXME(SR-11100): Remove
  internal func _searchLastSR11100<Other: Collection>(_ c: Other) -> Range<Other.Index>? {
    let selfResult = searchLast(c as! C)
    let result = selfResult as! Range<Other.Index>?
    return result
  }
}

internal struct _SearcherPredicate<C: Collection>: CollectionSearcher {
  internal typealias Element = C.Element
  internal let predicate: (Element) -> Bool

  internal init(_ f: @escaping (Element) -> Bool, of: C.Type = C.self) {
    self.predicate = f
  }

  internal func search(_ c: C, from idx: C.Index, _: inout ()) -> Range<C.Index>? {
    guard let lower = c[idx...].firstIndex(where: predicate) else { return nil }
    return lower ..< c.index(after: lower)
  }
}

extension _SearcherPredicate: BidirectionalCollectionSearcher where C: BidirectionalCollection {
  internal func searchBack(_ c: C, endingAt idx: C.Index, _:inout ()) -> Range<C.Index>? {
    guard let lower = c[..<idx].lastIndex(where: predicate) else { return nil }
    return lower ..< c.index(after: lower)
  }
}

extension Collection where SubSequence == Self {
  internal var _range: Range<Index> { return startIndex ..< endIndex }
}

// TODO: figure out how best to provide this to library authors, we probably don't want to
// polute their name spaces.
//
// Provide a O(n * m) naive searcher implementation
public struct _NaiveSearcherConsumer<
  CS: CollectionConsumer
> {
  public typealias C = CS.C

  internal let consumer: CS

  public init(_ cs: CS) { self.consumer = cs }
}

extension _NaiveSearcherConsumer: CollectionSearcher{
  public func search(_ c: C, from idx: C.Index, _: inout ()) -> Range<C.Index>? {
    var lower = idx
    while lower < c.endIndex {
      if let upper = consumer.consume(c, from: lower) {
        return lower ..< upper
      }
      lower = c.index(after: lower)
    }
    return nil
  }
}
extension _NaiveSearcherConsumer: BidirectionalCollectionSearcher
where CS: BidirectionalCollectionConsumer {
  public func searchBack(_ c: C, endingAt idx: C.Index, _: inout ()) -> Range<C.Index>? {
    var upper = idx
    while upper >= c.startIndex {
      if let lower = consumer.consumeBack(c, endingAt: upper) {
        return lower ..< upper
      }
      guard upper > c.startIndex else { return nil }

      upper = c.index(before: upper)
    }
    return nil
  }
}

internal struct _SearcherSequence<
  C: Collection, S: Sequence
>: CollectionSearcher where C.Element == S.Element, C.Element: Equatable {
  internal typealias Element = C.Element

  internal let searcher: _NaiveSearcherConsumer<_ConsumerSequence<C, S>>

  init(_ s: S) {
    self.searcher = _NaiveSearcherConsumer(_ConsumerSequence(s))
  }

  func search(_ c: C, from idx: C.Index, _ state: inout ()) -> Range<C.Index>? {
    return searcher.search(c, from: idx, &state)
  }

}

extension _SearcherSequence: BidirectionalCollectionSearcher
  where C: BidirectionalCollection, S: BidirectionalCollection
{
  func searchBack(_ c: C, endingAt idx: C.Index, _ state: inout ()) -> Range<C.Index>? {
    return searcher.searchBack(c, endingAt: idx, &state)
  }
}

