import XCTest
@testable import Prototype_CollectionConsumerSearcher

extension Collection {
  func offsetOf(_ i: Index) -> Int {
    return distance(from: startIndex, to: i)
  }
  func offsetOf(_ r: Range<Index>) -> (Int, Int) {
    return (offsetOf(r.lowerBound), offsetOf(r.upperBound))
  }
}

final class PalindromeTests: XCTestCase {

  static let testCases: [(String, [String])] = [
    ("aba", ["aba"]),
//    ("abaa", ["aba", "aa"]),
//    ("abba", ["abba"]),
//    ("abbba", ["bb", "abbba", "bb"]),
//    ("abcccba", ["cc", "abcccba", "cc"]),
//    ("abaabaabacdc", ["aba", "abaaba", "abaabaaba", "abaaba", "aba", "cdc"]),
//    ("abcdddeeefffeeedddcba", [
//      "dd", "ddd", "dd", "ee", "eee", "ee", "ff", "abcdddeeefffeeedddcba",
//      "ff", "ee", "eee", "ee", "dd", "ddd", "dd"]),
//    ("aaa", ["aa", "aaa", "aa"])
  ]

  func test_leftMostLongest() {
    let cases: [(String, [String])] = [
      ("aba", ["aba", "", "a"]),
      ("aaa", ["aaa", "aa", "a"]),
      ("abaa", ["aba", "", "aa", "a"]),
      ("abba", ["abba", "b", "b", "a"]),
      ("abbba", ["abbba", "bb", "bb", "b", "a"]),
      ("abcccba", ["abcccba", "b", "cc", "cc", "c", "b", "a"]),
      ("abaXcdcYzz", ["aba", "", "a", "X", "cdc", "", "c", "Y", "zz", "z"]),
    ]

    for (input, expected) in cases {
      let longest = PalindromeFinder.leftMostLongest(input).map { String(input[$0]) }
      expectEqualSequence(expected, longest)
    }
  }

  func test_palindromes() {
    let cases: [(String, [String])] = [
      ("aba", ["aba"]),
      ("abac", ["aba", "c"]),
      ("abaXcdcYzz", ["aba", "X", "cdc", "Y", "zz"]),
    ]

    for (input, expected) in cases {
      let palindromes = Palindromes(input)
      expectEqualSequence(expected, palindromes.map { String($0) })
      expectEqualSequence(palindromes, PalindromesFromConsumer(input))
    }
  }

  func test_search() {
    let cases: [(String, [String])] = [
      ("aba", ["ab"]),
      ("abac", ["ab", "c"]),
      ("abaXcdcYzzZZZZ", ["ab", "X", "cd", "Y", "z", "ZZ"]),
    ]

    for (input, expected) in cases {
      var str = input
      str.replaceAll(PalindromeFinder()) { (_ s: Substring) -> Substring in
        assert(!s.isEmpty)
        var (start, end) = (s.startIndex, s.endIndex)
        while true {
          let next = s.index(after: start)
          if next >= end { return s[..<end] }
          (start, end) = (next, s.index(before: end))
        }
      }
      expectEqualSequence(expected.joined(), str)
    }
  }

  func test_reversed() {
    // TODO: test
  }

  func test_matcher() {
    // TODO: test
  }
}

final class CharacterSetTests: XCTestCase {
  func test_trim() {
    var input = """

       some content

    """
    input.stripFront(CharacterSet.whitespaces)
    expectEqualSequence("\n   some", input.prefix(8))
    input.stripFront(CharacterSet.whitespacesAndNewlines)
    expectEqualSequence("some", input.prefix(4))
    input.stripFront(CharacterSet.letters)
    expectEqualSequence(" content", input.prefix(8))
    input.stripFront(CharacterSet.whitespaces)
    expectEqualSequence("content", input.prefix(7))
    input.stripFront(CharacterSet.letters)
    expectEqualSequence("\n", input)
    input.stripFront(CharacterSet.whitespacesAndNewlines)
    expectTrue(input.isEmpty)
  }
}

final class NSRegularExpressionTests: XCTestCase {
  func test_trim() {
    let input = """

       some content

    """

    let trimWhitespace = try! NSRegularExpression(pattern: #"\p{whitespace}*"#)
    func trimFront(_ s: String) -> String {
      return String(s.unicodeScalars.drop(while: { $0.properties.isWhitespace }))
    }
    func trimBack(_ s: String) -> String {
      return String(
        decoding: s.unicodeScalars.reversed().drop(
          while: { $0.properties.isWhitespace }
        ).reversed().map { $0.value },
        as: UTF32.self)
    }
    func trimBoth(_ s: String) -> String {
      return trimFront(trimBack(s))
    }

    expectEqualSequence(trimFront(input), input.trimFront(trimWhitespace))

    // NSRegularExpression isn't naturally bidi, it requires processing the entire string to match.
    expectEqualSequence(trimBack(input), input.trimBack { $0.isWhitespace } )
    expectEqualSequence(trimBoth(input), input.trim { $0.isWhitespace } )

    expectEqualSequence(input, input.trimFront(try! NSRegularExpression(pattern: #"a"#)))
  }

  func test_search() {
    let str = """
      abc def
       ghi  jkl  123 🧟‍♀️ \t yz
      """
    let nonWhitespace = try! NSRegularExpression(pattern: #"\P{whitespace}+"#)
    let whitespace = try! NSRegularExpression(pattern: #"\p{whitespace}+"#)

    var repl = str
    repl.replaceAll(nonWhitespace) { return $0.uppercased() }
    expectEqualSequence(str.uppercased(), repl)

    expectEqualSequence(
      ["abc", "def", "ghi", "jkl", "123", "🧟‍♀️", "yz"], str.matches(nonWhitespace).map { $0 })

    expectEqualSequence(
      ["abc", "def", "ghi", "jkl", "123", "🧟‍♀️", "yz"], str.split(whitespace))
    expectEqualSequence(
      [" ", "\n ", "  ", "  ", " ", " \t "], str.split(nonWhitespace))
  }
}

import PatternKitRegex
import PatternKitCore
import PatternKitBundle
final class TestPatternKit: XCTestCase {
  func test_pattern() {
    let input = "catdogdogdogcatdogcat"
    let pattern = ("cat" as Literal<Substring>) | ("dog" as Literal<Substring>)

    var str = input[...]
    expectEqualSequence(["cat", "dog", "dog", "dog", "cat", "dog", "cat"], str.eatAll(pattern))
  }
}

