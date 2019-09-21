//
// MARK: Search APIs
//


internal enum _SearchResult<Index: Comparable> {
  case found(Range<Index>)
  case notFound(Range<Index>)
}
internal struct _SearchResultSequence<C, CS: CollectionSearcher> where C == CS.C {
  let collection: C
  let searcher: CS
  var state: CS.State
  var currentIndex: C.Index

  init(_ c: C, _ cs: CS) {
    self.collection = c
    self.searcher = cs
    self.state = searcher.preprocess(c)
    self.currentIndex = c.startIndex
  }
}

extension _SearchResultSequence: Sequence, IteratorProtocol {
  typealias Element = _SearchResult<C.Index>

  mutating func next() -> Element? {
    guard currentIndex < collection.endIndex else { return nil }

    guard let range = searcher.search(collection, from: currentIndex, &state) else {
      defer { self.currentIndex = collection.endIndex }
      return .notFound(currentIndex ..< collection.endIndex)
    }

    if currentIndex != range.lowerBound {
      defer { self.currentIndex = range.lowerBound }
      return .notFound(currentIndex ..< range.lowerBound)
    }

    defer { self.currentIndex = range.upperBound }
    return .found(range)
  }
}

public struct CollectionMatchSequence<C, CS: CollectionSearcher> where CS.C == C {
  var searchResults: _SearchResultSequence<C, CS>

  init(_ c: C, _ cs: CS) {
    self.searchResults = _SearchResultSequence(c, cs)
  }
}

extension CollectionMatchSequence: Sequence, IteratorProtocol {
  public typealias Element = C.SubSequence

  public mutating func next() -> Element? {
    while let nextResult = searchResults.next() {
      if case .found(let r) = nextResult { return searchResults.collection[r] }
    }
    return nil
  }
}

extension Collection {
  internal func _searchResults<CS: CollectionSearcher>(
    _ searcher: CS
  ) -> _SearchResultSequence<Self, CS> where CS.C == Self {
    return _SearchResultSequence(self, searcher)
  }

  // TODO: want opaque return type with Element == SubSequence
  public func matches<CS: CollectionSearcher>(
    _ searcher: CS
  ) -> CollectionMatchSequence<Self, CS> {
    return CollectionMatchSequence(self, searcher)
  }
}


extension Collection {
  internal func _forEachSearchResult<CS: CollectionSearcher>(
    _ searcher: CS, _ body: (_SearchResult<Index>) throws -> Void
  ) rethrows where CS.C == Self {
    for result in self._searchResults(searcher) {
      try body(result)
    }
  }
}

//
// MARK: Search APIs
//
extension Collection {
  public func split<CS: CollectionSearcher>(
    _ cs: CS, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [SubSequence] where CS.C == Self {

    guard maxSplits > 0 else {
      return self.isEmpty && omittingEmptySubsequences ? [] : [self[...]]
    }

    var result = Array<SubSequence>()
    var trailingLower = self.startIndex
    for search in self._searchResults(cs) {
      if case .found(let r) = search {
        defer { trailingLower = r.upperBound }
        if trailingLower != r.lowerBound || !omittingEmptySubsequences {
          result.append(self[trailingLower ..< r.lowerBound])
          if result.count == maxSplits { break }
        }
      }
    }

    if trailingLower != self.endIndex || !omittingEmptySubsequences {
      result.append(self[trailingLower ..< self.endIndex])
    }

    return result
  }

  // NOTE: The first two below are redundant with split(separator:) and split(where:), but are
  // included and built upon for testing and prototyping purposes
  public func split(
    _ predicate: (Element) -> Bool, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [Self.SubSequence] {
    return withoutActuallyEscaping(predicate) {
      let searcher = _SearcherPredicate<Self>($0)
      return self.split(
        searcher, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences)
    }
  }
}
extension Collection where Element: Equatable {
  public func split(
    _ elt: Element, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [Self.SubSequence] {
    return self.split(
      { $0 == elt }, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences)
  }
  public func split<C: Collection>(
    _ c: C, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [Self.SubSequence] where C.Element == Element {
    let searcher = _SearcherSequence<Self, C>(c)
    return self.split(
      searcher, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences)
  }
}
extension Collection where Element: Hashable {
  public func split(
    anyOf set: Set<Element>, maxSplits: Int = Int.max, omittingEmptySubsequences: Bool = true
  ) -> [Self.SubSequence] {
    return self.split(
      { set.contains($0) },
      maxSplits: maxSplits,
      omittingEmptySubsequences: omittingEmptySubsequences)
  }
}
