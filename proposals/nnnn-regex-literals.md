# Regex Literals

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Hamish Knight](https://github.com/hamishknight), [Michael Ilseman](https://github.com/milseman), [David Ewing](https://github.com/DaveEwing)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Awaiting review**
* Implementation: https://github.com/apple/swift-experimental-string-processing
  * Available in nightly toolchain snapshots with `-enable-bare-slash-regex`

## Introduction

We propose the introduction of regex literals to Swift source code, providing compile-time checks and typed-capture inference. Regex literals help complete the story told in *[Regex Type and Overview][regex-type]*.

## Motivation

In *[Regex Type and Overview][regex-type]* we introduced the `Regex` type, which is able to dynamically compile a regex pattern:

```swift
let pattern = #"(\w+)\s\s+(\S+)\s\s+((?:(?!\s\s).)*)\s\s+(.*)"#
let regex = try! Regex(pattern)
// regex: Regex<AnyRegexOutput>
```

The ability to compile regex patterns at run time is useful for cases where it is e.g provided as user input, however it is suboptimal when the pattern is statically known for a number of reasons:

- Regex syntax errors aren't detected until run time, and explicit error handling (e.g `try!`) is required to deal with these errors.
- No special source tooling support, such as syntactic highlighting, code completion, and refactoring support, is available.
- Capture types aren't known until run time, and as such a dynamic `AnyRegexOutput` capture type must be used.
- The syntax is overly verbose, especially for e.g an argument to a matching function.

## Proposed solution

A regex literal may be written using `/.../` delimiters:

```swift
// Matches "<identifier> = <hexadecimal value>", extracting the identifier and hex number
let regex = /(?<identifier>[[:alpha:]]\w*) = (?<hex>[0-9A-F]+)/
// regex: Regex<(Substring, identifier: Substring, hex: Substring)>
```

Forward slashes are a regex term of art. They are used as the delimiters for regex literals in, e.g., Perl, JavaScript and Ruby. Perl and Ruby additionally allow for [user-selected delimiters](https://perldoc.perl.org/perlop#Quote-and-Quote-like-Operators) to avoid having to escape any slashes inside a regex. For that purpose, we propose the extended literal `#/.../#`.

An extended literal, `#/.../#`, avoids the need to escape forward slashes within the regex. It allows an arbitrary number of balanced `#` characters around the literal and escape. When the opening delimiter is followed by a new line, it supports a multi-line literal where whitespace is non-semantic and line-ending comments are ignored.

The compiler will parse the contents of a regex literal using regex syntax outlined in *[Regex Construction][internal-syntax]*, diagnosing any errors at compile time. The capture types and labels are automatically inferred based on the capture groups present in the regex. Regex literals allows editors and source tools to support features such as syntax coloring inside the literal, highlighting sub-structure of the regex, and conversion of the literal to an equivalent result builder DSL (see *[Regex builder DSL][regex-dsl]*).

A regex literal also allows for seamless composition with the Regex DSL, enabling lightweight intermixing of a regex syntax with other elements of the builder:

```swift
// A regex for extracting a currency (dollars or pounds) and amount from input 
// with precisely the form /[$£]\d+\.\d{2}/
let regex = Regex {
  Capture { /[$£]/ }
  TryCapture {
    /\d+/
    "."
    /\d{2}/
  } transform: {
    Amount(twoDecimalPlaces: $0)
  }
}
```

This flexibility allows for terse matching syntax to be used when it's suitable, and more explicit syntax where clarity and strong types are required.

Due to the existing use of `/` in comment syntax and operators, there are some syntactic ambiguities to consider. While there are quite a few cases to consider, we do not feel that the impact of any individual case is sufficient to disqualify the syntax. Some of these ambiguities require a couple of source breaking language changes, and as such the `/.../` syntax requires upgrading to a new language mode in order to use.

## Detailed design

### Typed captures

Regex literals have their capture types statically determined by the capture groups present. This follows the same inference behavior as [the DSL][regex-dsl], and is explored in more detail in *[Strongly Typed Captures][strongly-typed-captures]*. We are therefore proposing the following inference behavior for regex literals:

- A `Substring` is always present for the entire match.
- If any captures are present, a tuple is formed with the `Substring`, with subsequent elements representing the capture types. Captures are ordered according to [their numbering][capture-numbering].

The type of a capture is `Substring` by default, however it gets wrapped in an optional if it is not guaranteed to have a value on a successful match. This occurs when it is nested within a quantification that may be zero, e.g `?`, `*`, and `{0,n}`:

```swift
let regex = /([ab]+)?/
// regex: Regex<(Substring, Substring?)>
```

it also occurs when it appears as a child of an alternation:

```swift
let regex = /([ab]+)|\d+/
// regex: Regex<(Substring, Substring?)>
```

The optional wrapping will nest arbitrarily if the capture is nested within multiple zero-quantifiers or alternations:

```swift
let regex = /(.)*|\d/
// regex: Regex<(Substring, Substring??)>
``` 

Note that optionality does not affect cases where the capture surrounds the zero quantifier or alternation:

```swift
let regex = /([ab]*)cd/
// regex: Regex<(Substring, Substring)>
```

In this case, if the `*` quantifier is matched zero times, the resulting capture will be an empty string.

### Named captures

One aspect of typed captures that is currently unique to the literal is the ability to infer labeled tuple elements for named capture groups. For example:

```swift
func matchHexAssignment(_ input: String) -> (String, Int)? {
  let regex = /(?<identifier>[[:alpha:]]\w*) = (?<hex>[0-9A-F]+)/
  // regex: Regex<(Substring, identifier: Substring, hex: Substring)>
  
  guard let match = regex.matchWhole(input), 
        let hex = Int(match.hex, radix: 16) 
  else { return nil }
  
  return (String(match.identifier), hex)
}
```

This allows the captures to be referenced as `match.identifier` and `match.hex`, in addition to numerically (like unnamed capture groups) as `match.1` and `match.2`. This label inference behavior is not available in the DSL, however users are able to [bind captures to named variables instead][dsl-captures].

### Extended delimiters `#/.../#`, `##/.../##`

Backslashes may be used to write forward slashes within the regex literal, e.g `/foo\/bar/`. However, this can be quite syntactically noisy and confusing. To avoid this, a regex literal may be surrounded by an arbitrary number of balanced number signs. This changes the delimiter of the literal, and therefore allows the use of forward slashes without escaping. For example:

```swift
let regex = #/usr/lib/modules/([^/]+)/vmlinuz/#
// regex: Regex<(Substring, Substring)>
```

The number of `#` characters may be further increased to allow the use of e.g `/#` within the literal. This is similar in style to the raw string literal syntax introduced by [SE-0200], however it has a couple of key differences. Backslashes do not become literal characters. Additionally, a multi-line mode, where whitespace and line-ending comments are ignored, is entered when the opening delimiter is followed by a newline.

```swift
let regex = #/
  usr/lib/modules/ # Prefix
  (?<subpath> [^/]+)
  /vmlinuz          # The kernel
#/
// regex: Regex<(Substring, subpath: Substring)>
```

#### Escaping of backslashes

This syntax differs from raw string literals `#"..."#` in that it does not treat backslashes as literal within the regex. A string literal `#"\n"#` represents the literal characters `\n`. However a regex literal `#/\n/#` remains a newline escape sequence.

One of the primary motivations behind this escaping behavior in raw string literals is that it allows the contents to be easily transportable to/from e.g external files where escaping is unnecessary. For string literals, this suggests that backslashes be treated as literal by default. For regex literals however, it instead suggests that backslashes should retain their semantic meaning. This enables interoperability with regexes taken from outside your code without having to adjust escape sequences to match the delimiters used.

With string literals, escaping can be tricky without the use of raw syntax, as backslashes may have semantic meaning to the consumer, rather than the compiler. For example:

```swift
// Matches '\' <word char> <whitespace>* '=' <whitespace>* <digit>+
let regex = try NSRegularExpression(pattern: "\\\\\\w\\s*=\\s*\\d+", options: [])
```

In this case, the intent is not for the compiler to recognize any of these sequences as string literal escapes, it is instead for `NSRegularExpression` to interpret them as regex escape sequences. As such, a raw string may be used to treat the backslashes literally, allowing `NSRegularExpression` to directly process the escapes, e.g `#"\\\w\s*=\s*\d+"#`.

However this is not an issue for regex literals, as the regex parser is the only possible consumer of such escape sequences. Such a regex can be directly spelled as:

```swift
let regex = /\\\w\s*=\s*\d+/
// regex: Regex<Substring>
```

Backslashes still require escaping to be treated as literal, however we don't expect this to be as common of an occurrence as needing to write a regex escape sequence such as `\s`, `\w`, or `\p{...}`, within a regex literal with extended delimiters `#/.../#`.

#### Multi-line mode

Extended regex delimiters additionally support a multi-line mode when the opening delimiter is followed by a new line. For example:

```swift
let regex = #/
  # Match a line of the format e.g "DEBIT  03/03/2022  Totally Legit Shell Corp  $2,000,000.00"
  (?<kind>    \w+)                \s\s+
  (?<date>    \S+)                \s\s+
  (?<account> (?: (?!\s\s) . )+)  \s\s+ # Note that account names may contain spaces.
  (?<amount>  .*)
  /#
```

In this mode, [extended regex syntax][extended-regex-syntax] `(?x)` is enabled by default. This means that whitespace becomes non-semantic, and end-of-line comments are supported with `# comment` syntax.

This mode is supported with any (non-zero) number of `#` characters in the delimiter. Similar to multi-line strings introduced by [SE-0168], the closing delimiter must appear on a new line. To avoid parsing confusion, such a literal will not be parsed if a closing delimiter is not present. This avoids inadvertently treating the rest of the file as regex if you only type the opening.

### Ambiguities with comment syntax

Line comment syntax `//` and block comment syntax `/*` will continue to be parsed as comments. An empty regex literal is not a particularly useful thing to express, but can be written as `#//#` if desired. `*` would be an invalid starting character of a regex, and therefore does not pose an issue.

A parsing conflict does however arise when a block comment surrounds a regex literal ending with `*`, for example:

  ```swift
  /*
  let regex = /[0-9]*/
  */
  ```

In this case, the block comment prematurely ends on the second line, rather than extending all the way to the third line as the user would expect. This is already an issue today with `*/` in a string literal, though it is more likely to occur in a regex given the prevalence of the `*` quantifier. This issue can be avoided in many cases by using line comment syntax `//` instead, which it should be noted is the syntax that Xcode uses when commenting out multiple lines.


### Ambiguity with infix operators

There is a minor ambiguity when infix operators are used with regex literals. When used without whitespace, e.g `x+/y/`, the expression will be treated as using an infix operator `+/`. Whitespace is therefore required for regex literal interpretation, e.g `x + /y/`. Alternatively, extended literals may be used, e.g `x+#/y/#`.

### Regex syntax limitations

In order to help avoid further parsing ambiguities, a `/.../` regex literal will not be parsed if it starts with a space or tab character. This restriction may be avoided by using the extended `#/.../#` literal.

#### Rationale

This is due to a parsing ambiguity that arises when a `/.../` regex literal starts a new line. This is particularly problematic for result builders, where we expect it to be frequently used, in particular within a `Regex` builder:

```swift
let digit = Regex {
  TryCapture(OneOrMore(.digit)) { Int($0) }
}
// Matches against <digit>+ (' + ' | ' - ') <digit>+
let regex = Regex {
   digit
   / [+-] /
   digit
}
```

Instead of being parsed as 3 result builder elements, the second of which being a regex literal, this is instead parsed as a single operator chain with the operands `digit`, `[+-]`, and `digit`. This will therefore be diagnosed as semantically invalid.

To avoid this issue, a regex literal may not start with a space or tab character. This takes advantage of the fact that infix operators require consistent spacing on either side.

If a space or tab is needed as the first character, it must be either escaped, e.g:

```swift
let regex = Regex {
   digit
   /\ [+-] /
   digit
}
```

or extended literal must be used, e.g:

```swift
let regex = Regex {
   digit
   #/ [+-] /#
   digit
}
```

### Language changes required

In addition to ambiguity listed above, there are also a couple of parsing ambiguities that require the following language changes in a new language mode:

- Deprecation of prefix operators containing the `/` character.
- Parsing an unapplied infix operator containing `/` as the start of a regex literal if a closing `/` is found, and the starting character is valid.
  
#### Prefix operators containing `/`

Prefix operators starting with `/` require banning to avoid ambiguity with cases such as:

```swift
let x = /0; let y = 1/
let z = /^x^/
```

Prefix operators containing `/` more generally also need banning, in order to allow prefix operators to be used with regex literals in an unambiguous way, e.g:
    
```swift
let x = !/y / .foo()
```

Today, this is interpreted as the prefix operator `!/` on `y`. With the banning of prefix operators containing `/`, it becomes prefix `!` on a regex literal, with a member access `.foo`. 

Postfix `/` operators do not require banning, as they'd only be treated as regex literal delimiters if we are already trying to lex as a regex literal.

#### Unapplied infix operators containing `/`

An ambiguity arises with Swift's ability to pass an unapplied operator reference as an argument to a function or subscript, for example:

```swift
let arr: [Double] = [2, 3, 4]
let x = arr.reduce(1, /) / 5
```

The `/` in the call to `reduce` is in a valid expression context, and as such could be parsed as a regex literal. This is also applicable to operators in tuples and parentheses. To help mitigate this ambiguity, a regex literal will not be parsed if the first character is `)`. This should have minimal impact, as this would not be valid regex syntax anyway. This joins the existing space and tab starting character rule.

However this does not mitigate the ambiguity when the next character is a comma, `]`, or another valid operator character such as `^`. These are all valid regex starting characters, with comma and `^` in particular being quite common. In these cases, a regex literal will be parsed if a closing `/` is found.

For example, all of the following will be parsed as regex literals instead of unapplied operators:

```swift
func foo(_ x: (Int, Int) -> Int, _ y: (Int, Int) -> Int) {}

foo(/, /)  // Will become the regex literal `/, /`
foo(/^, /) // Will become the regex literal `/^, /`
foo(!/, /) // Will become prefix `!` on the regex literal `/, /`

// Also affects cases where the closing '/' is outside the argument list.
func bar(_ fn: (Int, Int) -> Int, _ x: Int) -> Int { 0 }
bar(/, 2) + bar(/, 3) // Will become the (invalid) regex literal `/, 2) + bar(/`

// Ambiguity with right square bracket:
struct S {
  subscript(_ fn: (Int, Int) -> Int) -> Int { 0 }
}
func baz(_ x: S) -> Int {
  x[/] + x[/] // Will become the (invalid) regex literal `/] + x[/`
}

// Ambiguity with an unapplied operator with two `/` characters:
func baz(_ x: (Int, Int) -> Int) {}
baz(/^/) // Will become the regex literal `/^/`
```

To disambiguate the cases with the `/` operator, you may surround at least the opening `/` with parentheses, e.g:

```swift
foo((/), /)
bar((/), 2) + bar(/, 3)

func baz(_ x: S) -> Int {
  x[(/)] + x[/]
}
```

This takes advantage of the fact that a regex literal will not be parsed if the first character is `)`.

To disambiguate other operator cases, e.g `/^`, `!/`, and `/^/`, you may either turn the expression into a closure, e.g:

```swift
foo({ $0 /^ $1 }, /)
foo({ $0 !/ $1 }, /)
baz({ $0 /^/ $1 })
```

This takes advantage of the fact that a regex literal will not be parsed in an infix operator position.

In most cases, you may also factor the operator out of the call, e.g:

```swift
let op = (/^)
foo(op, /)
```

Or even split the argument list over multiple lines, e.g:

```swift
foo(/^, 
    /)
```

### Summary of `/.../` parsing

When enabled, the forward slash syntax will be parsed when an opening `/` is encountered in expression position. Because this only affects syntax in an expression position, the following will continue to parse as normal:

```swift
infix operator /^/
func /^/ (lhs: Int, rhs: Int) -> Int { 0 }
let i = 0 /^/ 1
```

But `let r = /^/` will be parsed as a regex.

A regex literal may not begin with space, tab or `)`. Though the latter is already invalid regex syntax. In many cases, we have sufficient context to know that an opening `/` must be a regex literal. In these cases, an error will be emitted if either a closing `/` is not found or an invalid starting character is present. However, within parentheses, tuples, and argument lists, there is an ambiguity with unapplied infix operators. In these cases, a regex literal will only be parsed if a closing `/` is present, and the starting character is valid.

A regex literal may be used with a prefix operator, e.g `let r = ^^/x/` is parsed as `let r = ^^(/x/)`. In this case, when encountering operator characters containing `/` in an expression position, the characters up to the first `/` are split into a prefix operator, and regex literal parsing continues as normal.

## Source Compatibility

As explored above, two source breaking changes are needed for `/.../` syntax:

- Deprecation of prefix operators containing the `/` character.
- Parsing an unapplied infix operator containing `/` as the start of a regex literal if a closing `/` is found, and the starting character is valid.

As such, both these changes and the `/.../` syntax will be introduced in Swift 6 mode. However, projects will be able to adopt the syntax earlier by passing the compiler flag `-enable-bare-regex-syntax`. Note this does not affect the extended delimiter syntax `#/.../#`, which will be usable immediately.

## Future Directions

### Modern literal syntax

We could support a more modern Swift-like syntax in regex literals. For example, comments could be done with `//` and `/* ... */`, and quoted sequences could be done with `"..."`. This would however be incompatible with the syntactic superset of regex syntax we intend to parse, and as such may need to be introduced using a new literal kind, with no obvious choice of delimiter.

However, such a syntax would lose out on the familiarity benefits of standard regex, and as such may lead to an "uncanny valley" effect. It's also possible that the ability to use regex literals in the DSL lessens the benefit that this syntax would bring.

### Typed captures for duplicate named group

PCRE allows duplicate capture group names when `(?J)` is set. However this would be incompatible with labeled tuple elements for the captures, as tuples may not have duplicate names. Given we do not currently support `(?J)` in regex literals, the handling of typed captures here is left as future work. 

### Typed captures for branch reset alternations

PCRE and Perl support a branch reset construct `(?|(a)|(b))` where a child alternation resets the capture numbering for each branch, allowing `(a)` and `(b)` to share the same capture number. This would require unifying their types for the purposes of typed captures. Given we do not currently support this construct, the handling of typed captures here is left as future work.

## Alternatives Considered

Given the fact that `/.../` is an existing term of art for regular expressions, we feel it should be the preferred delimiter syntax. It should be noted that the syntax has become less popular in some communities such as Perl, however we still feel that it is a compelling choice, especially with extended delimiters `#/.../#`. Additionally, while there are some syntactic ambiguities, we do not feel they are sufficient to disqualify the syntax. To evaluate this trade-off, below is a list of alternative delimiters that would not have the same ambiguities, and would not therefore require source breaking changes.

### Extended syntax only `#/.../#`

We could choose to avoid adding the bare forward slash syntax, and instead require at least one `#` character to be present in the delimiter. This would retain some of the familiarity of `/.../` while avoiding the parsing ambiguities and source breaking changes.

However we feel that `/.../` is the better choice of default syntax, especially for simple regex where the additional noise of the `#` characters would be undesirable. While there are some parsing ambiguities to contend with, we do not feel they outweigh the benefits of having a lightweight and instantly recognizable syntax for regex.

### Prefixed quote `re'...'`

We could choose to use `re'...'` delimiters, for example:

```swift
// Matches "<identifier> = <hexadecimal value>", extracting the identifier and hex number
let regex = re'([[:alpha:]]\w*) = ([0-9A-F]+)'
```

The use of two letter prefix could potentially be used as a namespace for future literal types. It would also have obvious extensions to extended and multi-line literals using `re#'...'#` and `re'''...'''` respectively. However, it is unusual for a Swift literal to be prefixed in this way. We also feel that its similarity to a string literal might have users confuse it with a raw string literal. 

Also, there are a few items of regex grammar that use the single quote character as a metacharacter. These include named group definitions and references such as `(?'name')`, `(?('name'))`, `\g'name'`, `\k'name'`, as well as callout syntax `(?C'arg')`. The use of a single quote conflicts with the `re'...'` delimiter as it will be considered the end of the literal. However, alternative syntax exists for all of these constructs, e.g `(?<name>)`, `\k<name>`, and `(?C"arg")`. Those could be required instead. An extended regex literal syntax e.g `re#'...'#` would also avoid this issue.

### Prefixed double quote `re"...."`

This would be a double quoted version of `re'...'`, more similar to string literal syntax. This has the advantage that single quote regex syntax e.g `(?'name')` would continue to work without requiring the use of the alternative syntax or extended literal syntax. However it could be argued that regex literals are distinct from string literals in that they introduce their own specific language to parse. As such, regex literals are more like "program literals" than "data literals", and the use of single quote instead of double quote may be useful in expressing this difference.

### Single letter prefixed quote `r'...'`

This would be a slightly shorter version of `re'...'`. While it's more concise, it could potentially be confused to mean "raw", especially as Python uses this syntax for raw strings.

### Single quotes `'...'`

This would be an even more concise version of `re'...'` that drops the prefix entirely. However, given how close it is to string literal syntax, it may not be entirely clear to users that `'...'` denotes a regex as opposed to some different form of string literal (e.g some form of character literal, or a string literal with different escaping rules).

We could help distinguish it from a string literal by requiring e.g `'/.../'`, though it may not be clear that the `/` characters are part of the delimiters rather than part of the literal. Additionally, this would potentially rule out the use of `'...'` as a future literal kind. 

### Magic literal `#regex(...)`

We could opt for for a more explicitly spelled out literal syntax such as `#regex(...)`. This is a more heavyweight option, similar to `#selector(...)`. As such, it may be considered syntactically noisy as e.g a function argument `str.match(#regex([abc]+))` vs `str.match(/[abc]+/)`.

Such a syntax would require the containing regex to correctly balance parentheses for groups, otherwise the rest of the line might be incorrectly considered a regex. This could place additional cognitive burden on the user, and may lead to an awkward typing experience. For example, if the user is editing a previously written regex, the syntax highlighting for the rest of the line may change, and unhelpful spurious errors may be reported. With a different delimiter, the compiler would be able to detect and better diagnose unbalanced parentheses in the regex.

We could avoid the parenthesis balancing issue by requiring an additional internal delimiter such as `#regex(/.../)`. However this is even more heavyweight, and it may be unclear that `/` is part of the delimiter rather than part of an argument. Alternatively, we could replace the internal delimiter with another character such as ```#regex`...` ```, `#regex{...}`, or `#regex/.../`. However those would be inconsistent with the existing `#literal(...)` syntax and the first two would overload the existing meanings for the ``` `` ``` and `{}` delimiters.

It should also be noted that `#regex(...)` would introduce a syntactic inconsistency where the argument of a `#literal(...)` is no longer necessarily valid Swift syntax, despite being written in the form of an argument.

### Shortened magic literal `#(...)`

We could reduce the visual weight of `#regex(...)` by only requiring `#(...)`. However it would still retain the same issues, such as still looking potentially visually noisy as an argument, and having suboptimal behavior for parenthesis balancing. It is also not clear why regex literals would deserve such privileged syntax.

### Using a different delimiter for multi-line

Instead of re-using the extended delimiter syntax `#/.../#` for multi-line regex literals, we could choose a different delimiter for it. Unfortunately, the obvious choice for a multi-line regex literal would be to use `///` delimiters, in accordance with the precedent set by multi-line string literals `"""`. This signifies a (documentation) comment, and as such would not be viable.

### Double slash `// ... //`

Rather than using single forward slash delimiters `/.../`, we could use double slash delimiters. This would have previously been comment syntax, and would therefore be potentially source breaking. In particular, file header comments frequently use this style. Even if they successfully parse as a regex, they would receive different syntax highlighting, and emit a spurious error about being unused.

This would also significantly impact a variety of commonly occurring comments, some examples from the Swift repository include:

```swift
// rdar://41219750

// Please submit a bug report (https://swift.org/contributing/#reporting-bugs)

//   let pt = CGPoint(x: 1.0, y: 2.0) // Here we query for CGFloat.
```

This syntax also means the editor would not be able to automatically complete the closing delimiter, as it would initially appear to be a regular comment. This further means that typing the literal would receive comment syntax highlighting until the closing delimiter is written.

### Reusing string literal syntax

Instead of supporting a first-class literal kind for regex, we could instead allow users to write a regex in a string literal, and parse, diagnose, and generate the appropriate code when it's coerced to the `Regex` type.

```swift
let regex: Regex = #"([[:alpha:]]\w*) = ([0-9A-F]+)"#
```

However we decided against this because:

- We would not be able to easily apply custom syntax highlighting and other editor features for the regex syntax.
- It would require a `Regex` contextual type to be treated as a regex, otherwise it would be defaulted to `String`, which may be undesired.
- In an overloaded context it may be ambiguous or unclear whether a string literal is meant to be interpreted as a literal string or regex.
- Regex-specific escape sequences such as `\w` would likely require the use of raw string syntax `#"..."#`, as they are otherwise invalid in a string literal.
- It wouldn't be compatible with other string literal features such as interpolations.

### No custom literal

Instead of adding a custom regex literal, we could require users to explicitly write `try! Regex("[abc]+")`. This would be similar to `NSRegularExpression`, and loses all the benefits of parsing the literal at compile time. This would mean:

- No source tooling support (e.g syntax highlighting, refactoring actions) would be available.
- Parse errors would be diagnosed at run time rather than at compile time.
- We would lose the type safety of typed captures.
- More verbose syntax is required.

We therefore feel this would be a much less compelling feature without first class literal support.

[SE-0168]: https://github.com/apple/swift-evolution/blob/main/proposals/0168-multi-line-string-literals.md
[SE-0200]: https://github.com/apple/swift-evolution/blob/main/proposals/0200-raw-string-escaping.md

[pitch-status]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/ProposalOverview.md
[regex-type]: https://github.com/apple/swift-evolution/blob/main/proposals/0350-regex-type-overview.md
[strongly-typed-captures]: https://github.com/apple/swift-experimental-string-processing/blob/main/Documentation/Evolution/StronglyTypedCaptures.md

[internal-syntax]: https://github.com/apple/swift-experimental-string-processing/blob/39cb22d96d90ee7cb308b1153e106e50598afdd9/Documentation/Evolution/RegexSyntaxRunTimeConstruction.md
[extended-regex-syntax]: https://github.com/apple/swift-experimental-string-processing/blob/39cb22d96d90ee7cb308b1153e106e50598afdd9/Documentation/Evolution/RegexSyntaxRunTimeConstruction.md#extended-syntax-modes

[capture-numbering]: https://github.com/apple/swift-experimental-string-processing/blob/9e09bf8c8ee5aebe43be9ba6a9a73a0970eebbfc/Documentation/Evolution/RegexSyntaxRunTimeConstruction.md#group-numbering

[regex-dsl]: https://github.com/apple/swift-evolution/blob/main/proposals/0351-regex-builder.md
[dsl-captures]: https://github.com/apple/swift-evolution/blob/main/proposals/0351-regex-builder.md#capture-and-reference
