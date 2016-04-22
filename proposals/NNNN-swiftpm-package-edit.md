# Package Manager Editable Packages

* Proposal: SE-NNNN
* Author(s): [Daniel Dunbar](https://github.com/ddunbar)
* Status: **Under construction**
* Review manager: Rick Ballard

## Introduction

This is a proposal for changing the behavior for iterative development of a
group of packages. In particular, we will change the default location to which
package dependency sources are cloned, the package managers behavior around
those sources, and add a new feature for allowing iterative development. These
features are tightly interrelated, which is why they are combined into one
proposal.


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

This also gives us a new place to add workflow behaviors to help make the
interactions with editable packages safer or more flexible. For example, the
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

   The desired invariant here is that the following sequence:
   ```
   swift build
   swift build --edit <NAME>
   swift build
   ```
   have the exact same results for each build step.

5. We *may* introduce a metadata file to record the project state and what
   packages are editable. This would potentially allow us to provide better
   diagnostics to the user, it would also allow us to record an alternate
   location for the editable package. The latter would be useful when an author
   is developing multiple independent projects that they keep in a canonical
   location on their file system, and would like other packages to refer to for
   iterative development. Initially, that behavior can be emulated using
   symbolic links within the `Packages` directory.


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
