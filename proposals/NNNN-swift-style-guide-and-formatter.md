# Swift Code Style Guidelines and Formatter

* Proposal: [SE-NNNN](NNNN-swift-style-guide-and-formatter.md)
* Authors: [Tony Allevato](https://github.com/allevato), [Dave Abrahams](https://github.com/dabrahams)
* Review Manager: TBD
* Status: **Awaiting discussion**

## Introduction

We propose that the Swift project adopt a set of code style
guidelines and provide a formatting tool that lets users easily
diagnose and update their code according to those guidelines.

## Motivation

At the time of this writing, there is no single style agreed on
by developers using Swift. Indeed, even Apple's own Swift
projects on GitHub—such as the standard library, Foundation,
Swift NIO, and so forth—have adopted their own varying styles.
Furthermore, in many cases the code in those projects—despite
the owners' best efforts—is not always completely consistent in
terms of style.

In the absence of strict or recommended language-specific
guidelines, many organizations adopt company-wide or project-wide
style guides, which other developers may, and do, choose to
adopt. But creating code style guidelines that are maintained by
the language owners and community, along with tooling that allows
users to easily adopt those guidelines, provides a number of
additional benefits:

1. The guidelines serve as a clear and easily referenceable
   source of language best practices and patterns, rather than
   developers trying to glean these by reading existing code.
1. Developers can move from one codebase to another without
   incurring the mental load of learning and conforming to a
   different style or being required to reconfigure their
   development environment.
1. Developers spend less time worrying about how to format their
   code and more on the program's logic.
1. Likewise, code reviewers spend less time commenting on code
   formatting issues and more on its logic and design.

The first two points in particular align well with the Swift
team's goal of making the language easy to learn. They also
remove learning barriers for developers who want to contribute
to a new open-source project, or to the language itself.

## Proposed solution

This proposal consists of two parts, discussed below:

1. We propose that Swift adopt a set of code style guidelines for
   the Swift language.
2. We propose formally adopting a formatting tool into the Swift
   project that will allow users to update their code in
   accordance with those guidelines.

### Style Guide

This meta-proposal does not attempt to define any specific style
guidelines. Its purpose is to answer the following existential
question:

> Should the Swift language adopt a set of code style guidelines
> and a formatting tool?

If the answer to this is "yes", then a **subsequent proposal**
will be pitched to discuss and ratify those guidelines.

The proposal authors wish to emphasize that **we are not
proposing that users be required or forced** to use a particular
set of style conventions. The Swift compiler will **not** be
changed in any way that would prevent otherwise syntactically
valid code from compiling. Users who wish to reject the style
guidelines and adopt a different style for their own projects are
free to do so without the tooling pushing back on that decision.

### Formatting Tool

If the proposal is accepted, the Swift project will adopt an
official code formatting tool. The adoption of such a tool into
the Swift project will not preclude other similar tools being
written, but the expectation is that this tool will be officially
maintained as part of the Swift project and will (once the
details are decided) format users' code in accordance with the
accepted code style guidelings.

The proposal authors ([among others](#acknowledgments)) have
collaborated on the `swift-format` tool currently hosted at
https://github.com/google/swift/tree/format and intend to propose
its adoption into the Swift project.

The tool will be used as part of evaluating options for the
proposed code style guidelines, as part of a follow-up proposal on
the details of the guidelines themselves.

As with the style guidelines above, the adopted formatting tool
will not be forced upon a developer's workflow by any part of the
Swift toolchain. Users who wish not to use it will have the
option to simply not run it on their code.

## Alternatives considered

One alternative would be to not propose any particular style
guidelines and leave it to individual developers and teams to
create their own (if they so desired). That, of course, does not
address the points listed in [Motivation](#motivation) above.

Some Swift users have suggested that instead of proposing any
style guidelines, tooling should be able to transform code
to the developer's personal style upon checkout and then back to
some canonical style upon check-in, allowing individual
developers to code in whatever style they wished. While such
ideas are intriguing, we find them to be more of an academic
curiosity than a practical solution:

* Varying personal styles would hinder team communication. Team
  members should be able to discuss code on a whiteboard without
  it looking foreign to other people in the room, and to make
  API and language design decisions based on a clear idea of how
  the code will look.
* This approach assumes that all tools on all platforms used in
  the developer's workflow support this approach. The development
  experience would suffer if the code does not use the same
  format locally as it does on their code review system, if
  remote builds reported errors at different line numbers because
  they used a checked-in snapshot with a different style, or if
  symbolicated crash logs contain line numbers that must be
  matched to one specific "rendering" of the project's source
  code long after the fact.
* If the source of truth of the source code is saved in some
  canonical format and transformed when checked in/out, then
  there must still be some decision about what that canonical
  style _is._

Indeed, nothing in this proposal would _prevent_ a developer from
using a workflow like the one described above, if they wished to
implement it.

## Acknowledgments

We gratefully acknowledge the following contributors, without
whom this work would not have been possible:

* the other contributors to `swift-format`: Austin Belknap
  ([@dabelknap](https://github.com/dabelknap)),
  Harlan Haskins ([@harlanhaskins](https://github.com/harlanhaskins)),
  Alexander Lash ([@abl](https://github.com/abl)),
  Lauren White ([@LaurenWhite](https://github.com/LaurenWhite)),
  and Andrés Tamez Hernandez ([@atamez31](https://github.com/atamez31)),
* Argyrios Kyrtzidis ([@akyrtzi](https://github.com/akyrtzi)) for
  his insight and help on using SwiftSyntax,
* and Kyle Macomber ([@kylemacomber](https://github.com/kylemacomber)),
  who advocated for using results of existing research for
  `swift-format`'s implementation and found the Oppen paper,
  instead of inventing solutions from whole cloth.
