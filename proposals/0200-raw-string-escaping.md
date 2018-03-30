# "Raw" mode string literals

* Proposal: [SE-0200](0200-raw-string-escaping.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active Review (March 16...26, 2018)**
* Toolchain: [swift-LOCAL-2018-03-24-a-osx.tar.gz](http://johnholdsworth.com/swift-LOCAL-2018-03-24-a-osx.tar.gz)
* Implementation: [apple/swift#13055](https://github.com/apple/swift/pull/13055)
* Forum Links: [Proposal](https://forums.swift.org/t/se-0200-raw-mode-string-literals/11048) [Pitch](https://forums.swift.org/t/pitch-raw-mode-string-literals/7120)
* Bugs: [SR-6362](https://bugs.swift.org/browse/SR-6362)

## Introduction

During the discussion on [multi-line string literals](https://github.com/apple/swift-evolution/blob/master/proposals/0168-multi-line-string-literals.md) a mode for "raw-mode" strings was discussed but postponed for later consideration. This proposal looks to move this idea forward and suggests the a change be made to the Swift lexer to allow the entry of "raw" string literals by surrounding them with `#raw("raw literal")`. In raw literals, the \ character would have no special meaning and the closing delimiter would be `")`. This distinctive delimiter means they could contain double quotes.

Raw string literals are used in Python, C++, Python, and Lua and other languages. They support tech-oriented content for regular expressions, markup language strings, etc, without adding language-specific delimiters to allow standard string parsing. This produces more readable and maintainable string content for these special purposes.

Like multi-line strings which would also have a `#raw("""... """)` counterpart and, neither would create a new String type per sae, the result would be a Swift.String and this processing is transparent after compilation. Multi-line raw literals would still have indentation removed.

Many have expressed concerns that this clutters the Swift language for marginal benefit. Strings are an important data type and it is one of the stated aims of Swift to provide rich support for them. This wouldn't be a feature that new users would be required to know and if they did encounter it the feature has been designed to be easy to understand.

This proposal can accommodate custom delimiters between the opening `(` and the `"` character and this sequence must be repeated at the end of the string. For example the following is valid:

    print(#raw(🤡"SE-200"🤡))

Further, the proposal suggests the inclusion of a feature of "interpolating raw strings" where no escapes are processed except for `\()` interpolations which are. This was found to be very useful in practice and does not overload the feature if we use the following double bracketed syntax reminiscent of the inclusions themselves:

    print(#raw(("SE-\("200")")))

## Motivation

Regular expressions represent the most common, but not singular, motivation for incorporating raw strings into the Swift language. Raw quoting enables users to enter regular expressions without having to escape each backslash use. Patterns often contain elements such as "\w" or "\S". These do not translate well to Swift's existing string literal syntax, resulting in overly complex strings such as:

    let sentence = "\\w+(\\s+\\w+)\\."
    
The raw literal equivalent would be
    
    let sentence = #raw("\w+(\s+\w+)*\.")

Adopting this proposal does not prejudice the future development of native regex language support. A raw string feature should be considered as a separate orthogonal feature.

Windows uses backslash delimiters for file paths. It is easier to read and maintain a path that does not require backslash escaping:

	#raw("c:\windows\system32\path\to\something")
	"c:\\windows\\system32\\path\\to\\something"
	
This problem is encountered when writing code generators for `\` laden languages such as `Tex` or when looking to embed language code snippets of `C` or `Swift` itself which contain string that contain `\`.

	#raw(_"    print("Hello World\n");"_)
	"    print(\"Hello World\\n\");"

Embed JSON messages offers similar challenges. JSON can contain `\` characters to escape `"`s in strings and if the message is to be pasted in verbatim then, raw string literals provide a simpler and more direct way to incorporate that content into Swift source.

	#raw("""
		[
			{
				"id": "12345",
				"title: "A title that \"contains\" \\\""
			}
		]
		""")

	"""
		[
			{
				\"id\": \"12345\",
				\"title\": \"A title that \\\"contains\\\" \\\\\\\""
			}
		]
	"""

Raw string literals allow you to cut and paste literal strings without hand-annotating each backslash. This minimises the potential to introduce bugs should an escaping backslash be missed in translation.
	
Raw string literals go beyond convenience to improve clarity, correctness, and inspection. Raw strings simplify understanding exact string content at a glance.

## Proposed solution

The proposal suggests a new "raw" string literal syntax by surrounding any string with #raw("literal") which alters slightly the behaviour of the compiler in realising the literal. The `\` character would loose it's role as an escaping introducer altogether.

    let sentence = #raw("\w+(\s+\w+)*\.")

Some examples of raw mode literals and their existing literal equivalents:

	#raw("\n\(var)\n") == "\\n\\(var)\\n"

	#raw("\?\y\=") == "\\?\\y\\="

	#raw("c:\windows\system32") == "c:\\windows\\system32"

	#raw("""
		Line One\
		Line Two\
		""") == "Line One\\\nLineTwo\\"

The full syntax is as follows:

	#raw([(][delimiter]"contents"[delimiter][)])

Where a second enclosing set of brackets is used, the literal can still process interpolation escapes to include values. The delimiter is a convenience for particularly difficult cases where the string contents contain code or for decoration to make the extent of a multi-line literal, for example, clearer.

## Detailed design

The changes are confined to the file lib/Parse/Lexer.cpp and involves check for a flag whether the string was prefixed by #raw disabling processing processing of backslash escapes and is localised to the function Lexer::lexCharacter in the code. If the `#raw` introducer was present, both the backslash and the unknown character are passed into the literal in Lexer::getEncodedStringSegment. A further change is also required to the main switch statement in Lexer::lexImpl and Token.h to convey the flag from parsing to code generation phases.

## Source compatibility

This is a purely additive change. The syntax proposed is not currently valid Swift.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

An alternative proposal where known escapes retained their functionality and anything else was passed through was considered. This found to be too difficult to reason about in practice. 

Alternative "introducers" where considered including using Python's Syntax `r""`. This doesn't follow Swift patterns and was very unpopular among developers.

Other names for the `#raw` introducer could be considered such as `#rawStringLiteral` or `#rawString` but for the author it is already obvious this is a String and a literal and such verbosity should not be imposed on the user. This name does not form a functional part of the feature and can be discussed in the forum.

`\"a string with a \ in it"` was also considered and is not sufficiently self explanatory. Some have suggested using `'a string'` which has a precedent in Perl but the author would rather this was reserved for something single character related acknowledging Swift's origins in C. In the finish single character delimiters are simply not unique enough have the feature cover a wide range of use cases.

## Acknowledgements

Thanks to Erica Sadun for proofing various versions of this proposal and contributing the well written sections of the text.
