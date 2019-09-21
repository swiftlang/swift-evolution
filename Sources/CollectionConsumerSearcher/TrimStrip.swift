//
// MARK: - Trim
//

extension Collection {
  public func trimFront<CC: CollectionConsumer>(
    _ cc: CC
  ) -> SubSequence where CC.C == Self {
    return self[(cc._clampedConsume(self))...]
  }
}
extension BidirectionalCollection {
  public func trimBack<CC: BidirectionalCollectionConsumer>(
    _ cc: CC
  ) -> SubSequence where CC.C == Self {
    return self[..<(cc._clampedConsumeBack(self))]
  }
  public func trim<CC: BidirectionalCollectionConsumer>(
    _ cc: CC
  ) -> SubSequence where CC.C == Self {
    return self[cc._clampedConsumeBoth(self)]
  }
}

//
// MARK: Trim Convenience Overloads
//

extension Collection {
  public func trimFront(_ predicate: (Element) -> Bool) -> SubSequence {
    return withoutActuallyEscaping(predicate) {
      return self.trimFront(_ConsumerPredicate($0))
    }
  }
}
extension Collection where Element: Equatable {
  public func trimFront(_ e: Element) -> SubSequence {
    return self.trimFront { (other: Element) in other == e }
  }
  public func trimFront<S: Sequence>(exactly s: S) -> SubSequence where S.Element == Element {
    return self.trimFront(_ConsumerSequence(s))
  }
}
extension Collection where Element: Hashable {
  public func trimFront(in s: Set<Element>) -> SubSequence {
    return self.trimFront { s.contains($0) }
  }
  public func trimFront<S: Sequence>(anyOf s: S) -> SubSequence where S.Element == Element {
    return self.trimFront(in: Set(s))
  }
}
extension BidirectionalCollection {
  public func trimBack(_ predicate: (Element) -> Bool) -> SubSequence {
    return withoutActuallyEscaping(predicate) {
      return self.trimBack(_ConsumerPredicate($0))
    }
  }
  public func trim(_ predicate: (Element) -> Bool) -> SubSequence {
    return withoutActuallyEscaping(predicate) {
      return self.trim(_ConsumerPredicate($0))
    }
  }
}
extension BidirectionalCollection where Element: Equatable {
  public func trimBack(_ e: Element) -> SubSequence {
    return self.trimBack { (other: Element) in other == e }
  }
  public func trim(_ e: Element) -> SubSequence {
    return self.trim { (other: Element) in other == e }
  }
  public func trimBack<S: BidirectionalCollection>(exactly s: S) -> SubSequence where S.Element == Element {
    return self.trimBack(_ConsumerSequence(s))
  }
  public func trim<S: BidirectionalCollection>(exactly s: S) -> SubSequence where S.Element == Element {
    return self.trim(_ConsumerSequence(s))
  }
}

extension BidirectionalCollection where Element: Hashable {
  public func trimBack(in s: Set<Element>) -> SubSequence {
    return self.trimBack { s.contains($0) }
  }
  public func trim(in s: Set<Element>) -> SubSequence {
    return self.trim { s.contains($0) }
  }
  public func trimBack<S: Sequence>(anyOf s: S) -> SubSequence where S.Element == Element {
    return self.trimBack(in: Set(s))
  }
  public func trim<S: Sequence>(anyOf s: S) -> SubSequence where S.Element == Element {
    return self.trim(in: Set(s))
  }
}

//
// MARK: - Strip
//

extension RangeReplaceableCollection {
  public mutating func stripFront<CC: CollectionConsumer>(_ cc: CC) where CC.C == Self {
    self.removeSubrange(..<cc._clampedConsume(self))
  }
}
extension RangeReplaceableCollection where Self: BidirectionalCollection {
  public mutating func stripBack<CC: BidirectionalCollectionConsumer>(
    _ cc: CC
  ) where CC.C == Self {
    self.removeSubrange(cc._clampedConsumeBack(self)...)
  }

  public mutating func strip<CC: BidirectionalCollectionConsumer>(
    _ cc: CC
  ) where CC.C == Self {
    self.stripFront(cc)
    self.stripBack(cc)
  }
}

// MARK: Strip Convenience Overloads

extension RangeReplaceableCollection {
  public mutating func stripFront(_ predicate: (Element) -> Bool) {
    withoutActuallyEscaping(predicate) {
      self.stripFront(_ConsumerPredicate($0))
    }
  }
}
extension RangeReplaceableCollection where Element: Equatable {
  public mutating func stripFront(_ e: Element) {
    self.stripFront { (other: Element) in other == e }
  }
  public mutating func stripFront<S: Sequence>(exactly s: S) where S.Element == Element {
    self.stripFront(_ConsumerSequence(s))
  }
}

extension RangeReplaceableCollection where Element: Hashable {
  public mutating func stripFront(in s: Set<Element>) {
    self.stripFront { s.contains($0) }
  }
  public mutating func stripFront<S: Sequence>(anyOf s: S) where S.Element == Element {
    self.stripFront(in: Set(s))
  }
}

extension RangeReplaceableCollection where Self: BidirectionalCollection {
  public mutating func stripBack(_ predicate: (Element) -> Bool) {
    withoutActuallyEscaping(predicate) { self.stripBack(_ConsumerPredicate($0)) }
  }
  public mutating func strip(_ predicate: (Element) -> Bool) {
    withoutActuallyEscaping(predicate) { self.strip(_ConsumerPredicate($0)) }
  }
}
extension RangeReplaceableCollection where Self: BidirectionalCollection, Element: Equatable {
  public mutating func stripBack(_ e: Element) {
    self.stripBack { (other: Element) in other == e }
  }
  public mutating func strip(_ e: Element) {
    self.strip { (other: Element) in other == e }
  }
  public mutating func stripBack<S: BidirectionalCollection>(exactly s: S) where S.Element == Element {
    self.stripBack(_ConsumerSequence(s))
  }
  public mutating func strip<S: BidirectionalCollection>(exactly s: S) where S.Element == Element {
    self.strip(_ConsumerSequence(s))
  }
}

extension RangeReplaceableCollection where Self: BidirectionalCollection, Element: Hashable {
  public mutating func stripBack(in s: Set<Element>) {
    self.stripBack { s.contains($0) }
  }
  public mutating func strip(in s: Set<Element>) {
    self.strip { s.contains($0) }
  }
  public mutating func stripBack<S: Sequence>(anyOf s: S) where S.Element == Element {
    self.stripBack(in: Set(s))
  }
  public mutating func strip<S: Sequence>(anyOf s: S) where S.Element == Element {
    self.strip(in: Set(s))
  }
}
