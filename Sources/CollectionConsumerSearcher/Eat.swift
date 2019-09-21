// TODO: eatBack for Bidi? eatAround? Consistent naming convention

extension Collection where SubSequence == Self {
  @discardableResult
  public mutating func eat(upTo idx: Index) -> SubSequence {
    defer { self = self[idx...] }
    return self[..<idx]
  }

  @discardableResult
  public mutating func eat(from idx: Index) -> SubSequence {
    defer { self = self[..<idx] }
    return self[idx...]
  }

  // FIXME: Needed?
  @discardableResult
  public mutating func eat(
    around range: Range<Index>
  ) -> (prefix: SubSequence, suffix: SubSequence) {
    defer { self = self[range] }
    return (self[..<range.lowerBound], self[range.upperBound...])
  }

  @discardableResult
  public mutating func eat<CC: CollectionConsumer>(
    _ cc: CC
  ) -> SubSequence
    // where CC.C == Self // FIXME(SR-11100): Add
  {
    return self.eat(upTo: cc._clampedConsumeSR11100(self))
  }

  @discardableResult
  public mutating func eatAll<CS: CollectionConsumer>(
    _ cs: CS
  ) -> [SubSequence]
    // where CC.C == Self // FIXME(SR-11100): Add
  {
    var result: [Self] = []
    while true {
      let subseq = self.eat(cs)
      guard !subseq.isEmpty else { return result }
      result.append(subseq)
    }
  }

  @discardableResult
  public mutating func eat<CS: CollectionSearcher>(
    untilFirst cs: CS
  ) -> SubSequence
    // where CS.C == Self // FIXME(SR-11100): Add
  {
    let idx = cs._searchFirstSR11100(self)?.lowerBound ?? self.startIndex
    return self.eat(upTo: idx)
  }

  @discardableResult
  public mutating func eat<CS: CollectionSearcher>(
    throughFirst cs: CS
  ) -> SubSequence
    // where CS.C == Self // FIXME(SR-11100): Add
  {
    let idx = cs._searchFirstSR11100(self)?.upperBound ?? self.startIndex
    return self.eat(upTo: idx)
  }
}

extension BidirectionalCollection where SubSequence == Self {
  @discardableResult
  public mutating func eat<CS: BidirectionalCollectionSearcher>(
    untilLast cs: CS
  ) -> SubSequence
    // where CS.C == Self // FIXME(SR-11100): Add
  {
    let idx = cs._searchLastSR11100(self)?.lowerBound ?? self.startIndex
    return self.eat(upTo: idx)
  }

  @discardableResult
  public mutating func eat<CS: BidirectionalCollectionSearcher>(
    throughLast cs: CS
  ) -> SubSequence
    // where CS.C == Self // FIXME(SR-11100): Add
  {
    let idx = cs._searchLastSR11100(self)?.upperBound ?? self.startIndex
    return self.eat(upTo: idx)
  }
}


//
// MARK: Eat Convenience Overloads
//

extension Collection where SubSequence == Self {
  // TODO: optionality of return? Probably a good idea to signal if something happened...

  // TODO: worth having?
  @discardableResult
  public mutating func eat() -> Element? {
    return self.eat(count: 1).first
  }

  @discardableResult
  public mutating func eat(count n: Int = 0) -> SubSequence {
    let idx = self.index(self.startIndex, offsetBy: n, limitedBy: self.endIndex) ?? self.endIndex
    return self.eat(upTo: idx)
  }

