import CollectionConsumerSearcher
import PatternKitCore
import PatternKitBundle

extension PatternKitCore.Pattern {
  public typealias C = Subject

  public func consume(_ collection: C, from: C.Index) -> C.Index? {
    let start = Match(over: collection, inputPosition: from)
    return self.forwardMatches(enteringFrom: start).first?.inputPosition
  }
}
extension Concatenation: CollectionConsumer {}
extension Alternation: CollectionConsumer {}

