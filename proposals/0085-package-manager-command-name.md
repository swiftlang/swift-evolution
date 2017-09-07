# Package Manager Command Names

* Proposal: [SE-0085](0085-package-manager-command-name.md)
* Authors: [Rick Ballard](https://github.com/rballard), [Daniel Dunbar](http://github.com/ddunbar)
* Review Manager: [Daniel Dunbar](http://github.com/ddunbar)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/017728.html)
* Implementation: [apple/swift-package-manager#364](https://github.com/apple/swift-package-manager/pull/364)

## Note

This proposal underwent some minor changes from its original form. See the end
of this document for historical information and why this proposal changed.

## Introduction

This is a proposal for changing the command names used for invoking the
Swift package manager. Instead of hanging all functionality off of `swift build`
and `swift test`, we will introduce a new `swift package` command with multiple
subcommands. `swift build` and `swift test` will remain as top-level commands due to
their frequency of use.

[Swift Build Review Thread](https://lists.swift.org/pipermail/swift-build-dev/Week-of-Mon-20160509/000438.html)

[Swift Evolution Review Thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/016931.html)

## Motivation

When we introduced the package manager, we exposed it with the `swift build`
top-level command. This made clear its tight integration with Swift, and made it
discoverable (it's just a subcommand of Swift). We also added a top-level `swift test`
command for running tests. As the functionality of the package manager has grown beyond
basic build and test functionality, we've introduced other operations you can perform,
such as initializing a new package or updating existing packages.
These new commands have been supported via flags to `swift build`, but this is awkward;
these are not really flags modifying a build, and should be full commands in their own right.

The intent of this proposal is to establish a forward-looking syntax for supporting
the full range of future package manager functionality in a clean, expressive, and
clear manner, without using command-line flags (which should be modifiers on a commmand)
to express commands.

## Proposed solution

Our proposed solution is as follows:

1. Introduce a new top-level `swift package` command. This command will have
   subcommands for the package manager functionality.

2. Move existing package manager commands, such as `swift build --init`, to be
   subcommands of `swift package`, e.g. as `swift package init`. New commands
   we add, such as the `update` command, should also be added as subcommands,
   e.g. `swift package update`. Note that some current `swift build` flags
   are actually modifiers to a build command, such as `--configuration`; these will
   remain as flags instead of becoming `swift package` subcommands.

3. Introduce `swift package build` and `swift package test` subcommands, for the
   existing build and test functionality, but retain `swift build` and `swift test`
   as top-level commands which alias to these subcommands.

## Detailed design

Swift will remain a multitool whose package manager commands call through to a tool
provided by the package manager. Currently there are two tools -- `swift-build` and 
`swift-test` -- but these will be replaced by a new `swift-package` tool. This tool
is essentially an implementation detail of the package manager, as all use is expected
to be invoked through the Swift multitool.

The `swift package` command of the Swift muiltitool will call
`swift-package`. The top- level commands `swift build` and `swift test` will
call `swift-package build` and `swift-package test` respectively, although this
is considered an implementation detail and the recommend way to invoke the build
or test processes is always as a direct subcommand of `swift`. Subcommands of
`swift package` will be passed to `swift-package` verbatim.

The current `--init`, `--fetch`, `--update`, and `--generate-xcodeproj` flags to `swift build`
will become subcommands of `swift package`. The other flags to `swift build` actually
do modify the build, and will remain as flags on the `build` subcommand. New functionality
added to the package manager will be added as subcommands of `swift package` if they
are appropriate as standalone commands, or as a flag modifying an existing subcommand,
such as `build`, if they modify the behavior of an existing command.

The flags to `swift build` that are being removed will remain for a short time after
the new `swift package` subcommands are added, as aliases to those subcommands,
for compatibility. They will be removed before Swift 3 is released.

We acknowledge the possible need for a shorter version of the `swift package`
command, and believe we can revisit this to add a shorter alias for this in the
future if necessary. See the alternatives section below.

## Impact on existing packages

This has no impact on the existing packages themselves, but does have impact on any
software which invokes the `swift build` flags which are moving to
be subcommands of `swift package`. There will be a transitionary period where
both old and new syntax is accepted, but any software invoking this functionality
will need to move to the new `swift package` subcommands before Swift 3 is released.

## Alternatives considered

This proposal originally suggested `swift build` and `swift package build` would
be aliases. In order to avoid having multiple ways to run the same command, we
updated the proposal to emphasize only `swift build`.

We considered using `swift build` as the top level command for the package
manager and moving the other verbs from being flags to being subcommands of
`swift build`, instead of introducing a `package` command (e.g., `swift
build init`). We think this reads poorly and is less clear than making them `package`
subcommands.

We considered adding a `swift pm` subcommand instead of using `swift package`. That
requires less typing, but we think that spelling out the word `package` aligns better
with Swift naming conventions. Furthermore, the most common subcommands (`build`
and `test`) are exposed directly off of `swift`, limiting how often you will need to
type `package`.

We considered adding a `spm` command. However, this was regarded as too short to
ever be the definitive name, when means it would only ever be an alias. This
means that there would be two ways of doing things, which was something we
wanted to strongly avoid. We also felt that the "shortcut" of `spm` over
`swiftpm` was not in line with our overall goals, and so we focused on the
`swiftpm` alternative as discussed below.

### Using `swiftpm` as the command name

We considered adding a top-level `swiftpm` tool instead of keeping the package
manager as a subcommand of Swift. We discussed this option at length, as it was
regarded as the most compelling alternative to `swift package`. The perceived
advantages of this approach were:

* It would cement the name of the package manager clearly (as `swiftpm`), and it
  gave a clear identity useful for web searches, documentation, internal naming,
  etc.

* It included "package manager" in the name (as an acronym), which makes
  commands which are exclusive to the "package management" part of the problem
  domain more clear. For example, the behavior of `swiftpm install` is intuitive
  once one understands the name.

* It is short and convenient to type.

In the end, we rejected this alternative for several reasons:

1. We felt very strongly that there needed to be only typical one way of doing
   things, and so we felt that we needed to choose between `swiftpm` and `swift
   package` (and not simply add it as an alias). Our belief was this was more
   important than any individual advantages or disadvantages to either name.

2. While there was significant feedback requesting a shorter command name, we
   were concerned that the feedback was not necessarily representative of the
   overall user base we hope to impact. For example, we hope the Swift package
   manager will be widely used by less experienced developers who may only run
   the `swift package` commands rarely, and will benefit from the explicit
   nature of the commands over brevity.

3. If we used this as the command, then it raises a difficult question of `swift
   build` versus `swiftpm build`. We wanted to retain the "natural" feel of the
   package manager as being integrated with the language, and keep `swift
   build`, but we had substantial difficulty articulating the exact reasons why
   it made sense for some commands (e.g., `swift build` and `swift test`) to be
   subcommands of `swift`, and others to be subcommands of `swiftpm`.

   In the end, we were unable to come to a consensus on this question, so we
   ended up regarding this as a reason to choose `swift package` instead, which
   side steps this question.

4. We believe that the readability and clarity of using consistent,
   unabbreviated commands was more in line with the Swift language than
   attempting to use a "shorter" command name. Our belief is that `swift
   package` will primarily be used for commands which are not commonly executed,
   and we think that the package manager is more discoverable, and its role in
   the Swift ecosystem more clear, with it as a Swift subcommand.

5. We believe that we can always choose to install a `swiftpm` alias for `swift
   package` if our needs or justification changes, whereas going in the other
   direction was considered undesirable.
