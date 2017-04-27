# Multi-Line String Literals

* Proposal: [SE-0168](0168-multi-line-string-literals.md)
* Authors: [John Holdsworth](https://github.com/johnno1962), [Brent Royal-Gordon](https://github.com/brentdax), [Tyler Cloutier](https://github.com/TheArtOfEngineering)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Implemented (Swift 4)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035923.html)
* Bug: [SR-170](https://bugs.swift.org/browse/SR-170)

## Introduction

This proposal introduces multi-line string literals to Swift source code.
This has been discussed a few times on swift-evolution most recently
putting forward a number of different syntaxes that could achieve this goal
each of which has their own use case and constituency for discussion.

[Swift-evolution thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/001565.html)

## Motivation

Multi-line String literals are a common programming-language feature that is, to date, still missing in
Swift. Whether generating XML/JSON messages or building usage messages in Swift scripts, providing string
literals that extend over multiple lines offers a simple way to represent text without having to manually
break lines using string concatenation. Concatenation is ungainly and may result in slow compilation.

## Proposed solution

After consideration this proposal puts forward a single simple syntax for inclusion: `"""long strings"""`.
This has the advantage that it is well supported by the syntax highlighters on GitHub and existing editors
and is a relatively minor change to the Swift Lexer. Interpolation would work as before.

### Long strings

Long strings are strings delimited by `"""triple quotes"""` that can contain newlines and individual `"`
characters without the need to escape them.

    assert( xml == """
        <?xml version="1.0"?>
        <catalog>
            <book id="bk101" empty="">
                <author>\(author)</author>
                <title>XML Developer's Guide</title>
                <genre>Computer</genre>
                <price>44.95</price>
                <publish_date>2000-10-01</publish_date>
                <description>An in-depth look at creating applications with XML.</description>
            </book>
        </catalog>
        """ )

To allow free formatting of the literal an indentation stripping operation is applied whereby
any whitespace characters in front of the closing delimiter are removed from each of the lines 
in the literal. As part of this process any initial linefeed is also removed. This allows the
developer to paste literal content directly into the string without modification. Some concern
has been expressed about could introduce confusion if the prefixing indentation of each line does
not contain the same whitespace characters, though this can be checked for by a compiler warning.

## Detailed design

These changes are envisaged to be mostly confined to the Swift tokeniser: lib/Parse/Lexer.cpp.
The new string literals would be presented to the grammar as simply being string literals.
This has been explored in a PR for a [prototype toolchain](https://github.com/apple/swift/pull/2275)
and seems to be a robust approach. Other details are explored in the prototype such as
escaping the newline in literals resulting in it not being included in the final literal.

## Impact on existing code

As this proposal is additive it does not affect existing code.

## Alternatives considered

Two other alternative syntaxes were discussed in the swift-evolution thread.
It became apparent that each syntax had its own, at times, non-overlapping
constituency of supporters.

### Continuation quotes

The basic idea of continuation quotes is straightforward. If a quoted string literal is not closed by "
before the end of the line and the first non-whitespace character on the next line is " it is taken to
be a continuation of the previous literal.

    let xml = "<?xml version=\"1.0\"?>
        "<catalog>
        "    <book id=\"bk101\" empty=\"\">
        "        <author>\(author)</author>
        "        <title>XML Developer's Guide</title>
        "        <genre>Computer</genre>
        "        <price>44.95</price>
        "        <publish_date>2000-10-01</publish_date>
        "        <description>An in-depth look at creating applications with XML.</description>
        "    </book>
        "</catalog>
        ""

The advantage of this format is it gives precise control of exactly what is included in the literal. It also
allows code to be formatted in an aesthetically pleasing manner. Its main disadvantage is that some external 
editors will not be familiar with the format and will be unable to correctly syntax highlight literals.

### Heredoc

Taking a precedent from other languages, a syntax such as the following could be used to introduce
literals into a codebase. 

    assert( xml == <<"XML" )
        <?xml version="1.0"?>
        <catalog>
            <book id="bk101" empty="">
                <author>\(author)</author>
                <title>XML Developer's Guide</title>
                <genre>Computer</genre>
                <price>44.95</price>
                <publish_date>2000-10-01</publish_date>
                <description>An in-depth look at creating applications with XML.</description>
            </book>
        </catalog>
        XML

The same indentation stripping rules would be applied as for long strings. This syntax has the 
advantage of being able to paste content in directly and the additional advantage that the
literal is separated from the line of code using it, increasing clarity. Its main disadvantage
is a more practical one: it is a more major departure for the compiler in that tokens
in the AST are no longer in source file order. Testing has, however, shown the toolchain
to be surprisingly robust in dealing with this change once a few assertions were removed.

