import Prototype_CollectionConsumerSearcher

import Foundation

func p<T: CustomStringConvertible>(converting s: T, line: Int = #line) {
  print("\(line): \(s)")
}
func p<T: Collection>(_ s: T, line: Int = #line) where T.Element == Character {
  let escaped = String(s).unicodeScalars.map {
    $0.escaped(asASCII: true)
  }

  p(converting: escaped.joined(), line: line)
}


p("  \n\tThe quick brown fox\n".trim { $0.isWhitespace })
// "The quick brown fox"

p(converting: [1,2,3,2,1,5,5,9,0,9,0,9,0,9].matches(PalindromeFinder()).map { $0.count })
// [5, 2, 7]

let number = try! NSRegularExpression(pattern: "[-+]?[0-9]*\\.?[0-9]+")
var str = "12.34,5,.6789\n10,-1.1"

p(converting: str.split(number))
// [",", ",", "\n", ","]

p(str.matches(number).joined(separator: " "))
// "12.34 5 .6789 10 -1.1"

str.replaceAll(number) { "\(Double($0)!.rounded())" }
p(str)
// str == "12.0,5.0,1.0\n10.0,-1.0"