  @discardableResult
  public mutating func eat(one predicate: (Element) -> Bool) -> Element? {
    guard let elt = self.first, predicate(elt) else { return nil }
    return eat()
  }
  @discardableResult
  public mutating func eat(while predicate: (Element) -> Bool) -> SubSequence {
    return withoutActuallyEscaping(predicate) {
      return self.eat(_ConsumerPredicate<Self>($0))
    }
  }
  @discardableResult
  public mutating func eat(untilFirst predicate: (Element) -> Bool) -> SubSequence {
    withoutActuallyEscaping(predicate) {
      self.eat(untilFirst: _SearcherPredicate($0, of: Self.self))
    }
  }
  @discardableResult
  public mutating func eat(throughFirst predicate: (Element) -> Bool) -> SubSequence {
    withoutActuallyEscaping(predicate) {
      self.eat(throughFirst: _SearcherPredicate($0, of: Self.self))
    }
  }
}

extension BidirectionalCollection where SubSequence == Self {
  @discardableResult
  public mutating func eat(untilLast predicate: (Element) -> Bool) -> SubSequence {
    withoutActuallyEscaping(predicate) {
      self.eat(untilLast: _SearcherPredicate($0, of: Self.self))
    }
  }
  @discardableResult
  public mutating func eat(throughLast predicate: (Element) -> Bool) -> SubSequence {
    withoutActuallyEscaping(predicate) {
      self.eat(throughLast: _SearcherPredicate($0, of: Self.self))
    }
  }
}


extension Collection where SubSequence == Self, Element: Equatable {
  @discardableResult
  public mutating func eat(one e: Element) -> Element? {
    return self.eat(one: { (other: Element) in other == e })
  }
  @discardableResult
  public mutating func eat(many e: Element) -> SubSequence {
    return self.eat(while: { (other: Element) in other == e })
  }
  @discardableResult
  public mutating func eat(untilFirst e: Element) -> SubSequence {
    return self.eat(untilFirst: { (other: Element) in other == e })
  }
  @discardableResult
  public mutating func eat(throughFirst e: Element) -> SubSequence {
    return self.eat(throughFirst: { (other: Element) in other == e })
  }

  @discardableResult
  public mutating func eat<S: Sequence>(exactly s: S) -> SubSequence where S.Element == Element {
    return self.eat(_ConsumerSequence<Self, S>(s))
  }
  @discardableResult
  public mutating func eat<S: Sequence>(
    untilFirst s: S
  ) -> SubSequence where S.Element == Element {
    return self.eat(untilFirst: _SearcherSequence<Self, S>(s))
  }
  @discardableResult
  public mutating func eat<S: Sequence>(
    throughFirst s: S
  ) -> SubSequence where S.Element == Element {
    return self.eat(throughFirst: _SearcherSequence<Self, S>(s))
  }
}

extension BidirectionalCollection where SubSequence == Self, Element: Equatable {
    @discardableResult
    public mutating func eat(untilLast e: Element) -> SubSequence {
      return self.eat(untilLast: { (other: Element) in other == e })
    }
    @discardableResult
    public mutating func eat(throughLast e: Element) -> SubSequence {
      return self.eat(throughLast: { (other: Element) in other == e })
    }
}

extension Collection where SubSequence == Self, Element: Hashable {
  @discardableResult
  public mutating func eat(oneIn s: Set<Element>) -> Element? {
    return self.eat(one: { s.contains($0) })
  }
  @discardableResult
  public mutating func eat(whileIn s: Set<Element>) -> SubSequence {
    return self.eat(while: { s.contains($0) })
  }
  @discardableResult
  public mutating func eat(untilFirst s: Set<Element>) -> SubSequence {
    return self.eat(untilFirst: { s.contains($0) })
  }
  @discardableResult
  public mutating func eat(throughFirst s: Set<Element>) -> SubSequence {
    return self.eat(throughFirst: { s.contains($0) })
  }
}

extension BidirectionalCollection where SubSequence == Self, Element: Hashable {
  @discardableResult
  public mutating func eat(untilLast s: Set<Element>) -> SubSequence {
    return self.eat(untilLast: { s.contains($0) })
  }
  @discardableResult
  public mutating func eat(throughLast s: Set<Element>) -> SubSequence {
    return self.eat(throughLast: { s.contains($0) })
  }
}

