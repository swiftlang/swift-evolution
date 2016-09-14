# Clarify interaction between comments & operators

* Proposal: [SE-0037](0037-clarify-comments-and-operators.md)
* Author: [Jesse Rusak](https://github.com/jder)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000066.html)
* Bug: [SR-960](https://bugs.swift.org/browse/SR-960)


## Introduction

There are several inconsistencies in how comments are treated when determining
whether an operator is prefix, postfix, or infix. They are sometimes treated
as whitespace, sometimes as non-whitespace, and this differs depending on
whether they are to the left or right of an operator, and the contents of
the comment itself. This proposal suggests a uniform set of rules for how these
cases should be parsed.

Swift-evolution thread: [started here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/006030.html)

A draft implementation is [available here](https://github.com/apple/swift/compare/master...jder:comment-operator-fixes).

[Review](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012398.html)

## Motivation

At the moment, comments next to operators are usually treated as
non-whitespace for the purpose of [determining whether an operator is prefix/postfix/binary](https://developer.apple.com/library/mac/documentation/Swift/Conceptual/Swift_Programming_Language/LexicalStructure.html#//apple_ref/doc/uid/TP40014097-CH30-ID418),
meaning that this fails to compile ([SR-186](https://bugs.swift.org/browse/SR-186)):

```
if /* comment */!foo { ... }
```

Because the "!" is parsed as binary operator (no whitespace on either side),
rather than as a prefix operator, which seems undesirable. This behavior is also
not consistently applied. For example, this currently works:

```
1 +/* comment */2
```

Because the "`+/*`" is treated as one token and sees the whitespace to its
right and left, and so is parsed as a binary operator.

In order to resolve these and related issues, this proposes a general rule about
the expected behavior.

## Proposed solution

Comments should be treated as whitespace for all of the purposes in the “operators”
section of the Swift language reference: determining whether an operator is
binary, prefix, or postfix, as well as the special rules around the “!” and “?”
predefined operators.

This means that swapping a comment with whitespace should
not change whether an adjacent operator token is treated as prefix, postfix,
or binary (regardless of the contents of the comment).
This also includes whitespace/comments between the operator and its operand.

For example, these should be equivalent:

```
if/* comment */!foo { ... }
if !foo { ... }
```

As should these:

```
// whitespace on both sides
1 + 2
1 +/* comment */2
```

This model is easy to describe, and fits in with the general rule already
present in the Swift language reference that comments are treated as whitespace.

## Detailed design

When parsing an operator token and trying to determine whether it has a
whitespace character to either the right or left, an adjacent slash-slash
or slash-star comment should be treated as whitespace. The contents of these
comments (e.g. whether they themselves include whitespace) should have no effect.

The language reference should also be updated to make clear that comments are
treated as whitespace for these purposes.

## Impact on existing code

Only code with comments immediately next to operators will be affected. This is
not expected to be very common, and could be fixed by adding whitespace
or moving the comment outside of the expression. It would probably be possible
to produce fix-its for these. Here are some examples of the changes.

Some cases which would previously work will now produce an error
(these are breaking changes):

```
foo/* */?.description
foo/* */!
1/**/+2
1+/**/2
```

Some cases which were previously errors will now work:

```
/* */!foo
1/**/+ 2
1 /**/+ 2
1 +/**/2
```

Examples of things which will continue to be errors:

```
!/* */foo
1+/* */2
```

And things which will continue to work:

```
foo!// comment

1 +/**/ 2
1 +/* */2
```

## Alternatives considered

### Treat comments as absent

We could instead specify that comments are treated as though they are not present
(i.e. we would look past comments to see whether whitespace follows).
This more-closely matches some people’s mental model of comments. It is also more
flexible; that is, there are places where this rule permits comments which are forbidden
by the above proposal. (e.g. `!/* */foo`)

However, this rule is harder to describe (the comments are not ignored entirely as
they still separate tokens) and goes against the general rule in the
language reference that comments are treated as whitespace.

This also has the disadvantage that you have to look at the other side of a
comment to determine if an operator has whitespace around it. For example:

```
a = 1 +/* a very long comment */~x
```

You can’t tell just by looking near the “+” whether it is a binary or prefix
operator. (And, in fact, this would fail to parse if the comment was simply
treated as absent.)

### A more general rule

Another alternative is a more general rule about how comments are handled
everywhere in the language (e.g. there must be no effect when replacing a
comment with a space character). This has the advantage of possibly resolving
other ambiguities, but has potentially far-reaching consequences in various
edge cases which are hard to fully enumerate (e.g. multi-line comments,
comments within interpolated sequences inside of string literals, comments
in lines which contain "#" directives, etc).
