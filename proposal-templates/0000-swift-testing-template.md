# Swift Testing Feature name

* Proposal: [ST-NNNN](NNNN-filename.md)
* Authors: [Author 1](https://github.com/author1), [Author 2](https://github.com/author2)
* Review Manager: TBD
* Status: **Awaiting implementation** or **Awaiting review**
* Bug: _if applicable_ [swiftlang/swift-testing#NNNNN](https://github.com/swiftlang/swift-testing/issues/NNNNN)
* Implementation: [swiftlang/swift-testing#NNNNN](https://github.com/swiftlang/swift-testing/pull/NNNNN)
* Previous Proposal: _if applicable_ [ST-XXXX](XXXX-filename.md)
* Previous Revision: _if applicable_ [1](https://github.com/swiftlang/swift-evolution/blob/...commit-ID.../proposals/testing/NNNN-filename.md)
* Review: ([pitch](https://forums.swift.org/...))

When filling out this template, you should delete or replace all of the text
except for the section headers and the header fields above. For example, you
should delete everything from this paragraph down to the Introduction section
below.

As a proposal author, you should fill out all of the header fields except
`Review Manager`. The review manager will set that field and change several
others as part of initiating the review. Delete any header fields marked _if
applicable_ that are not applicable to your proposal.

When sharing a link to the proposal while it is still a PR, be sure to share a
live link to the proposal, not an exact commit, so that readers will always see
the latest version when you make changes. On GitHub, you can find this link by
browsing the PR branch: from the PR page, click the "username wants to merge ...
from username:my-branch-name" link and find the proposal file in that branch.

`Status` should reflect the current implementation status while the proposal is
still a PR. The proposal cannot be reviewed until an implementation is available,
but early readers should see the correct status.

`Bug` should be used when this proposal is fixing a bug with significant
discussion in the bug report. It is not necessary to link bugs that do not
contain significant discussion or that merely duplicate discussion linked
somewhere else. Do not link bugs from private bug trackers.

`Implementation` should link to the PR(s) implementing the feature. If the
proposal has not been implemented yet, or if it simply codifies existing
behavior, just say that. If the implementation has already been committed to the
main branch (as an experimental feature or SPI), mention that. If the
implementation is spread across multiple PRs, just link to the most important
ones.

`Previous Proposal` should be used when there is a specific line of succession
between this proposal and another proposal. For example, this proposal might
have been removed from a previous proposal so that it can be reviewed separately,
or this proposal might supersede a previous proposal in some way that was felt
to exceed the scope of a "revision". Include text briefly explaining the
relationship, such as "Supersedes ST-1234" or "Extracted from ST-01234". If
possible, link to a post explaining the relationship, such as a review decision
that asked for part of the proposal to be split off. Otherwise, you can just
link to the previous proposal.

`Previous Revision` should be added after a major substantive revision of a
proposal that has undergone review. It links to the previously reviewed revision.
It is not necessary to add or update this field after minor editorial changes.

`Review` is a history of all discussion threads about this proposal, in
chronological order. Use these standardized link names: `pitch` `review`
`revision` `acceptance` `rejection`. If there are multiple such threads, spell
the ordinal out: `first pitch` `second review` etc.

## Introduction

A short description of what the feature is. Try to keep it to a single-paragraph
"elevator pitch" so the reader understands what problem this proposal is
addressing.

## Motivation

Describe the problems that this proposal seeks to address. If the problem is
that some common pattern is currently hard to express, show how one can
currently get a similar effect and describe its drawbacks. If it's completely
new functionality that cannot be emulated, motivate why this new functionality
would help Swift developers test their code more effectively.

## Proposed solution

Describe your solution to the problem. Provide examples and describe how they
work. Show how your solution is better than current workarounds: is it cleaner,
safer, or more efficient?

This section doesn't have to be comprehensive. Focus on the most important parts
of the proposal and make arguments about why the proposal is better than the
status quo.

## Detailed design

Describe the design of the solution in detail. If it includes new API, show the
full API and its documentation comments detailing what it does. If it involves
new macro logic, describe the behavior changes and include a succinct example of
the additions or modifications to the macro expansion code. The detail in this
section should be sufficient for someone who is *not* one of the authors to be
able to reasonably implement the feature.

## Source compatibility

Describe the impact of this proposal on source compatibility. As a general rule,
all else being equal, test code that worked in previous releases of the testing
library should work in new releases. That means both that it should continue to
build and that it should continue to behave dynamically the same as it did
before.

This is not an absolute guarantee, and the testing library administrators will
consider intentional compatibility breaks if their negative impact can be shown
to be small and the current behavior is causing substantial problems in practice.

For proposals that affect testing library API, consider the impact on existing
clients. If clients provide a similar API, will type-checking find the right one?
If the feature overloads an existing API, is it problematic that existing users
of that API might start resolving to the new API?

## Integration with supporting tools

In this section, describe how this proposal affects tools which integrate with
the testing library. Some features depend on supporting tools gaining awareness
of the new feature for users to realize new benefits. Other features do not
strictly require integration but bring improvement opportunities which are worth
considering. Use this section to discuss any impact on tools.

This section does need not to include details of how this proposal may be
integrated with _specific_ tools, but it should consider the general ways that
tools might support this feature and note any accompanying SPI intended for
tools which are included in the implementation. Note that tools may evolve
independently and have differing release schedules than the testing library, so
special care should be taken to ensure compatibility across versions according
to the needs of each tool.

## Future directions

Describe any interesting proposals that could build on this proposal in the
future. This is especially important when these future directions inform the
design of the proposal, for example by making sure an interface meant for tools
integration can be extended to include additional information.

The rest of the proposal should generally not talk about future directions
except by referring to this section. It is important not to confuse reviewers
about what is covered by this specific proposal. If there's a larger vision that
needs to be explained in order to understand this proposal, consider starting a
discussion thread on the forums to capture your broader thoughts.

Avoid making affirmative statements in this section, such as "we will" or even
"we should". Describe the proposals neutrally as possibilities to be considered
in the future.

Consider whether any of these future directions should really just be part of
the current proposal. It's important to make focused, self-contained proposals
that can be incrementally implemented and reviewed, but it's also good when
proposals feel "complete" rather than leaving significant gaps in their design.
An an example from the Swift project, when
[SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md)
introduced the `@inlinable` attribute, it also included the `@usableFromInline`
attribute so that declarations used in inlinable functions didn't have to be
`public`. This was a relatively small addition to the proposal which avoided
creating a serious usability problem for many adopters of `@inlinable`.

## Alternatives considered

Describe alternative approaches to addressing the same problem. This is an
important part of most proposal documents. Reviewers are often familiar with
other approaches prior to review and may have reasons to prefer them. This
section is your first opportunity to try to convince them that your approach is
the right one, and even if you don't fully succeed, you can help set the terms
of the conversation and make the review a much more productive exchange of ideas.

You should be fair about other proposals, but you do not have to be neutral;
after all, you are specifically proposing something else. Describe any
advantages these alternatives might have, but also be sure to explain the
disadvantages that led you to prefer the approach in this proposal.

You should update this section during the pitch phase to discuss any
particularly interesting alternatives raised by the community. You do not need
to list every idea raised during the pitch, just the ones you think raise points
that are worth discussing. Of course, if you decide the alternative is more
compelling than what's in the current proposal, you should change the main
proposal; be sure to then discuss your previous proposal in this section and
explain why the new idea is better.

## Acknowledgments

If significant changes or improvements suggested by members of the community
were incorporated into the proposal as it developed, take a moment here to thank
them for their contributions. This is a collaborative process, and everyone's
input should receive recognition!

Generally, you should not acknowledge anyone who is listed as a co-author or as
the review manager.
