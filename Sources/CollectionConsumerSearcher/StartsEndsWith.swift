//
// MARK: - Starts / Ends With
//

extension Collection {
  public func starts<CC: CollectionConsumer>(
    with cc: CC
  ) -> Bool where CC.C == Self {
    return cc.consume(self) != nil
  }
}
extension BidirectionalCollection {
  public func ends<CC: BidirectionalCollectionConsumer>(
    with cc: CC
  ) -> Bool where CC.C == Self {
    return cc.consumeBack(self) != nil
  }
}

