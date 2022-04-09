# Regex Type and Overview

* Proposal: [SE-0350](0350-regex-type-overview.md)
* Authors: [Michael Ilseman](https://github.com/milseman)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Active Review (4 - 15 April 2022)**
* Implementation: https://github.com/apple/swift-experimental-string-processing
  * Available in nightly toolchain snapshots with `import _StringProcessing`

## Introduction

Swift strings provide an obsessively Unicode-forward model of programming with strings. String processing with `Collection`'s algorithms is woefully inadequate for many day-to-day tasks compared to other popular programming and scripting languages.

We propose addressing this basic shortcoming through an effort we are calling regex. What we propose is more powerful, extensible, and maintainable than what is traditionally thought of as regular expressions from other programming languages. This effort is presented as 6 interrelated proposals:

1. `Regex<Output>` and `Regex<Output>.Match` types with support for typed captures, both static and dynamic.
2. A best-in-class treatment of traditional, familiar regular expression syntax for run-time construction of regex.
3. A literal for compile-time construction of a regex with statically-typed captures, enabling powerful source tools.
4. An expressive and composable result-builder DSL, with support for capturing strongly-typed values.
5. A modern treatment of Unicode semantics and string processing.
6. A slew of regex-powered string processing algorithms, along with library-extensible protocols enabling industrial-strength parsers to be used seamlessly as regex components.

This proposal provides details on \#1, the `Regex` type and captures, and gives an overview of how each of the other proposals fit into regex in Swift.

At the time of writing, these related proposals are in various states of being drafted, pitched, or proposed. For the current status, see [Pitch and Proposal Status][pitches].

<details><summary>Obligatory differentiation from formal regular expressions</summary>

Regular expressions originated in formal language theory as a way to answer yes-or-no whether a string is in a given [regular language](https://en.wikipedia.org/wiki/Regular_language). They are more powerful (and less composable) than [star-free languages](https://en.wikipedia.org/wiki/Star-free_language) and less powerful than [context-free languages](https://en.wikipedia.org/wiki/Context-free_language). Because they just answer a yes-or-no question, _how_ that answer is determined is irrelevant; i.e. their execution model is ambiguous.

Regular expressions were brought into practical applications for text processing and compiler lexers. For searching within text, where the result (including captures) is a portion of the searched text, _how_ a match happened affects the result. Over time, more and more power was needed and "regular expressions" diverged from their formal roots.

For compiler lexers, especially when implemented as a [discrete compilation phase](https://en.wikipedia.org/wiki/Lexical_analysis), regular expressions were often ingested by a [separate tool](https://en.wikipedia.org/wiki/Flex_(lexical_analyser_generator)) from the rest of the compiler. Understanding formal regular expressions can help clarify the separation of concerns between lexical analysis and parsing. Beyond that, they are less relevant for structuring modern parsers, which interweave error handling and recovery, debuggability, and fine-grained source location tracking across this traditional separation-of-tools.

The closest formal analogue to what we are proposing are [Parsing Expression Grammars](https://en.wikipedia.org/wiki/Parsing_expression_grammar) ("PEGs"), which describe a recursive descent parser. Our alternation is ordered choice and we support possessive quantification, recursive subpattern calls, and lookahead. However, we are first and foremost providing a regexy presentation: quantification, by default, is non-possessive.

</details>


## Motivation

Imagine processing a bank statement in order to extract transaction details for further scrutiny. Fields are separated by 2-or-more spaces:

```swift
struct Transaction {
  enum Kind { case credit; case debit }

  let kind: Kind
  let date: Date
  let accountName: String
  let amount: Decimal
}

let statement = """
  CREDIT    03/02/2022    Payroll                   $200.23
  CREDIT    03/03/2022    Sanctioned Individual A   $2,000,000.00
  DEBIT     03/03/2022    Totally Legit Shell Corp  $2,000,000.00
  DEBIT     03/05/2022    Beanie Babies Forever     $57.33
  """
```

One option is to `split()` around whitespace, hard-coding field offsets for everything except the account name, and `join()`ing the account name fields together to restore their spaces. This carries a lot of downsides such as hard-coded offsets, many unnecessary allocations, and this pattern would not easily expand to supporting other representations.

Another option is to process an entry in a single pass from left-to-right, but this can get unwieldy:

```swift
// Parse dates using a simple (localized) numeric strategy
let dateParser = Date.FormatStyle(date: .numeric).parseStrategy

// Parse currencies as US dollars
let decimalParser = Decimal.FormatStyle.Currency(code: "USD")

func processEntry(_ s: String) -> Transaction? {
  var slice = s[...]
  guard let kindEndIdx = slice.firstIndex(of: " "),
        let kind = Transaction.Kind(slice[..<kindEndIdx])
  else {
    return nil
  }

  slice = slice[kindEndIdx...].drop(while: \.isWhitespace)
  guard let dateEndIdx = slice.firstIndex(of: " "),
        let date = try? Date(
          String(slice[..<dateEndIdx]), strategy: dateParser)
  else {
    return nil
  }
  slice = slice[dateEndIdx...].drop(while: \.isWhitespace)

  // Account can have spaces, look for 2-or-more for end-of-field
  // ...
  // You know what, let's just bail and call it a day
  return nil
}
```

Foundation provides [NSRegularExpression](https://developer.apple.com/documentation/foundation/nsregularexpression), an API around [ICU's regular expression engine](https://unicode-org.github.io/icu/userguide/strings/regexp.html). An `NSRegularExpression` is constructed at run time from a string containing regex syntax. Run-time construction is very useful for tools, such as SwiftPM's `swift test --filter` and search fields inside text editors.

```swift
let pattern = #"(\w+)\s\s+(\S+)\s\s+((?:(?!\s\s).)*)\s\s+(.*)"#
let nsRegEx = try! NSRegularExpression(pattern: pattern)

func processEntry(_ line: String) -> Transaction? {
  let range = NSRange(line.startIndex..<line.endIndex, in: line)
  guard let result = nsRegEx.firstMatch(in: line, range: range),
        let kindRange = Range(result.range(at: 1), in: line),
        let kind = Transaction.Kind(line[kindRange]),
        let dateRange = Range(result.range(at: 2), in: line),
        let date = try? Date(String(line[dateRange]), strategy: dateParser),
        let accountRange = Range(result.range(at: 3), in: line),
        let amountRange = Range(result.range(at: 4), in: line),
        let amount = try? Decimal(
          String(line[amountRange]), format: decimalParser)
  else {
    return nil
  }

  return Transaction(
    kind: kind, date: date, account: String(line[accountRange]), amount: amount)
}
```

The pattern is represented as a string literal, missing out on better source tooling. For example, the pattern describes an algorithm and would benefit from syntax highlighting more akin to code than uniform data. We also miss the opportunity to represent the number and kinds of captures in the type system: the programmer must remember to check for `NSNotFound` or make sure that whatever the capture is passed to does.

Traditional regular expression engines and tooling present an all-in or all-out world, making them impervious to refactoring or sharing common sub-components. This also encourages programmers to use regular expressions to parse things they shouldn't, such as dates, times, numbers, and currencies. In the code above, an overly-permissive parser is used and validation and interpretation is left as a post-processing phase, increasing complexity and maintenance burden.

Fundamentally, ICU's regular expression engine operates over a different model of string than Swift's model. The results may split grapheme clusters apart (potentially introducing [degenerate grapheme clusters](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries)), ICU does not support comparing under canonical equivalence, etc. This means that using `NSRegularExpression` will often produce different results than the equivalent algorithm ran over `String`.

Finally, `NSRegularExpression`, due to both compatibility reasons and needing to use ICU, incurs bridging overhead and is unable to take advantage of Swift's native string representations.


## Proposed solution

A `Regex<Output>` describes a string processing algorithm. Captures surface the portions of the input that were matched by subpatterns. By convention, capture `0` is the entire match.

### Creating Regex

Regexes can be created at run time from a string containing familiar regex syntax. If no output type signature is specified, the regex has type `Regex<AnyRegexOutput>`, in which captures are existentials and the number of captures is queryable at run time. Alternatively, providing an output type signature produces strongly-typed outputs, where captures are concrete types embedded in a tuple, providing safety and enabling source tools such as code completion.

```swift
let pattern = #"(\w+)\s\s+(\S+)\s\s+((?:(?!\s\s).)*)\s\s+(.*)"#
let regex = try! Regex(compiling: pattern)
// regex: Regex<AnyRegexOutput>

let regex: Regex<(Substring, Substring, Substring, Substring, Substring)> =
  try! Regex(compiling: pattern)
```

*Note*: The syntax accepted and further details on run-time compilation, including `AnyRegexOutput` and extended syntaxes, are discussed in [Run-time Regex Construction][pitches].

Type mismatches and invalid regex syntax are diagnosed at construction time by `throw`ing errors.

When the pattern is known at compile time, regexes can be created from a literal containing the same regex syntax, allowing the compiler to infer the output type. Regex literals enable source tools, e.g. syntax highlighting and actions to refactor into a result builder equivalent.

```swift
let regex = /(\w+)\s\s+(\S+)\s\s+((?:(?!\s\s).)*)\s\s+(.*)/
// regex: Regex<(Substring, Substring, Substring, Substring, Substring)>
```

*Note*: Regex literals, most notably the choice of delimiter, are discussed in [Regex Literals][pitches].

This same regex can be created from a result builder, a refactoring-friendly representation:

```swift
let fieldSeparator = Regex {
  CharacterClass.whitespace
  OneOrMore(.whitespace)
}

let regex = Regex {
  Capture(OneOrMore(.word))
  fieldSeparator

  Capture(OneOrMore(.whitespace.inverted))
  fieldSeparator

  Capture {
    OneOrMore {
      NegativeLookahead(fieldSeparator)
      CharacterClass.any
    }
  }
  fieldSeparator

  Capture { OneOrMore(.any) }
}
// regex: Regex<(Substring, Substring, Substring, Substring, Substring)>
```

*Note*: The result builder API is discussed in [Regex Builders][pitches]. Character classes and other Unicode concerns are discussed in [Unicode for String Processing][pitches].

`Regex` itself is a valid component for use inside a result builder, meaning that embedded literals can be used for concision.

### Using Regex

A `Regex<Output>.Match` contains the result of a match, surfacing captures by number, name, and reference.

```swift
func processEntry(_ line: String) -> Transaction? {
  // Multiline literal implies `(?x)`, i.e. non-semantic whitespace with line-ending comments
  let regex = #/
    (?<kind>    \w+)                \s\s+
    (?<date>    \S+)                \s\s+
    (?<account> (?: (?!\s\s) . )+)  \s\s+
    (?<amount>  .*)
  /#
  //  regex: Regex<(
  //    Substring,
  //    kind: Substring,
  //    date: Substring,
  //    account: Substring,
  //    amount: Substring
  //  )>

  guard let match = regex.matchWhole(line),
        let kind = Transaction.Kind(match.kind),
        let date = try? Date(String(match.date), strategy: dateParser),
        let amount = try? Decimal(String(match.amount), format: decimalParser)
  else {
    return nil
  }

  return Transaction(
    kind: kind, date: date, account: String(match.account), amount: amount)
}
```

*Note*: Details on typed captures using tuple labels are covered in [Regex Literals][pitches].

The result builder allows for inline failable value construction, which participates in the overall string processing algorithm: returning `nil` signals a local failure and the engine backtracks to try an alternative. This not only relieves the use site from post-processing, it enables new kinds of processing algorithms, allows for search-space pruning, and enhances debuggability.

Swift regexes describe an unambiguous algorithm, where choice is ordered and effects can be reliably observed. For example, a `print()` statement inside the `TryCapture`'s transform function will run whenever the overall algorithm naturally dictates an attempt should be made. Optimizations can only elide such calls if they can prove it is behavior-preserving (e.g. "pure").

`CustomMatchingRegexComponent`, discussed in [String Processing Algorithms][pitches], allows industrial-strength parsers to be used a regex components. This allows us to drop the overly-permissive pre-parsing step:

```swift
func processEntry(_ line: String) -> Transaction? {
  let fieldSeparator = Regex {
    CharacterClass.whitespace
    OneOrMore(.whitespace)
  }

  // Declare strongly-typed references to store captured values into
  let kind = Reference<Transaction.Kind>()
  let date = Reference<Date>()
  let account = Reference<Substring>()
  let amount = Reference<Decimal>()

  let regex = Regex {
    TryCapture(as: kind) {
      OneOrMore(.word)
    } transform: {
      Transaction.Kind($0)
    }
    fieldSeparator

    TryCapture(as: date) { dateParser }
    fieldSeparator

    Capture(as: account) {
      OneOrMore {
        NegativeLookahead(fieldSeparator)
        CharacterClass.any
      }
    }
    fieldSeparator

    TryCapture(as: amount) { decimalParser }
  }
  // regex: Regex<(Substring, Transaction.Kind, Date, Substring, Decimal)>

  guard let match = regex.matchWhole(line) else { return nil }

  return Transaction(
    kind: match[kind],
    date: match[date],
    account: String(match[account]),
    amount: match[amount])
}
```

*Note*: Details on how references work is discussed in [Regex Builders][pitches]. `Regex.Match` supports referring to _all_ captures by position (`match.1`, etc.) whether named or referenced or neither. Due to compiler limitations, result builders do not support forming labeled tuples for named captures.


### Regex-powered algorithms

Regexes can be used right out of the box with a variety of powerful and convenient algorithms, including trimming, splitting, and finding/replacing all matches within a string.

These algorithms are discussed in [String Processing Algorithms][pitches].


### Unicode handling

A regex describes an algorithm to be ran over some model of string, and Swift's `String` has a rather unique Unicode-forward model. `Character` is an [extended grapheme cluster](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries) and equality is determined under [canonical equivalence](https://www.unicode.org/reports/tr15/#Canon_Compat_Equivalence).

Calling `dropFirst()` will not drop a leading byte or `Unicode.Scalar`, but rather a full `Character`. Similarly, a `.` in a regex will match any extended grapheme cluster. A regex will match canonical equivalents by default, strengthening the connection between regex and the equivalent `String` operations.

Additionally, word boundaries (`\b`) follow [UTS\#29 Word Boundaries](https://www.unicode.org/reports/tr29/#Word_Boundaries). Contractions ("don't") are correctly detected and script changes are separated, without incurring significant binary size costs associated with language dictionaries.

Regex targets [UTS\#18 Level 2](https://www.unicode.org/reports/tr18/#Extended_Unicode_Support) by default, but provides options to switch to scalar-level processing as well as compatibility character classes. Detailed rules on how we infer necessary grapheme cluster breaks inside regexes, as well as options and other concerns, are discussed in [Unicode for String Processing][pitches]. 


## Detailed design

```swift
/// A regex represents a string processing algorithm.
///
///     let regex = try Regex(compiling: "a(.*)b")
///     let match = "cbaxb".firstMatch(of: regex)
///     print(match.0) // "axb"
///     print(match.1) // "x"
///
public struct Regex<Output> {
  /// Match a string in its entirety.
  ///
  /// Returns `nil` if no match and throws on abort
  public func matchWhole(_ s: String) throws -> Regex<Output>.Match?

  /// Match part of the string, starting at the beginning.
  ///
  /// Returns `nil` if no match and throws on abort
  public func matchPrefix(_ s: String) throws -> Regex<Output>.Match?

  /// Find the first match in a string
  ///
  /// Returns `nil` if no match is found and throws on abort
  public func firstMatch(in s: String) throws -> Regex<Output>.Match?

  /// Match a substring in its entirety.
  ///
  /// Returns `nil` if no match and throws on abort
  public func matchWhole(_ s: Substring) throws -> Regex<Output>.Match?

  /// Match part of the string, starting at the beginning.
  ///
  /// Returns `nil` if no match and throws on abort
  public func matchPrefix(_ s: Substring) throws -> Regex<Output>.Match?

  /// Find the first match in a substring
  ///
  /// Returns `nil` if no match is found and throws on abort
  public func firstMatch(in s: Substring) throws -> Regex<Output>.Match?

  /// The result of matching a regex against a string.
  ///
  /// A `Match` forwards API to the `Output` generic parameter,
  /// providing direct access to captures.
  @dynamicMemberLookup
  public struct Match {
    /// The range of the overall match
    public var range: Range<String.Index> { get }
  
    /// The produced output from the match operation
    public var output: Output { get }
  
    /// Lookup a capture by name or number
    public subscript<T>(dynamicMember keyPath: KeyPath<Output, T>) -> T { get }
  
    /// Lookup a capture by number
    @_disfavoredOverload
    public subscript(
      dynamicMember keyPath: KeyPath<(Output, _doNotUse: ()), Output>
    ) -> Output { get }
    // Note: this allows `.0` when `Match` is not a tuple.
  
  }
}
```

*Note*: The below are covered by other proposals, but listed here to help round out intuition.

```swift

// Result builder interfaces
extension Regex: RegexComponent {
  public var regex: Regex<Output> { self }

  /// Result builder interface
  public init<Content: RegexComponent>(
    @RegexComponentBuilder _ content: () -> Content
  ) where Content.Output == Output

}
extension Regex.Match {
  /// Lookup a capture by reference
  public subscript<Capture>(_ reference: Reference<Capture>) -> Capture
}

// Run-time compilation interfaces
extension Regex {
  /// Parse and compile `pattern`, resulting in a strongly-typed capture list.
  public init(compiling pattern: String, as: Output.Type = Output.self) throws
}
extension Regex where Output == AnyRegexOutput {
  /// Parse and compile `pattern`, resulting in an existentially-typed capture list.
  public init(compiling pattern: String) throws
}
```

### On severability and related proposals

The proposal split presented is meant to aid focused discussion, while acknowledging that each is interconnected. The boundaries between them are not completely cut-and-dry and could be refined as they enter proposal phase.

Accepting this proposal in no way implies that all related proposals must be accepted. They are severable and each should stand on their own merit.


## Source compatibility

Everything in this proposal is additive. Regex delimiters may have their own source compatibility impact, which is discussed in that proposal.

## Effect on ABI stability

Everything in this proposal is additive. Run-time strings containing regex syntax are represented in the ABI as strings. For this initial release, literals are strings in the ABI as well (they get re-parsed at run time), which avoids baking an intermediate representation into Swift's ABI as we await better static compilation support (see future work).

## Effect on API resilience

N/A

## Alternatives considered


### Regular expressions are a blight upon computing!

"I had one problem so I wrote a regular expression, now I have two problems!"

Regular expressions have a deservedly mixed reputation, owing to their historical baggage and treatment as a completely separate tool or subsystem. Despite this, they still occupy an important place in string processing. We are proposing the "regexiest regex", allowing them to shine at what they're good at and providing mitigations and off-ramps for their downsides.

* "Regular expressions are bad because you should use a real parser"
    - In other systems, you're either in or you're out, leading to a gravitational pull to stay in when... you should get out
    - Our remedy is interoperability with real parsers via `CustomMatchingRegexComponent`
    - Literals with refactoring actions provide an incremental off-ramp from regex syntax to result builders and real parsers
* "Regular expressions are bad because ugly unmaintainable syntax"
    - We propose literals with source tools support, allowing for better syntax highlighting and analysis
    - We propose result builders and refactoring actions from literals into result builders
* "Regular expressions are bad because Unicode"
    - We propose a modern Unicode take on regexes
    - We treat regexes as algorithms to be ran over some model of String, like's Swift's default Character-based view.
* "Regular expressions are bad because they're not powerful enough"
    - Engine is general-purpose enough to support recursive descent parsers with captures, back-references, and lookahead
    - We're proposing a regexy presentation on top of more powerful functionality
* "Regular expressions are bad because they're too powerful"
    - We provide possessive quantifications, atomic groups, etc., all the normal ways to prune backtracking
    - We provide clear semantics of how alternation works as ordered-choice, allowing for understandable execution
    - Pathological behavior is ultimately a run-time concern, better handled by engine limiters (future work)
    - Optimization is better done as a compiler problem, e.g. static compilation to DFAs (future work)
    - Formal treatment of power is better done by other presentations, like PEGs and linear automata (future work)

<!--

### Restrict to regular languages or even to "linear" something something

- ... leads to workarounds that are far worse than what we could build
- ... just inserting a print(), etc., would break a brittle world
- ... more important mitigations can come from engine limiters instead of formal-but-abstract guarantees
- ... predictable and understandable behavior is more important than benchmark scores

### `Pattern<T>` vs `Regex<Substring, T>`

- Overview presented `Pattern<T>`, which has history-preserving recursively nested captures
- In the course of implementing this...
    + Implementation issues around eager/lazy history preservation
        * Eager history preservation consumes tons of memory for something that may never get done
        * Lazy history preservation with our extensible model can lead to re-running side effects
    + Limitations of variadic generics, result builders, and type-level operations
    + Lead to an uncanny valley that is neither `Pattern` nor clearly a regex
- We're choosing to go with the regexiest regex
    + History preservation is future work via explicit API call (instead of paying for it by default)
    + Recursive nesting and `Pattern<T>` is future work, explore in context of parser combinators

-->

### Alternative names

The generic parameter to `Regex` is `Output` and the erased version is `AnyRegexOutput`. This is... fairly generic sounding.

An alternative could be `Captures`, doubling down on the idea that the entire match is implicitly capture `0`, but that can make describing and understanding how captures combine in the result builder harder to reason through (i.e. a formal distinction between explicit and implicit captures).

An earlier prototype used the name `Match` for the generic parameter, but that quickly got confusing with all the match methods and was confusing with the result of a match operation (which produces the output, but isn't itself the generic parameter). We think `Match` works better as the result of a match operation.


### What's with all the `String(...)` initializer calls at use sites?

We're working on how to eliminate these, likely by having API to access ranges, slices, or copies of the captured text.

We're also looking for more community discussion on what the default type system and API presentation should be. As pitched, `Substring` emphasizes that we're referring to slices of the original input, with strong sharing connotations.

The actual `Match` struct just stores ranges: the `Substrings` are lazily created on demand. This avoids unnecessary ARC traffic and memory usage.


### `Regex<Match, Captures>` instead of `Regex<Output>`

The generic parameter `Output` is proposed to contain both the whole match (the `.0` element if `Output` is a tuple) and captures. One alternative we have considered is separating `Output` into the entire match and the captures, i.e. `Regex<Match, Captures>`, and using `Void` for for `Captures` when there are no captures.

The biggest issue with this alternative design is that the numbering of `Captures` elements misaligns with the numbering of captures in textual regexes, where backreference `\0` refers to the entire match and captures start at `\1`. This design would sacrifice familarity and have the pitfall of introducing off-by-one errors.

### Future work: static optimization and compilation

Swift's support for static compilation is still developing, and future work here is leveraging that to compile regex when profitable. Many regex describe simple [DFAs](https://en.wikipedia.org/wiki/Deterministic_finite_automaton) and can be statically compiled into very efficient programs. Full static compilation needs to be balanced with code size concerns, as a matching-specific bytecode is typically far smaller than a corresponding program (especially since the bytecode interpreter is shared).

Regex are compiled into an intermediary representation and fairly simple analysis and optimizations are high-value. This compilation currently happens at run time (as such the IR is not ABI), but more of this could happen at compile time to save load/compilation time of the regex itself. Ideally, this representation would be shared along the fully-static compilation path and can be encoded in the ABI as a compact bytecode. 


### Future work: parser combinators

What we propose here is an incremental step towards better parsing support in Swift using parser-combinator style libraries. The underlying execution engine supports recursive function calls and mechanisms for library extensibility. `CustomMatchingRegexComponent`'s protocol requirement is effectively a [monadic parser](https://homepages.inf.ed.ac.uk/wadler/papers/marktoberdorf/baastad.pdf), meaning `Regex` provides a regex-flavored combinator-like system.

An issues with traditional parser combinator libraries are the compilation barriers between call-site and definition, resulting in excessive and overly-cautious backtracking traffic. These can be eliminated through better [compilation techniques](https://core.ac.uk/download/pdf/148008325.pdf). As mentioned above, Swift's support for custom static compilation is still under development.

Future work is a parser combinator system which leverages tiered static compilation and presents a parser-flavored approach, such as limited backtracking by default and more heavily interwoven recursive calls.


### Future work: `Regex`-backed enums

Regexes are often used for tokenization and tokens can be represented with Swift enums. Future language integration could include `Regex` backing somewhat analogous to `RawRepresentable` enums. A Regex-backed enum could conform to `RegexComponent` producing itself upon a match by forming an ordered choice of its cases.

<!--

### Future work: low-level engine interfaces

- Expose matching engine state, such as the backtracking stack, to libraries
- Future work because that would make it ABI/API, and fix in place execution details
- What is presented here is a lot, really need time to bake that portion
- ... future work includes cancellation, high-water marks, observers, etc., provided by the engine at run time

### Future work: syntactic destructuring match operator

- Swift's `~=` operator, used for language-level pattern matching, returns a `Bool` indicating success or failure.
- Regexes surface more information than just success/fail
- An operator that returns a `T?` would allow `case` expressions to perform a destructuring bind (e.g. inside a switch)
- Future work and it could lead into an overall destructuring story


### Future work: better result builders

- local bindings for refs
- drop-or-keep subpattern captures
- scoped names and operators
- type operators and tuple labels

### Future work: stream processing

- async sources of string-like content
- need to flesh out position/index story
- regex may not be ideal formulation here (unrestricted backtracking)

### Future work: data processing

- regex definitely not ideal formulation, lots of concerns about characters, scripts, unrestricted backtracking, etc
- engine has generic capabilities, just need to find the right expression
- result builders still not great for processing pipelines...

### Future work: baked-in localized processing

- `CustomMatchingRegexComponent` gives an entry point for localized processors
- Future work includes (sub?)protocols to communicate localization intent

-->

[pitches]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/ProposalOverview.md
