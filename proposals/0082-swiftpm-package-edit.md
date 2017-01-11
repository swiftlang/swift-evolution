# Package Manager Editable Packages

* Proposal: [SE-0082](0082-swiftpm-package-edit.md)
* Author: [Daniel Dunbar](https://github.com/ddunbar)
* Review Manager: [Anders Bertelrud](https://github.com/abertelrud)
* Status: **Implemented (Swift 3.1)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160509/017038.html)

## Introduction

This is a proposal for changing the behavior for iterative development of a
group of packages. In particular, we will change the default location to which
package dependency sources are cloned, the package managers behavior around
those sources, and add a new feature for allowing iterative development. These
features are tightly interrelated, which is why they are combined into one
proposal.

[Proposal Announcement](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015686.html)

[Review announcement](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160502/016502.html)


## Motivation

We would like the package manager to support the following two workflows:

1. In general, we would like to guarantee the most deterministic behavior
   possible when building a package, so that other users of the package or
   deployment scenarios see the same behavior as the developer. We would also
   like builds to be as efficient as possible, to improve developer
   productivity.

   For these reasons, it is desirable for the package manager to have a very
   strong default consistency model with regard to package dependencies, where
   it actively tries to ensure that the correct version of the sources is being
   used when a developer expects to be building against a particular tag of a
   package.

   For that reason, the default behavior should be an error or warning if a
   developer unintentionally tries to build against a modified version of a
   package, without otherwise specifying their intent.

2. We would like to support productive development on projects which depend on a
   number of packages, including development of those upstream packages.

   This is important for projects whose authors directly control multiple
   packages, but also simply to encourage users to contribute changes back to
   the packages they are using, or factor their code into packages others can
   use.

Currently, the package manager always checks out sources into a subdirectory
adjacent to the project package called `Packages`, under a name combining the
package name and tag. Users can directly edit the sources in that directory and
they will be picked up by the build, but for a package author that is unlikely
to be the directory they wish to edit their repository at (it will likely be
checked out into a canonical location). In addition, the `git` repository at
that point will be on a tag, which is an uncommon place to do iterative
development. The user could choose to switch the branch they are working on, but
then there is a confusing inconsistency between the directory name (which embeds
the tag) and the content.

In addition, the package manager naturally needs to support other operations
which interact with the dependency package sources, such as updating them to a
newer version. Directly supporting a user editing these sources requires the
package manager to resolve difficult workflow questions about how to resolve the
intended user action with the current contents of the tree.


## Proposed solution

Our proposed solution is as follows:

1. Move the default location for checked depencency sources to be "hidden" (an
   implementation detail). The package manager build system will by default try
   to ensure that any normal build always runs against the exact sources
   specified by the tag which was selected by dependency resolution.

2. Introduce a new feature `swift build --edit <PACKAGE>` which takes an
   existing dependency, and converts it into an editable dependency (by moving
   it into the existing location within the `Packages` subdirectory).

   If a such an editable package is present in `Packages`, then `swift build`
   will always use the exact sources in this directory to build, regardless of
   it's state, git repository status, tags, or the tag desired by dependency
   resolution. In other words, this will "just build" against the sources that
   are present.

   When an editable package is present, it will be used to satisfy all instances
   of that Package in the depencency graph. It should be possible to edit all,
   some, or none of the packages in a dependency graph, without restriction.

This solution is intended to directly address the desired behaviors of the
package manager:

* By hiding the sources by default, we minimize the distractions in the common
  case where a user is programming against a known, well-establised, library
  they do not need to modify.

* By adding a new, explicit workflow for switching to an "editable" package, we
  hope it is more explicit when a user is building against a canonical set of
  package versions versus a packages which may have been modified.

We defined this feature in terms of behavior of `swift build` -- as opposed to
changes to a "lockfiles" or "package pinning" mechanism -- because the
expectation is that the decision to use an editable version of a Package versus
the canonically resolved version is ultimately up to the individual
developer. We do not yet have a clear feature for supporting the situation where
a team of developers typically wants to edit the same group of packages (e.g.,
all the ones they own), but anticipate that this mechanism can evolve to support
that.

This feature also gives us a new place to add workflow behaviors to help make
the interactions with editable packages safer or more flexible. For example, the
following are possible features for future extension:

* We could infer (or allow user specification of) the next semantic version that
  the editable package will be. We could then build the package graph "as if"
  the package being edited had been tagged with this version. This would allow
  us to ensure that the package graph builds the same as it does for the
  developer when they commit and tag the package under development.

* We can provide additional features to leave editable mode, which could include
  a variety of safety checks that the changes had been committed, pushed, and
  tagged, in a way appropriate for the project under development.

* We could provide a feature to notify the developer when the editable packages
  have changes to the project metadata which may interact poorly with other
  editable packages. For example, trying to modify package dependency tags for a
  package which is in an editable state should most likely produce a warning,
  since the impact of those changes will not be reflected by the build.


## Detailed design

Concretely, we will take the following steps:

1. We will initially move the package clones into the existing `.build`
   directory, and provide a new explicit command line action `swift build
   --get-package-path <PACKAGE>` to get the package path in a supported
   manner. This allows us to transparently move the cache to a shared location
   if that becomes desirable.

2. When resolving the package graph, we will load all of the repositories
   present in `Packages`, and use those repositories as replacements for any
   packages in the graph with the same *package name*. We will not audit the
   repository origin, initially, to allow for developing package graphs which
   are have not yet been pushed to any server.

3. We will **not** load editable packages from any package other than the root
   package (i.e., we will ignore the presence of `Packages` anywhere except for
   the root package).

4. We will introduce the `--edit <NAME>` subcommand. The package named **must
   be** an existing package in the graph. The behavior will be to take the exact
   tag that would have been chosen via dependency resolution, and clone that
   repository to `Packages/<NAME>` checked out to the tag.

   The desired invariant here is that the following sequence (starting from
   having no editable dependencies):
   ```
   swift build
   swift build --edit <NAME>
   swift build
   ```
   have the exact same results for each build step.

5. We would like to introduce a `--end-edit <NAME>` subcommand (exact name is
   TBD), which will revert the package manager to the behavior of using the
   canonically resolved package.

   As described, this will require removing the `Packages/<NAME>` checkout. We
   need to be very careful about doing this, but this also gives us a good
   opportunity to communicate to the user if the state on the repository they
   are editing has not been pushed back into what would be the canonically
   resolved package.

   We will most likely defer this feature from the initial implementation and
   document that users can `rm -rf Packages/<NAME>` to stop editing, until the
   feature is introduced.

6. We *may* introduce a metadata file to record the project state and what
   packages are editable. This would potentially allow us to provide better
   diagnostics to the user, it would also allow us to record an alternate
   location for the editable package. The latter would be useful when an author
   is developing multiple independent projects that they keep in a canonical
   location on their file system, and would like other packages to refer to for
   iterative development. Initially, that behavior can be emulated using
   symbolic links within the `Packages` directory.

   If such a file is introduced, the file system representation of the editable
   packages will always be the "canonical" source of data, and the metadata file
   will simply be used for additional diagnostics or information which cannot be
   inferred from the file system.

7. We will consider a `swift build --edit-all` flag for immediately moving all
   packages to editable mode.


## Impact on existing packages

This is a substantial behavior change for existing package checkouts, which will
be seen by `swift build` as having a lot of editable packages with names not
matching anything in the graph. We should consider detecting and warning about
this situation as part of a transitional mechanism. In fact, this may motivate
us to provide a way within the package manager to detect what the last version
of the package manager used inside a project was, so that we can enable
migration type behaviors automatically.


## Alternatives considered

There has been discussion about using additional metadata from whatever
mechanism we use to support package pinning/lockfiles to enable the iterative
development workflows. The motivation for this proposal was in part based on the
difficulties in defining the exact semantics for package pinning in conjunction
with the existing semantics around the `Packages` directory.

We have discussed whether or not hiding the sources for non-editable packages is
the right default. The motivation for hiding the sources is that in a large,
mature, stable ecosystem there are likely to be a large number of packages
involved in any particular project build, and many of those are likely to be
uninteresting to the package developer. In particular, while a project developer
might be interested in the source of their direct dependencies, the sources of
that packages own dependencies is an "implementation detail" from the
perspective of the project developer.

The downside of hiding sources by default is that it adds extra hoops for
developers to go through to see those sources. In practice, we anticipate a
workflow where a developer can easily transition between `--edit` and
`--end-edit` efficiently if they need to easily inspect sources for one-off
instances. For long-lived requirements (for example, needing to access a
packages documentation), we anticipate that this problem will be solved by other
mechanisms (for example, web hosted documentation or other mechanisms for
browsing the source).

We will revisit this default behavior if it proves problematic, and implement
this feature with the flexibility to easily change the default.
