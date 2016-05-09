# Package Manager Command Names

* Proposal: [SE-0085](0085-package-manager-command-name.md)
* Author(s): [Rick Ballard](https://github.com/rballard)
* Status: **Scheduled for review: May 9...12, 2016**
* Review manager: [Daniel Dunbar](http://github.com/ddunbar)

## Introduction

This is a proposal for changing the command names used for invoking the
Swift package manager. Instead of hanging all functionality off of 'swift build'
and 'swift test', we will introduce a new 'swift package' command with multiple
subcommands. 'swift build' and 'swift test' will remain as top-level commands due to
their frequency of use.

## Motivation

When we introduced the package manager, we exposed it with the 'swift build'
top-level command. This made clear its tight integration with Swift, and made it
discoverable (it's just a subcommand of Swift). We also added a top-level 'test'
command for running tests. As the functionality of the package manager has grown beyond
basic build and test functionality, we've introduced other operations you can perform,
such as initializing a new package or updating existing packages.
These new commands have been supported via flags to 'swift build', but this is awkward;
these are not really flags modifying a build, and should be full commands in their own right.

The intent of this proposal is to establish a forward-looking syntax for supporting
the full range of future package manager functionality in a clean, expressive, and
clear manner, without using command-line flags (which should be modifiers on a commmand)
to express commands.

## Proposed solution

Our proposed solution is as follows:

1. Introduce a new top-level 'swift package' command. This command will have
   subcommands for the package manager functionality.

2. Move existing package manager commands, such as 'swift build --init', to be
   subcommands of 'swift package', e.g. as 'swift package init'. New commands
   we add, such as the 'update' command, should also be added as subcommnads,
   e.g. 'swift package update'. Note that some current 'swift build' flags
   are actually modifiers to a build command, such as '--configuration'; these will
   remain as flags instead of becoming 'swift package' subcommands.

3. Introduce 'swift package build' and 'swift package test' subcommands, for the
   existing build and test functionality, but retain 'swift build' and 'swift test'
   as top-level commands which alias to these subcommands.

## Detailed design

Swift will remain a multitool whose package manager commands call through to a tool
provided by the package manager. Curently there are two tools -- 'swift-build' and 
'swift-test' -- but these will be replaced by a new 'swift-package' tool. This tool
is essentially an implementation detail of the package manager, as all use is expected
to be invoked through the Swift multitool.

The 'swift package' command of the Swift muiltitool will call 'swift-package'. The top-
level commands 'swift build' and 'swift test' will call 'swift-package build' and
'swift-package test' respectively. Subcommands of 'swift package' will be passed to
'swift-package' verbatim.

The current '--init', '--fetch', '--update', and '--generate-xcodeproj' flags to 'swift build'
will instead become subcommands of 'swift package'. The other flags to 'swift build' actually
do modify the build, and will remain as flags on the 'build' subcommand. New functionality
added to the package manager will be added as subcommands of 'swift package' if they
are appropriate as standalone commands, or as a flag modifying an existing subcommand,
such as 'build', if they modify the behavior of an existing command.

The flags to 'swift build' that are being removed will remain for a short time after
the new 'swift package' subcommands are added, as aliases to those subcommands,
for compatibility. They will be removed before Swift 3 is released.

## Impact on existing packages

This has no impact of the existing packages themselves, but does have impact on any
software which invokes the 'swift build' flags which are moving to
be subcommands of 'swift package'. There will be a transitionary period where
both old and new syntax is accepted, but any software invoking this functionality
will need to move to the new 'swift package' subcommands before Swift 3 is released.

## Alternatives considered

We considered adding a top-level 'swiftpm' tool instead of keeping the package manager
as a subcommand of Swift. We think that the package manager is more discoverable,
and its role in the Swift ecosystem more clear, with it as a Swift subcommand.

We considered adding a 'swift pm' subcommand instead of using 'swift package'. That
requires less typing, but we think that spelling out the word 'package' aligns better
with Swift naming conventions. Furthermore, the most common subcommands ('build'
and 'test;) are exposed directly off of 'swift', limiting how often you will need to
type 'package'.

We considered using 'swift build' as the top level command for the package manager
and moving the other verbs from being flags to being subcommands of 'swift build',
instead of introducing a 'package' command. We think this reads poorly and is
less clear than making them 'package' subcommands.
