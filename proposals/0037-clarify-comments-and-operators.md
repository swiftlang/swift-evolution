# Clarify interaction between comments & operators

* Proposal: [SE-0037](https://github.com/apple/swift-evolution/blob/master/proposals/0037-clarify-comments-and-operators.md)
* Author(s): [Jesse Rusak](https://github.com/jder)
* Status: **Scheduled** for March 2...4, 2016
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

There are several inconsistencies in how comments are treated when determining
whether an operator is prefix, postfix, or infix. They are sometimes treated
as whitespace, sometimes as non-whitespace, and this differs depending on
whether they are to the left or right of an operator, and the contents of
the comment itself. This proposal suggests a uniform set of rules for how these
cases should be parsed.

Swift-evolution thread: [started here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003780.html)
and [continued here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/003913.html)
and [continued here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/004646.html).
And finally [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/006030.html).

A draft implementation is [available here](https://github.com/apple/swift/compare/master...jder:comment-operator-absent).

## Motivation

At the moment, comments next to operators are usually treated as
non-whitespace for the purpose of [determining whether an operator is prefix/postfix/binary](https://developer.apple.com/library/mac/documentation/Swift/Conceptual/Swift_Programming_Language/LexicalStructure.html#//apple_ref/doc/uid/TP40014097-CH30-ID418),
meaning that this fails to compile ([SR-186](https://bugs.swift.org/browse/SR-186)):

```swift
if /* comment */!foo { ... }
```

Because the "!" is parsed as binary operator (no whitespace on either side),
rather than as a prefix operator, which seems undesirable. This behavior is also
not consistently applied. For example, this currently works:

```swift
1 +/* comment */2
```

Because the "`+/*`" is treated as one token and sees the whitespace to its
right and left, and so is parsed as a binary operator. 

In order to resolve these and related issues, this proposes a general rule about
the expected behavior.

## Proposed solution

Comments should be treated as absent for all of the purposes in the “operators”
section of the swift language reference: determining whether an operator is
binary, prefix, or postfix, as well as the special rules around the “!” and “?”
predefined operators. In other words, operators should "see through" a comment
to the characters on the other side.

This means that adding a comment next to an operator (including between
it and its operand) should not change whether the operator is treated as prefix,
postfix, or binary, regardless of the contents of the comment.

For example, these should all be equivalent:

```swift
if !foo { ... }
if /* comment */!foo { ... }
if !/* comment */foo { ... }
```

As should these:

```swift
// whitespace on both sides
1 + 2
1 +/* comment */ 2

// no whitespace on either side
1+/*comment*/2
1+/* comment
 comment */2
```

This is a predictable model, and is intended to be as unsurprising as
possible, especially to beginners that are not used to troubleshooting parse
errors.

## Detailed design

When parsing an operator character and trying to determine whether it has a 
whitespace character to either the right or left, we should skip
comments (both possibly-nested slash-star comments, and slash-slash comments). 
The contents of the skipped comments (e.g. whether they include
newlines) should have no effect on this determination.

For this purpose, slash-slash comments should be treated as extending up to but
not including the trailing newline character (if present). So, for example,
this should be treated as a postfix "~" operator:

```swift
let a = foo~// comment
bar()
```

The newline character after the end of the comment means the "~" has whitespace
to its right, not `bar`. On the other hand, this should be parsed as a
binary operator:

```swift
let a = foo~/* commment
*/bar()
```

As the newline appears only within the comment. (Note that this only matters
for operators other than "!" and "?" because of their special rules.)

The language reference should also be updated to make clear that comments are
ignored for these purposes.

## Impact on existing code

Only code with comments immediately next to operators will be affected. This is
not expected to be very common, and could be fixed by adding/removing whitespace
or moving the comment outside of the expression. It would probably be possible
to produce fix-its for these. Here are some examples of the changes.

Some cases which would previously work will now produce an error 
(these are breaking changes):

```swift
1 /* */+2
1 +/* comment */2
1+/*comment*/ 2
```

Some cases which were previously errors will now work:

```swift
/* */!foo
!/* */foo

1+/* */2
1 /**/+ 2
```

Examples of things which will continue to be errors:

```swift
1/**/+ 2
1 +/*comment*/2
```

And things which will continue to work:

```swift
foo!// comment
foo/* */?.description
foo/* */!

1 +/**/ 2
1/**/+2
1+/**/2
```

## Alternatives considered

### Treat comments as whitespace

We could instead specify that comments are treated as whitespace. This is a 
simpler rule, and it avoids some extra complications described above around
slash-slash comments and multi-line slash-star comments. It is also easier for
both the lexer and a human reader to determine whether an operator is binary
or not, since if comments are always whitespace, you don't have to scan to
the other side of a long comment to tell whether an operator has whitespace
around it. For example:

```swift
1 +/* a very long comment */2
```

With the proposed changes, you can't tell just by looking near the “+” whether
it is a binary or prefix operator. 

On the other hand, this goes against the common mental model that comments are
ignored when parsing. As a result, this is somewhat more surprising rule. This
rule is also less flexible; that is, there are places which this completely
prohibits comments which are permitted by the above proposal. (e.g. `!/* */foo`)

### A more general rule

Another alternative is a more general rule about how comments are handled
everywhere in the language (e.g. there must be no effect when replacing a
comment with a space character). This has the advantage of possibly resolving
other ambiguities, but has potentially far-reaching consequences in various
edge cases which are hard to fully enumerate (e.g. multi-line comments, 
comments within interpolated sequences inside of string literals, comments
in lines which contain "#" directives, etc). 