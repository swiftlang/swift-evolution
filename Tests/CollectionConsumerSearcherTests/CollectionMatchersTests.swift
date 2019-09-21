import XCTest
@testable import CollectionConsumerSearcher

final class CollectionMatchersTests: XCTestCase {
  struct LetterGlobber: BidirectionalCollectionConsumer, BidirectionalCollectionSearcher {
    func consumeBack(_ str: String, endingAt: String.Index) -> String.Index? {
      guard let range = self.searchBack(str, endingAt: endingAt), range.upperBound == str.endIndex
      else { return nil }

      return range.lowerBound
    }

    func consume(_ str: String, from: String.Index) -> String.Index? {
      guard let range = self.search(str, from: from), range.lowerBound == str.startIndex
      else { return nil }

      return range.upperBound
    }

    typealias C = String

    func search(_ str: String, from: String.Index, _: inout ()) -> Range<String.Index>? {
      guard let lowerbound = str[from...].firstIndex(where: { $0.isLetter }) else { return nil }
      let upperbound = str[lowerbound...].firstIndex { !$0.isLetter } ?? str.endIndex
      return lowerbound ..< upperbound
    }
    func searchBack(_ str: String, endingAt: String.Index, _: inout ()) -> Range<String.Index>? {
      guard let closedUpperbound = str[..<endingAt].lastIndex(where: { $0.isLetter }) else {
        return nil
      }
      guard let beforeLowerbound = str[..<closedUpperbound].lastIndex(where: { !$0.isLetter }) else {
        return (str.startIndex ... closedUpperbound).relative(to: str)
      }
      return (str.index(after: beforeLowerbound) ... closedUpperbound).relative(to: str)
    }
  }

  func test_trimStripOverloads() {
    let whitespaceStr = "  ABCDEFG  "
    func testWhitespace(
      trimFront: @autoclosure () -> Substring,
      trimBack: @autoclosure () -> Substring,
      trimBoth: @autoclosure () -> Substring,
      stripFront: (inout String) -> (),
      stripBack: (inout String) -> (),
      stripBoth: (inout String) -> ()
    ) {

      expectEqualSequence("ABCDEFG  ", trimFront())
      expectEqualSequence("  ABCDEFG", trimBack())
      expectEqualSequence("ABCDEFG", trimBoth())

      var str = whitespaceStr
      stripFront(&str)
      expectEqualSequence(trimFront(), str)

      str = whitespaceStr
      stripBack(&str)
      expectEqualSequence(trimBack(), str)

      str = whitespaceStr
      stripBoth(&str)
      expectEqualSequence(trimBoth(), str)
    }

    let spFun: (Character) -> Bool = { $0.isWhitespace }
    testWhitespace(
      trimFront: whitespaceStr.trimFront(spFun),
      trimBack: whitespaceStr.trimBack(spFun),
      trimBoth: whitespaceStr.trim(spFun),
      stripFront: { $0.stripFront(spFun) },
      stripBack: { $0.stripBack(spFun) },
      stripBoth: { $0.strip(spFun) })
    let spChar: Character = " "
    testWhitespace(
      trimFront: whitespaceStr.trimFront(spChar),
      trimBack: whitespaceStr.trimBack(spChar),
      trimBoth: whitespaceStr.trim(spChar),
      stripFront: { $0.stripFront(spChar) },
      stripBack: { $0.stripBack(spChar) },
      stripBoth: { $0.strip(spChar) })
    let spSet: Set<Character> = [" ", "\n", "\r", "\r\n", "\t"]
    testWhitespace(
      trimFront: whitespaceStr.trimFront(in: spSet),
      trimBack: whitespaceStr.trimBack(in: spSet),
      trimBoth: whitespaceStr.trim(in: spSet),
      stripFront: { $0.stripFront(in: spSet) },
      stripBack: { $0.stripBack(in: spSet) },
      stripBoth: { $0.strip(in: spSet) })
    let spSeq = "  "
    testWhitespace(
      trimFront: whitespaceStr.trimFront(exactly: spSeq),
      trimBack: whitespaceStr.trimBack(exactly: spSeq),
      trimBoth: whitespaceStr.trim(exactly: spSeq),
      stripFront: { $0.stripFront(exactly: spSeq) },
      stripBack: { $0.stripBack(exactly: spSeq) },
      stripBoth: { $0.strip(exactly: spSeq) })

    expectEqualSequence(" ABCDEFG  ", whitespaceStr.trimFront(exactly: " "))
    expectEqualSequence("  ABCDEFG ", whitespaceStr.trimBack(exactly: " "))
    expectEqualSequence(" ABCDEFG ", whitespaceStr.trim(exactly: " "))
  }

  func test_eatOverloads() {
    let string = "the quick \nfox   jumped  \t over the lazy brown  \n dog"
    var str = string[...]

    let spFun: (Character) -> Bool = { $0.isWhitespace }
    expectEqualSequence("the", str.eat(untilFirst: spFun))
    expectEqualSequence(" quick \n", str.eat(throughFirst: "\n"))
    expectEqualSequence("fox", str.eat(exactly: "fox"))
    expectEqual(" ", str.eat(one: " "))
    expectNil(str.eat(one: "x"))
    expectEqualSequence("  ", str.eat(many: " "))
    expectNil(str.eat(oneIn: ["h", "i", "k"]))
    expectEqualSequence("ju", str.eat(whileIn: ["h", "i", "j", "k", "u"]))

    expectEqualSequence("mped  ", str.eat(untilFirst: "\t "))
    expectEqualSequence("\t over the lazy brown", str.eat(throughFirst: "brown"))
    expectEqualSequence("  ", str.eat(count: 2))
    expectEqualSequence("\n ", str.eat(while: spFun))
    expectEqualSequence("dog", str)
  }

