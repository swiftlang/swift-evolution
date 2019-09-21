import Foundation
import CollectionConsumerSearcher

extension Scanner: CollectionConsumer {
  public typealias C = String

  public func consume(_ str: String, from: String.Index) -> String.Index? {
    return self.charactersToBeSkipped?.consume(str, from: from)
  }
}

extension Scanner: CollectionSearcher {
  public func search(
    _ str: String, from: String.Index, _ state: inout ()
  ) -> Range<String.Index>? {
    self.charactersToBeSkipped?.search(str, from: from, &state)
  }
}
