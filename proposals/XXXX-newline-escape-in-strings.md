# String Newline Escaping

* Proposal: [SE-XXXX](XXXX-newline-escape-in-strings.md)
* Authors: [John Holdsworth](https://github.com/johnno1962), [David Hart](https://github.com/hartbit), [Adrian Zubarev](https://github.com/DevAndArtist)
* Review Manager: TBD
* Status: **Awaiting review**

* Previous Proposal: [SE-0168](0168-multi-line-string-literals.md)

## Introduction

This proposal introduces the ability to escape newlines in single and multi-line strings to improve readability and maintenance of source material containing excessively long lines.

This proposal adds onto [SE-0168](0168-multi-line-string-literals.md).

Swift-evolution thread: [Discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035923.html)

## Motivation

Escaping newlines in multi-line strings was removed from the [SE-0168](0168-multi-line-string-literals.md) proposal by the Core Team with the following rational:

> Discussion on the list raised the idea of allowing a line to end with \ to "escape" the newline and elide it from the value of the literal; the core team had concerns about only allowing that inside multi-line literals and felt that that could also be considered later as an additive feature.

Adding them to multi-line strings would have introduced an inconsistency with respect to conventional string literals. This proposal conforms both multi-line and conventional string construction to allow newline escaping, enabling developers to split text over multiple source lines without introducing new line breaks. This approach enhances source legibility. For example:

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

Incorporating a string continuation character is well founded, used in other development languages, and carries little risk of confusing naive users.

## Detailed design

This proposal introduces `\` as a line continuation character which escapes newlines matching the following regular-expression: `/\\[ \t]*\n/`. In other terms, line continuation requires a `\` character, followed by zero or more whitespace characters, followed by a newline character. All those characters are omitted from the resulting string.

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

let str2 = "line one \↵
line two \          ↵
line three"↵

assert(str1 == "line one line two line three")
assert(str2 == "line one line two line three")
assert(str1 == str2)
```

This does not affect the indentation removal feature of multiline strings and does not suggest that indentation removal should be added to conventional strings but it does give them consistent treatment.

## Further discussions

The following topics are related to escaping newlines. If newline-escaping where accepted it may be appropriate to revisit these decisions when considering this proposal though that shouldn't be the focus of the discussion.

### Reconsidering stripping the last newline in multi-line strings

When SE-0168 was reviewed, it was decided to strip the last newline in multi-line strings. Doing the opposite would have been ill-advised without a line continuation character to escape it when necessary. If this proposal is accepted, it might be worth reconsidering this decision and include the final newline in the literal. For example, it would allow easier concatenation of multi-line strings:

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

### Warning about trailing whitespace in multi-line strings

During the implementation of SE-0168, it was decided not to warn about trailing whitespace in multi-line strings. One of the reasons brought up was that the only way to silence the warning was with a no-op character sequence at the end of the line; the only option back then was `\("")`, which is less than ideal. With this proposal, a slightly more elegant solution is now available: `\n\`.

## Source compatibility

As this proposal is additive proposing a syntax that is not currently allowed in Swift this does not affect existing source.

## Effect on ABI stability

This proposal does not affect ABI stability.

## Effect on API resilience

This proposal does not affect ABI resilience.

## Alternatives considered

It has been heavily debated between the authors of the proposals wether newline escaping should be supported in single-line strings. One argument against it is that the lack of indentation stripping in single-line strings forces strings to include no indentation, hindering the readability of code by visually breaking scopes when returning the column 1:

```swift
class Messager {
    let defaultMessage = "This is a long string that will wrap over multiple \
lines. Because we don't strip indentation like with multi-line strings, the \
author has no choice but to remove all indentation."

    func send(message: String?) {
        precondition(message == nil || !message!.isEmpty, "You can't send an \
empty message, it has no meaning.")
        print(message ?? defaultMessage)
    }
}
```

Another counter-argument is that further proposals might come up to fix this problem by introducing indentation stripping to single-line strings, muddying the distinction between single and multi-line strings.
