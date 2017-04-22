# Feature name

* Proposal: [SE-0173](0173-newline-escape-in-strings.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: TBD
* Status: **Awaiting review**

* Previous Proposal: [SE-0168](0168-multi-line-string-literals.md)

## Introduction

This is a lightning proposal intended for quick review for which an implementation
is already available. During review of [SE-0168](0168-multi-line-string-literals.md)
it was felt that the feature of escaping a newline to elide it from the literal should
not be accepted as it would introduce an inconsistency with respect to conventional
string literals. This proposal suggests that it should be a part of both syntaxes
which would also bring Swift strings into line with the behaviour of C literals.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170417/035923.html)

## Motivation

Newline continuation was an integral part of the design of multiline string literals
so they could serve dual purpose as multiline literals but also as bulk literals for text
the user does not want to contain newlines but that should be split over a number
of lines in the source for legibility. For example:

```
        let text = """
            Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
            tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
            quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.\
            """
```

Accepting the proposal without it has meant no way could be found to easily escape
the last newline of a literal and as a result it was decided that it should always
be stripped. This has reduced the intuitiveness and usability of the feature in the
opinion of the author although this is the subject of some debate. This aside, having
a continuation character is useful in its own right in formatting source, is
precedented and carries very little risk of confusion for the naive user. Indeed,
when I started using Swift this is something I expected to be able do.

## Proposed solution

In order to enter long string literals that do not contain newlines it should
be possible to extend the string past the end of the line using an escape character
\ before the newline and have the string continue on the next line. The newline
character would not be included in the literal.

## Detailed design

This would be a very small change confined to Lexer.cpp that would be very limited in scope.

## Source compatibility

As this proposal is additive proposing a syntax that is not currently
allowed in Swift this does not affect existing source.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A Additive proposal

## Alternatives considered

Some would suggest using concatenation but past a certain point this becomes 
clumsy and as the expression becomes more complex, it can take a long time
for the swift compiler to analyse.