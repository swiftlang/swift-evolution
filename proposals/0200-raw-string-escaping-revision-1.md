# "Raw" mode string literals

* Proposal: [SE-0200](0200-raw-string-escaping.md)
* Author: [John Holdsworth](https://github.com/johnno1962), [Brent Royal-Gordon](https://github.com/brentdax), [Erica Sadun](https://github.com/erica)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Returned for revision**
* Implementation: [apple/swift#17668](https://github.com/apple/swift/pull/17668)
* Bugs: [SR-6362](https://bugs.swift.org/browse/SR-6362) **Needs Update for New Design**

## Introduction

Like many computer languages, Swift string literals use an escape character (`\`) to represent non-printing characters. Escapes can be also used to add string delimiters (the double quote), the escape character (the backslash itself), and (uniquely in Swift) to allow interpolation of expressions into a string. 

Escape characters provide useful and necessary capabilities but strings containing many escape sequences are difficult to read. Other languages have solved this problem by providing an alternate "raw" string literal syntax which does not process escape sequences. 

We propose to do the same, using a new design which we believe fits Swift's simple and clean syntax. This design supports both single-line and multi-line string literals, and can contain any content whatsoever.

This proposal has been extensively revised based on the Core Team feedback for [SE-0200](https://forums.swift.org/t/returned-for-revision-se-0200-raw-mode-string-literals/11630). It was discussed on the [Swift online forums](https://forums.swift.org/t/pure-bikeshedding-raw-strings-why-yes-again/13866).

### Background

Raw strings and their design have been discussed in the following Evolution forum threads:

* [\[Pitch\] Raw mode string literals](https://forums.swift.org/t/pitch-raw-mode-string-literals/7120/5)
* [SE-0200: "Raw" mode string literals (Review thread)](https://forums.swift.org/t/se-0200-raw-mode-string-literals/11048)
* [\[Returned for revision\] SE-0200: "Raw" mode string literals
](https://forums.swift.org/t/returned-for-revision-se-0200-raw-mode-string-literals/11630)
* [\[Pitch v2\]: Raw strings and SE-0200](https://forums.swift.org/t/pitch-v2-raw-strings-and-se-0200/11660)
* [Pure Bikeshedding: Raw Strings (why yes, again!)](https://forums.swift.org/t/pure-bikeshedding-raw-strings-why-yes-again/13866)

## Background: Escape Sequences

Normal string literals may include the following special character sequences:

* The escaped special characters `\0` (null character), `\\` (backslash), `\t` (horizontal tab), `\n` (line feed), `\r` (carriage return), `\"` (double quotation mark) and `\'` (single quotation mark)
 
* An arbitrary Unicode scalar, written as `\u{n}`, where *n* is a 1–8 digit hexadecimal number with a value equal to a valid Unicode code point

* An interpolated expression, introduced by `\(` and terminated by `)`

The backslash escape tells the compiler that a sequence should combine for a special literal. 

In raw strings, escapes are neither required nor recognized. In a raw string, the sequence `\\\n` represents three backslashes followed by the letter n, not a backslash followed by a line feed.

## Motivation

Raw strings are intended for non-trivial content which belongs directly in source code -- not in an external file -- but cannot be satisfactorily maintained or read in escaped form.

Hand-escaped strings require time and effort to transform source material to an escaped form. It is difficult to validate the process to ensure the escaped form properly represents the original text. This task is also hard to automate as it may not pick up intended nuances, such as recognizing embedded dialog quotes.

Escaping actively interferes with inspection. Developers should be able to inspect and modify raw strings in-place without removing that text from source code. This is especially important when working with precise content such as code sources and regular expressions.

Backslash escapes are common in other languages and formats, from JSON to LaTeX to Javascript to regular expressions. Embedding these to a string literal currently requires doubling-up escapes, or even quadrupling if the source is pre-escaped. Pre-escaped source should be maintained exactly as presented so it can be used, for example, when contacting web-based services.

Finally, raw strings are transportable. They allow developers to cut and paste content both from and to the literal string. This allows testing, reconfiguration, and adaption of raw content without the hurdles escaping and unescaping that limit development.

In short, a good raw string feature should let users embed any valid Unicode text snippet in a Swift string literal merely by surrounding it with appropriate delimiters, without altering the content itself.

### Examples

Raw string literals may include characters normally used for escaping (such as the backslash `\` character) and characters normally requiring escaping (such as a double quote `"`). For example, consider the following multiline string. It represents code to be output at some point in the program execution:

```
let separators = """
    public static var newlineSeparators: Set<Character> = [
        // [Zl]: 'Separator, Line'
        "\u{2028}", // LINE SEPARATOR

        // [Zp]: 'Separator, Paragraph'
        "\u{2029}", // PARAGRAPH SEPARATOR
    ]
    """
```

Unescaped backslash literals cause the unicode escape sequences to be evaluated and replaced in-string. This produces the following result:

```
public static var newlineSeparators: Set<Character> = [
    // [Zl]: 'Separator, Line'
    "
", // LINE SEPARATOR

    // [Zp]: 'Separator, Paragraph'
    "
", // PARAGRAPH SEPARATOR
]
```

To preserve the intended text, each backslash must be escaped, for example `\\u{2029}`. This is a relatively minor edit but if the code is being copied in and out of the source to permit testing and modification, then each hand-escaped cycle introduces the potential for error.

Single-line string literals may similarly be peppered with backslashes to preserve their original intent, as in the following examples. 

```
// Quoted Text
let quote = "Alice: "How long is forever?" White Rabbit: "Sometimes, just one second."" 
let quote = "Alice: \"How long is forever?\" White Rabbit: \"Sometimes, just one second.\""

// and

// Regular Expression
let ucCaseCheck = "enum\s+.+\{.*case\s+[:upper:]"
let ucCaseCheck = "enum\\s+.+\\{.*case\\s+[:upper:]"
```

Escaping hinders readability and interferes with inspection, especially in the latter example, where the content contains secondary escape sequences. Using a raw form ensures the expression can be read and updated as needed in the form that will be passed by the literal string.

### Candidates

A good candidate for raw strings is non-trivial and is burdened by escaping because it:

* Is obscured by escaping. Escaping actively harms code review and validation.
* Is already escaped. Escaped material should not be pre-interpreted by the compiler.
* Requires easy transport between source and code in both directions, whether for testing or just updating source.

The following example is a poor case for using a raw string:

```
let path = "C:\\AUTOEXEC.BAT"
```

The example is trivial and the escaping is not burdensome. It's unlikely that the string contents will require any further modification or reuse in a raw form.

### Utility

Raw strings are most valuable for the following scenarios.

**Metaprogramming**: Use cases include code-producing-code. This incorporates utility programming and building test cases without escaping. Apps may generate color scheme type extensions (in Swift, ObjC, for SpriteKit/SceneKit, literals, etc) or date formatters, perform language-specific escaping, create markup, and more.  

Escaping complicates copying and pasting from working code into your source and back. When you're talking about code, and using code, having that code be formatted as an easily updated raw string is especially valuable.

Examples of popular apps that perform these tasks include Kite Compositor and PaintCode. Any utility app that outputs code would benefit in some form.

**Regular expressions**: While regex in general is a much larger problem than raw strings, it is a primary (if not the primary) use case for many Swift developers. Even if we get native regular expressions in Swift, we will still sometimes have to write regular expressions intended for use in other systems using raw literals. 

For instance, if you need to send a regex to a server, or embed it in Javascript, or put it in a SQL query, or (because you're calling existing code which requires it) you need to use `NSRegularExpression` directly, you'll still express a regular expression as a string literal. Raw literals will make that much easier.

Our design's pound syntax might also be useful to extend to native regex literals. If this proposal is accepted, we'd already have it established in the language.

**Pedagogy**: Not all Swift learning takes place in the playground and not all code described in Swift source files use the Swift programming language. 

Code snippets extend beyond playground-only solutions for many applications. Students may be presented with source code, which may be explained in-context within an application or used to populate text edit areas as a starting point for learning.

Removing escaped snippets to external files makes code review harder. Escaping (or re-escaping) code is a tedious process, which is hard to inspect and validate. 

**Data Formats and Domain Specific Languages**: It's useful to incorporate short sections of unescaped or pre-escaped JSON and XML. It may be impractical to use external files and databases for each inclusion. Doing so impacts inspection, maintenance, and updating.

**Windows paths**: Windows uses backslashes to delineate descent through a directory tree: e.g., `C:\Windows\All Users\Application Data`. The more complex the path, the more intrusive the escapes.

## Status

"Raw-mode" strings were first discussed during the [SE-0168 Multi-Line String literals](https://github.com/apple/swift-evolution/blob/master/proposals/0168-multi-line-string-literals.md) review and postponed for later consideration. This proposal focuses on raw strongs to allow the entry of single and multi-line string literals.

The first iteration of [SE-0200](https://github.com/apple/swift-evolution/blob/master/proposals/0200-raw-string-escaping.md) proposed adopting Python's model, using `r"...raw string..."`. The proposal was returned for revision with the [following feedback](https://forums.swift.org/t/returned-for-revision-se-0200-raw-mode-string-literals/11630):

> The review of SE-0200: "Raw" mode string literals 71 ran from March 16…26, 2018. The proposed is returned for revision, and should be further discussed as a pitch to coalesce further before coming up for review again.
>
> 
> During the review discussion, a few issues surfaced with the proposal, including:
>
> The proposed r"..." syntax didn’t fit well with the rest of the language. The most-often-discussed replacement was #raw("..."), but the Core Team felt more discussion (as a pitch) is necessary.
>
> The proposal itself leans heavily on regular expressions as a use case for raw string literals. Several reviewers remarked that the motivation wasn’t strong enough to justify the introduction of new syntax in the language, so a revised proposal will need additional motivating examples in other domains.

To move forward, the new raw string design must provide a suitable Swift-appropriate syntax that works within the language's culture and conventions.

## Prior Art

The following links explore the existing art in other languages. We were inspired by the [Rust raw string RFC discussion](https://github.com/rust-lang/rust/issues/9411) when researching these features.

| Syntax | Language(s) | Possible in Swift? | Swifty? |
| ----- | --------- | ------------- | -------- |
| `'Hello, world!'` | Bourne shell, Perl, PHP, Ruby, Windows PowerShell | Yes | Yes if Rust-style multiplicity allows incorporating `'` into raw strings. May be too narrow a use-case to burn `'`. |
| `q(Hello, world!)` | [Perl](https://en.wikipedia.org/wiki/String_literal) (alternate) | Maybe (depends on delimiter) | No |
| `%q(Hello, world!)` | Ruby (alternate) | No (`%` is a valid prefix operator) | No |
| `@"Hello, world!"` | [C#](https://msdn.microsoft.com/en-us/library/69ze775t.aspx), F# | Yes (but would be awful for Obj-C switchers) | No |
| `R"(Hello, world!)"` | [C++11](https://en.cppreference.com/w/cpp/language/string_literal) | Yes | No |
| `r"Hello, world!"` | [D](https://tour.dlang.org/tour/en/basics/alias-strings), [Python](http://wiki.c2.com/?RawStrings) | Yes | No |
| `r#"Hello, world!"#` | [Rust](https://doc.rust-lang.org/reference/tokens.html#raw-string-literals) | Yes | Would need to drop the opening `r` and maybe change the delimiter from `#`. |
| `"""hello \' world"""` and `raw"Hello, world!"` | Scala | No/Yes | No |
| ``` `Hello, world!` ``` | [D](https://tour.dlang.org/tour/en/basics/alias-strings), [Go](https://golang.org/ref/spec), \`...\` | No (conflicts with escaped identifiers) | No, needs Rust multiplicity |
| ``` ``...`` ``` | [Java](http://openjdk.java.net/jeps/326), any number of \` | No (conflicts with escaped identifiers) | Yes |


## Design

We determined that Rust's approach to raw string literals is the best starting point, offering the greatest flexibility in the smallest syntactic footprint.

In Rust, raw string literals are written as `r"..."`. To embed double-quotes in a Rust raw string literal, you add one or more pound signs before the opening quote, and put a matching number of pound signs after the closing quote: `r#"..."..."#`, `r##"...#"..."##`, etc. Rust developers assured us that even one pound sign was unusual and more than one almost never needed but it's nice to have the flexibility in the rare cases where you need it.

### Leading Backslash

The `r"..."` syntax failed to fit with Swift's design aesthetics. Instead, we chose to use a leading backslash, Swift's existing "escape" symbol. Under this design, a raw string looks like this:

```
\"This is a raw string"

\"""
    This is also a 
    raw string
    """
```

Both forms resemble existing string literals and the leading backslash suggests escaping.

### Ignoring Escape Sequences

Raw strings allow you to eliminate escape sequences to present text as intended for use:

```
\"c:\windows\system32" // vs. "c:\\windows\\system32"
\"\d{3) \d{3} \d{4}" // vs "\\d{3) \\d{3} \\d{4}"
```

The following example terminates with backslash-r-backslash-n:

```
\"a raw string containing \r\n" 
// vs "a raw string containing \\r\\n"
```

The same raw behavior is extended to multi-line strings:

```
\"""
    a raw string containing \r\n
    """
```

### Incorporating Escape Sequences

Raw strings allow you to incorporate already-escaped text. For example, you can paste static data without having to worry about re-escaping a JSON message

```
\"""
	[
		{
			"id": "12345",
			"title: "A title that \"contains\" \\\""
		}
	]
	"""
```

Without raw strings this would be silently un-escaped to yield an invalid JSON message. Even if you did remember to escape, this process would be error-prone and difficult to maintain.

### Custom Delimiters

A raw string is normally terminated by `"` or `"""` for single and multi-line strings.  In a normal string, the `"` character can be escaped for inclusion. That's not an option in a raw string.

We follow Rust's example to override this behavior and permit embedded quotes by creating custom delimiters. Just add an arbitrary number of pound signs before the opening quote and match them after the closing quote:

```
\#"a string with "double quotes" in it"#

\##"a string that needs "# in it"##

\###"""
	a string with 
	"""
	in it
	"""###
```

These custom delimiters enable you to embed `"` and `"""` within the string, ensuring the raw string can represent all strings including embedded ones.

We also allow the custom delimiter syntax to be used with _conventional_ strings:

```
#"Hello "World""#
#"""
	print("""
		Hello \(what)
		""")
	"""#
```

This example is a conventional string in all ways other than the opening and closing delimiters. The interpolation sequence in this example _will_ be evaluated. The leading backslash's absence signifies this is a _non-raw string_.

This is useful in cases where a string contains many embedded double-quote characters which would be burdensome to escape, but doesn't contain literal backslashes and may be best expressed by escapes or interpolations. Error messages or code not containing backslashes might be good candidates for conventional strings with custom delimiters.

* Custom delimiters ensure you can use elements that normally terminate strings within the string literal without escaping them.
* This syntax uses one or more pound sign delimiters to adapt either raw or conventional strings. 
* A leading `\` means a raw string literal is being defined.
* `#` means custom delimiters are in use. 
* The number of leading pound signs matches the number of trailing pound signs.

### Discoverability and Recognition

There are two questions of developer approach: discoverability ("how do I do a raw string in Swift") and recognition ("Why do some strings in Swift start with `\` or `#`?"). Both are relatively easy to search for.

When presented to developers unfamiliar with the raw string syntax, we felt that `\` used an existing semantic cue to indicate "escaping". We do not believe it is overly burdensome to search the web for:

* "Why is there a backslash before the quote in Swift strings?"
* "What do #/pound/number/etc signs mean in Swift strings?"
* "How do I use raw strings in Swift?"

## Implementation

Changes are largely confined to the file lib/Parse/Lexer.cpp. They involve a slight modification to the main lexer loop Lexer::lexImpl(). When the start of a custom-delimited string is detected, looking for tokens starting with `#` or `\`, Lexer::lexStringLiteral() is called with modified arguments. Targeted changes to Lexer::lexCharacter() and Lexer::getEncodedStringSegment() bypass processing of the escape character `\` when selected.

A new `RawString` flag in Token.h carries the the string escaping mode from the parsing to code generation phases of compilation.

## Source compatibility

This is a purely additive change. The syntax proposed is not currently valid Swift.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

We evaluated many, *many* designs from other languages and worked through a long thread full of bikeshedding. We will list the most notable rejected designs here, but these are just the tip of the iceberg.

##### Excluding single quotes and backticks

Single quotes are a common syntax for raw strings in other languages. However, they're also commonly used for character literals (i.e. integer literals containing the value of a Unicode scalar) in other languages. If we use single quotes for raw strings, we cannot use them for character literals or any other future proposal. We think `\"..."` is a good syntax for raw strings and a bad syntax for any other potential feature, so we see no need to burn single quotes on this feature.

Similarly, while backticks preserve the meaning of "code voice" and "literal", as you are used to in markdown, they would conflict with escaped identifiers.

We decided to stick with double quotes as currently used in single-line and multi-line Swift strings.

##### Using "raw" and "rawString"

The original design `r"..."` was rejected in part for not being Swifty, that is, not taking on the look and feel and characteristics of existing parts of the language. Similar approaches like `raw"..."` and `#raw"..."` carry the same issues. Leading text is distracting and competes for attention with the content of the string that follows. And function-like constructs like `#raw("...")` harmonize better with the language syntax, but are even worse for readability.

In our samples, we concluded that both the leading backslash and pound signs did not overwhelm string content.

##### Using user-specified delimiters

We felt user-specified delimiters overly complicated the design space, were harder to discover and use, and were generally un-Swifty. The pound sign is rarely used and a minor burden on the syntax.

```
@rawString(delimiter: @) \@"Hello"@ // no
```

We considered a Perl/Ruby-like approach to arbitrary delimiters, but quickly rejected it. The arbitrary delimiter rules in these languages are complex and have many corner cases; we don't need or want that complexity.

We also rejected a standalone raw string attribute for being wordy and heavy, especially for short literals.