  func test_searchAPI() {
    let string = "%the quick    fox 123 jumped over_ the lazy \nbrown dog1gie"

    expectEqualSequence(
      ["THE", "QUICK", "FOX", "JUMPED", "OVER", "THE", "LAZY", "BROWN", "DOG", "GIE"],
      string.matches(LetterGlobber()).map { $0.uppercased() })
    expectEqualSequence(
      ["the", "quick", "fox", "jumped", "over", "the", "lazy", "brown", "dog", "gie"],
      string.matches(LetterGlobber()))

    var replStr = string
    replStr.replaceFirst(LetterGlobber(), with: "teh")
    replStr.replaceLast(LetterGlobber(), with: "")
    replStr.replaceLast(LetterGlobber(), with: "doggie")
    expectEqualSequence(
      ["teh", "quick", "fox", "jumped", "over", "the", "lazy", "brown", "doggie"],
      replStr.matches(LetterGlobber()).map { $0 })

    replStr.replaceAll(LetterGlobber()) { $0.uppercased() }
    expectEqual("%TEH QUICK    FOX 123 JUMPED OVER_ THE LAZY \nBROWN DOGGIE1", replStr)

  }

  func test_startsEndsWith() {
    let strStart = "the quick "
    let strEnd = " brown fox"
    let strBoth = strStart + strEnd

    expectTrue(strStart.starts(with: LetterGlobber()))
    expectFalse(strEnd.starts(with: LetterGlobber()))
    expectTrue(strBoth.starts(with: LetterGlobber()))

    expectFalse(strStart.ends(with: LetterGlobber()))
    expectTrue(strEnd.ends(with: LetterGlobber()))
    expectTrue(strBoth.ends(with: LetterGlobber()))

  }

  func test_splitAPI() {

    // Just to test a couple corner cases

    expectEqual([], "".split(separator: "_"))
    expectEqual([], "".split(separator: "_", maxSplits: 0))
    expectEqual([""], "".split(separator: "_", maxSplits: 0, omittingEmptySubsequences: false))

    expectEqual([], "_".split(separator: "_"))
    expectEqual(["_"], "_".split(separator: "_", maxSplits: 0))
    expectEqual(["_"], "_".split(separator: "_", maxSplits: 0, omittingEmptySubsequences: false))

    expectEqual([], "_".split(separator: "_"))
    expectEqual(["", ""], "_".split(separator: "_", omittingEmptySubsequences: false))

    expectEqual(["a"], "_a_".split(separator: "_"))
    expectEqual(["a"], "_a_".split(separator: "_", maxSplits: 1))
    expectEqual(["", "a_"], "_a_".split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false))
    expectEqual(["", "a", ""], "_a_".split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false))
    expectEqual(["", "a", ""], "_a_".split(separator: "_", omittingEmptySubsequences: false))

    expectEqual([], "__".split(separator: "_"))
    expectEqual(["", "_"], "__".split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false))
    expectEqual(["", "", ""], "__".split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false))
    expectEqual(["", "", ""], "__".split(separator: "_", omittingEmptySubsequences: false))

    expectEqual([], "".split(anyOf: ["_"]))
    expectEqual([], "".split(anyOf: ["_"], maxSplits: 0))
    expectEqual([""], "".split(anyOf: ["_"], maxSplits: 0, omittingEmptySubsequences: false))

    expectEqual([], "_".split(anyOf: ["_"]))
    expectEqual(["_"], "_".split(anyOf: ["_"], maxSplits: 0))
    expectEqual(["_"], "_".split(anyOf: ["_"], maxSplits: 0, omittingEmptySubsequences: false))

    expectEqual([], "_".split(anyOf: ["_"]))
    expectEqual(["", ""], "_".split(anyOf: ["_"], omittingEmptySubsequences: false))

    expectEqual(["a"], "_a_".split(anyOf: ["_"]))
    expectEqual(["a"], "_a_".split(anyOf: ["_"], maxSplits: 1))
    expectEqual(["", "a_"], "_a_".split(anyOf: ["_"], maxSplits: 1, omittingEmptySubsequences: false))
    expectEqual(["", "a", ""], "_a_".split(anyOf: ["_"], maxSplits: 2, omittingEmptySubsequences: false))
    expectEqual(["", "a", ""], "_a_".split(anyOf: ["_"], omittingEmptySubsequences: false))

    expectEqual([], "__".split(anyOf: ["_"]))
    expectEqual(["", "_"], "__".split(anyOf: ["_"], maxSplits: 1, omittingEmptySubsequences: false))
    expectEqual(["", "", ""], "__".split(anyOf: ["_"], maxSplits: 2, omittingEmptySubsequences: false))
    expectEqual(["", "", ""], "__".split(anyOf: ["_"], omittingEmptySubsequences: false))

    let string = "the quick \nfox   jumped  \t over the lazy brown  \n dog"
    expectEqualSequence(
      ["the", "quick", "fox", "jumped", "over", "the", "lazy", "brown", "dog"],
      string.split(anyOf: [" ", "\n", "\t"])
    )

  }

}

