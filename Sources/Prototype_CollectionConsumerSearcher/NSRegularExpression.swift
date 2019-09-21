import Foundation
import CollectionConsumerSearcher

extension NSRegularExpression: CollectionConsumer {
  internal func findFirst(
    _ str: String, _ range: Range<String.Index>, anchored: Bool
  ) -> Range<String.Index>? {
    let nsRange = NSRange(range, in: str)
    let options: NSRegularExpression.MatchingOptions = anchored ? [.anchored] : []
    let resultNSRange = self.rangeOfFirstMatch(in: str, options: options, range: nsRange)
    return Range<String.Index>(resultNSRange, in: str)
  }

  public typealias C = String

  public func consume(_ str: String, from: String.Index) -> String.Index? {
    return findFirst(str, from ..< str.endIndex, anchored: true)?.upperBound
  }
}

extension NSRegularExpression: CollectionSearcher {
  public func search(_ str: String, from: String.Index, _: inout State) -> Range<String.Index>? {
    return findFirst(str, from ..< str.endIndex, anchored: false)
  }
}
