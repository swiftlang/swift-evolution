import Foundation
import CollectionConsumerSearcher

extension CharacterSet {
  // TODO: We'd really like opaque return type with bound associated types for this...
  public struct CharacterSearcher<C: Collection> where C.Element == Character {
    internal var scalarSet: CharacterSet
    public init(_ set: CharacterSet) { self.scalarSet = set }
  }

  public struct UnicodeScalarSearcher<C: Collection> where C.Element == Unicode.Scalar {
    internal var scalarSet: CharacterSet
    public init(_ set: CharacterSet) { self.scalarSet = set }
  }

}

// TODO: Bidi too...
extension CharacterSet.CharacterSearcher: CollectionConsumer {
  public func consume(_ str: C, from: C.Index) -> C.Index? {
    var charIdx = from
    var result: C.Index? = nil
    while charIdx < str.endIndex {
      let char = str[charIdx]
      guard char.unicodeScalars.allSatisfy(scalarSet.contains) else { return result }
      charIdx = str.index(after: charIdx)
      result = charIdx
    }
    return result
  }
}
extension CharacterSet.CharacterSearcher: CollectionSearcher {
  public func search(
    _ str: C, from: C.Index, _ state: inout ()
  ) -> Range<C.Index>? {
    _NaiveSearcherConsumer(self).search(str, from: from, &state)
  }
}
extension CharacterSet.UnicodeScalarSearcher: CollectionConsumer {
  public func consume(_ str: C, from: C.Index) -> C.Index? {
    var charIdx = from
    var result: C.Index? = nil
    while charIdx < str.endIndex {
      guard scalarSet.contains(str[charIdx]) else { return result }
      charIdx = str.index(after: charIdx)
      result = charIdx
    }
    return result
  }
}
extension CharacterSet.UnicodeScalarSearcher: CollectionSearcher {
  public func search(
    _ str: C, from: C.Index, _ state: inout ()
  ) -> Range<C.Index>? {
    _NaiveSearcherConsumer(self).search(str, from: from, &state)
  }
}

extension CharacterSet {
  public func searcher<C: Collection>(
    for: C.Type = C.self
  ) -> CharacterSearcher<C> where C.Element == Character {
    return CharacterSearcher(self)
  }
  public func searcher<C: Collection>(
    for: C.Type = C.self
  ) -> UnicodeScalarSearcher<C> where C.Element == Unicode.Scalar {
    return UnicodeScalarSearcher(self)
  }
}

extension CharacterSet: CollectionConsumer {
  public typealias C = String

  public func consume(_ str: String, from: String.Index) -> String.Index? {
    searcher().consume(str, from: from)
  }
}

extension CharacterSet: CollectionSearcher {
  public func search(
    _ str: String, from: String.Index, _ state: inout ()
  ) -> Range<String.Index>? {
    CharacterSearcher(self).search(str, from: from, &state)
  }
}





