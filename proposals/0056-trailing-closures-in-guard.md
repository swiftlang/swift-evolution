# Allow trailing closures in `guard` conditions

* Proposal: [SE-0056](0056-trailing-closures-in-guard.md)
* Author: [Chris Lattner](https://github.com/lattner)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-April/000108.html)

## Introduction and Motivation

Swift-evolution thread: ["Allow trailing closures in 'guard' conditions"](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013141.html)

The three statements `if`, `while`, and `guard` form a family that all take a
rich form of conditions that can include one or more boolean conditions,
`#available` clauses, and `let`/`case` pattern bindings.  These are described by
the `condition-clause` production in the TSPL reference section and as a
`stmt-condition` in the compiler source code.

Today, these do not permit trailing closures in any top-level expressions 
embedded in the condition, because that would be generally ambiguous with the
body of an `if` or `while` statement:

```Swift
if foo {   // start of trailing closure, or start of the if body?
```

While it would be possible to tell what is intended in some cases by performing
arbitrary lookahead or by performing type checking while parsing, these
approaches have significant consequences for the architecture for the compiler.
As such, we've opted keep the parser simple and disallow this.  Unrelated to
this proposal, [a recent patch in Swift 3](https://github.com/apple/swift/commit/30ec0f4128525a16f998e04ae8b1f70180627446) *greatly* improves the
error messages in some of the most common cases where a developer accidentally
tries to do this. 

However, while this approach makes sense for `if` and `while` statements, it
does not make sense for `guard`: The body of a `guard` statement is delineated by
the `else` keyword, so there is no ambiguity.  A brace is always the start of a
trailing closure.

From a historical perspective, the current situation was an oversight.  An 
earlier design for `guard` did not include the `else` keyword (it used the
`unless` keyword), and I forgot to eliminate this requirement when we decided to
resyntax it to `guard/else`. 


## Proposed solution

The solution is simple: allow trailing closures in guard bodies.  As one
example, it would allow this example (adapted from the "Advanced Swift" book) to
compile correctly:

```swift
guard let object = someSequence.findElement { $0.passesTest() } else {
  return
}
```

## Detailed design

The compiler change to do this is extremely straight-forward, the patch is
[available here](https://lists.swift.org/pipermail/swift-evolution/attachments/20160322/50c40166/attachment.obj).

## Impact on existing code

There is no impact on existing code.  This only makes formerly invalid code
start being accepted.

## Alternatives considered

There are four primary alternatives:

 * *Do nothing*: It can be argued that this change would make `guard` inconsistent
   with the restrictions of `if` and `while` and that inconsistency would be
   confusing.  On the other hand, I am arguing that this is an arbitrary
   restriction.

 * *Expand the scope of `if` and `while` statements*:  Through enough heroics
   and lookahead we could consider relaxing the trailing closure requirements on
   `if` and `while` statements as well.  While this could be interesting, it
   raises several ambiguity questions, which makes it non-obvious that it is the
   right thing to do.  In any case, since this expansion would
   be compatible with this proposal, I see it as a separable potential extension
   on top of this basic proposal.

 * *Change the syntax of `guard`*: I only list this for completeness, but we
   could eliminate the `else` keyword, making `guard` more similar to `if` and 
   `while`.  I personally think that this is a really bad idea though: the 
   `guard` statement is not a general `unless` statement, and its current syntax
   was very very carefully evaluated, iterated on, discussed, and re-evaluated
   in the Swift 2 timeframe.  I feel that it has stood the test of time well
   since then.

 * *Change the syntax of `if` and `while`*: Brent Royal-Gordon points out that
   we could change `if` and `while` to use a keyword after their condition as
   well, e.g.:

```swift
if expr then {
while expr do {
for elem in expr do { code }
switch expr among { code }
```

   This would make it easy to support trailing closures in if and while, but it
   has some disadvantages: it takes a new keyword (`then`), it diverges
   unnecessarily from the rest of the C family of languages.

## Rationale

On April 20, 2016, the core team decided to **reject** this
proposal. The core team felt that the benefits from this change were
outweighed by the inconsistency it would introduce with `if` and
`while`.
