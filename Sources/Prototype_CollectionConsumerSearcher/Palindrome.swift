import CollectionConsumerSearcher

/// Find palindromes of length >= 2
///
/// This will present palindromes in sequential order of their centers. Note that this means that a sequentially-later palindrome may
/// span the entirety of an earlier palindrome, as in the below example.
///
/// Example:
///   "abcccba" => "cc", "abcccba", "cc"
///
public struct PalindromeFinder<C: BidirectionalCollection> where C.Element: Equatable {
  public typealias Element = C.Element
  public init() {
  }
}

extension PalindromeFinder {
  static internal func maximalPalindromes<C2: Collection>(
    _ ranges: C2
  ) -> Array<Range<C.Index>> where C2.Element == Range<C.Index> {
    // Prune over-lapped entries
    var result = Array<Range<C.Index>>()
    var ranges = ranges[...]
    while let range = ranges.eat() {
      result.append(range)

      // Skip all subsequent sub-palindromes
      ranges.eat(while: { range.upperBound > $0.lowerBound })
    }
    return result
  }

  static internal func findMaximalPalindrome(
    _ c: C, centeredAt center: C.Index, isPrior: Bool
  ) -> (Range<C.Index>, offsetFromCenter: Int) {
    var (lower, upper) = (center, center)
    var leftOffset = 0

    func returnRange<RE: RangeExpression>(
      _ r: RE
    ) -> (Range<C.Index>, Int) where RE.Bound == C.Index {
      return (r.relative(to: c), leftOffset)
    }

    let last = c.index(before: c.endIndex)

    if isPrior {
      if lower == c.startIndex { return returnRange(center ..< center) }
      c.formIndex(before: &lower)
      guard c[lower] == c[upper] else { return returnRange(center ..< center) }
      leftOffset += 1
    }

    while lower > c.startIndex, upper < last {
      assert(c[lower] == c[upper])
      let (prior, latter) = (c.index(before: lower), c.index(after: upper))
      guard c[prior] == c[latter] else { break }
      (lower, upper) = (prior, latter)
      leftOffset += 1
    }

    return returnRange(lower ... upper)
  }

  static internal func leftMostLongest(_ c: C) -> [Range<C.Index>] {
    let empty = c.startIndex ..< c.startIndex
    var result = [Range<C.Index>](repeating: empty, count: c.count)

    // Visit each of the 2*n - 1 palindrome centers, finding the maximal length palindrome at that
    // center. Store the longest one found, keyed off the left-most bound.
    withMaximalPalindromes(c, startingFrom: c.startIndex) { (range, offset) in
      if result[offset].upperBound < range.upperBound {
        result[offset] = range
      }
      return true
    }

    return result
  }

  ///
  /// * `f`: Takes the palindrome range and the relative offset of the lowerbound from `startingFrom`. Return value
  ///       of `true` means keep going, `false` means stop.
  static internal func withMaximalPalindromes(
    _ c: C,
    startingFrom idx: C.Index,
    _ f: (_: Range<C.Index>, _ leftRelativeOffsetFromIdx: Int) throws -> Bool
  ) rethrows {
    var center = idx
    var centerPosition = 0
    while center < c.endIndex {
      let (range, offset) = findMaximalPalindrome(c, centeredAt: center, isPrior: false)
      guard try f(range, centerPosition - offset) else { return }

      c.formIndex(after: &center)
      centerPosition += 1
      if center < c.endIndex {
        let (range, offset) = findMaximalPalindrome(c, centeredAt: center, isPrior: true)
        guard try f(range, centerPosition - offset) else { return }
      }
    }
  }

  static internal func isPalindrome(_ slice: C.SubSequence) -> Bool {
    // TODO: Do half as much work
    return slice.elementsEqual(slice.reversed())
  }
}

struct Palindromes<C: BidirectionalCollection>: Sequence, IteratorProtocol
  where C.Element: Equatable
{
  let base: C
  var ranges: ArraySlice<Range<C.Index>>

  init(_ base: C) {
    self.base = base
    self.ranges = PalindromeFinder<C>.maximalPalindromes(PalindromeFinder.leftMostLongest(base))[...]
  }

  mutating func next() -> C.SubSequence? {
    guard let range = ranges.eat() else { return nil }
    return base[range]
  }
}

extension PalindromeFinder: CollectionConsumer {
  public func consume(_ c: C, from: C.Index) -> C.Index? {
    guard from < c.endIndex else { return nil }
    var result = c.startIndex

    // Loop over every center, remembering the longest prefix palindrome
    Self.withMaximalPalindromes(c, startingFrom: from) { (range, _) in
      if range.lowerBound == from {
        result = Swift.max(result, range.upperBound)
        assert(result != c.startIndex)
      }
      return true
    }

    return result
  }
}

struct PalindromesFromConsumer<C: BidirectionalCollection>: Sequence, IteratorProtocol
  where C.Element: Equatable
{
  var slice: C.SubSequence

  init(_ base: C) {
    self.slice = base[...]
  }

  mutating func next() -> C.SubSequence? {
    guard !slice.isEmpty else { return nil }
    return slice.eat(PalindromeFinder<C.SubSequence>())
  }
}


extension PalindromeFinder: BidirectionalCollectionConsumer {
  public func consumeBack(
    _ c: C, endingAt: C.Index
  ) -> C.Index? {
    let revFinder = PalindromeFinder<ReversedCollection<C>>()
    let revIdx = revFinder.consume(c.reversed(), from: ReversedCollection.Index(endingAt))
    return revIdx?.base
  }
}

extension PalindromeFinder: CollectionSearcher {
  public func search(_ c: C, from: C.Index, _: inout ()) -> Range<C.Index>? {
    guard let upper = consume(c, from: from) else { return nil }
    return from ..< upper
  }
}

extension PalindromeFinder: BidirectionalCollectionSearcher {
  public func searchBack(
    _ c: C, endingAt: C.Index, _: inout ()
  ) -> Range<C.Index>? {
    let revFinder = PalindromeFinder<ReversedCollection<C>>()
    var state: () = ()
    guard let revRange = revFinder.search(c.reversed(), from: ReversedCollection.Index(endingAt), &state)
    else { return nil }

    return revRange.lowerBound.base ..< revRange.upperBound.base
  }
}

//extension PalindromeFinder: CollectionMatcher {
//  typealias Output = C.SubSequence
//
//  func validate(
//    _ c: C, _ range: Range<C.Index>
//  ) -> Output? {
//    let slice = c[range]
//    guard Self.isPalindrome(slice) else { return nil }
//    return slice
//  }
//}

