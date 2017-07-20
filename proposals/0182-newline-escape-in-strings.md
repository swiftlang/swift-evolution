# String Newline Escaping

* Proposal: [SE-0182](0182-newline-escape-in-strings.md)
* Authors: [John Holdsworth](https://github.com/johnno1962), [David Hart](https://github.com/hartbit), [Adrian Zubarev](https://github.com/DevAndArtist)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Accepted with Revision**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2017-July/000393.html)

* Previous Proposal: [SE-0168](0168-multi-line-string-literals.md)

## Introduction

This proposal is a refinement of [SE-0168](0168-multi-line-string-literals.md) which introduces the ability to escape newlines in multi-line strings to improve readability and maintenance of source material containing excessively long lines.

Swift-evolution thread: [Discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035923.html)

## Motivation

Escaping newlines was first proposed in [SE-0168](0168-multi-line-string-literals.md) to allow long lines in multi-line strings to be hard-wrapped for readability and adherence to coding styles requiring a maximum line length. For example:

```swift
// Excessively long line that requires scrolling to read
let text = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
    """

// Shorter lines that are easier to read, but represent the same long line
let text = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
    tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
    quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
    """
```

But the feature was removed from the [SE-0168](0168-multi-line-string-literals.md) proposal by the Core Team with the following rational:

> Discussion on the list raised the idea of allowing a line to end with \ to "escape" the newline and elide it from the value of the literal; the core team had concerns about only allowing that inside multi-line literals and felt that that could also be considered later as an additive feature.

This proposal argues that enabling escaped newlines for single line strings means that they are not single line anymore, and enabling single quoted strings to span multiple lines does not solve a strongly motivated glaring problem, since they can be upgraded to triple quoted strings. As a result, this proposal only introduces the escaping syntax for multi-line strings.

Incorporating a string continuation character is well founded, used in other development languages, and carries little risk of confusing naive users.

## Detailed design

This proposal introduces `\` as a line continuation character which escapes newlines matching the following regular-expression: `/\\[ \t]*\r?\n/`. In other terms, line continuation requires a `\` character, followed by zero or more horizontal whitespace characters, followed by a newline character. All those characters are omitted from the resulting string.

As a consequence, these rules follow:

* All whitespace characters between `\` and the newline are disregarded.
* All whitespace characters before `\` are included in the string as is.
* An escape character at the end of the last line of a literal is an error, as no newlines follow.

For example:

```swift
let str1 = """↵
    line one \↵
    line two \          ↵
    line three↵
    """↵

assert(str1 == "line one line two line three")
```

This does not affect the indentation removal feature of multiline strings.

## Source compatibility

This proposal does not affect existing source, because it is purely additive - enabling syntax that is not currently allowed in Swift.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect ABI resilience.

## Alternatives considered

An earlier revision of this proposal also allowed the escaping syntax to be used in single-line strings.