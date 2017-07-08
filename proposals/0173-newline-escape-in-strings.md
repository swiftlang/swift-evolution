# Introducing a Universal Newline String Escape

* Proposal: [TBD](TBD.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: TBD
* Status: **Awaiting review**

* Previous Proposal: [SE-0168](0168-multi-line-string-literals.md)

## Introduction

This proposal introduces escaped newlines for all string types including single and multiple lines. Escaping elides in-text newline characters to support better code reading and improve the maintenance of source material containing excessively long lines. 

This proposal adds onto [SE-0168](0168-multi-line-string-literals.md). It is a lightning proposal intended for quick review. An implementation is already available.

Swift-evolution thread: [Discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035923.html)

## Motivation

Newline escapes were not added during the [SE-0168](0168-multi-line-string-literals.md) process. Adding them to multi-line strings would have introduced an inconsistency with respect to conventional string literals. This proposal conforms both multi-line and conventional string construction to allow newline escaping, bringing Swift strings into line with C literals.

Newline continuation enables developers to split text over multiple source lines without introducing new line breaks. This approach enhances source legibility. For example:

```
// Excessively long line that requires scrolling to read
let text = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
            """

// Shorter lines that are easier to read, but represent the same long line
let text = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
            tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
            quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.\
            """
```

Accepting SE-0168 without newline escaping means there was no way to easily escape the last newline of a literal. As a result it was decided that trailing newlines should always be stripped from literals. This decision arguably reduces the feature's usability and intuitive adoption.

Incorporating a string continuation character is well founded, used in other development languages, and carries little risk of confusing naive users.

## Detailed design

This proposal introduces `\` as a line continuation character, enabling strings to extend past the end of the source line. The `\` and the new line character that follow it in source are not incorporated into the string.

Any horizontal whitespace before the \\\<newline> combination will be included in the string as is. Additionally, if an escape character \\ is followed by only horizontal whitespace characters then a \<newline> nothing from the \\ character to the \<newline> (inclusive) will be included in the literal. For example:

	let str1 = """↵
		line one \↵
		line two \		  ↵
		line three↵
		"""↵

	let str2 = "line one \↵
	line two \		  ↵
	line three"↵

	assert(str1 == "line one line two line three")
	assert(str2 == "line one line two line three")

An escape character at the end of the last line of a literal could be considered an error.

This does not affect the indent removal feature of multiline strings and does not suggest that indent removal should be added to conventional strings but it does gave them consistent treatment.

As separate debate, it also gives the user control over whether the final newline should be included in the string and it is recommended that it not always be stripped if this proposal were adopted. This anticipated usage shows this is better suited to more common use cases:

```swift
var xml = """
    <?xml version="1.0"?>
    <catalog>
    """

for (id, author, title, genre, price) in bookTuples {
    xml += """
            <book id="bk\(id)">
                <author>\(author)</author>
                <title>\(title)</title>
                <genre>\(genre)</genre>
                <price>\(price)</price>
            </book>
        """
}

xml += """
    </catalog>
    """
```

This produces a high-impact well-focused language change with low costs, as the update is confined to Lexer.cpp.

## Source compatibility

As this proposal is additive proposing a syntax that is not currently
allowed in Swift this does not affect existing source.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect ABI resilience.

## Alternatives considered

Concatenation can be considered as a "low rent" language solution alternative. This solution is less expressive, clumsier, and, as expressions become more complex, can produce higher compilation costs as it requires the Swift compiler to analyze and optimize each use.
