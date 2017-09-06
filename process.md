# Swift Evolution Process

Swift is a powerful and intuitive programming language that is designed to make writing and maintaining correct programs easier. Swift is growing and evolving, guided by a community-driven process referred to as the Swift evolution process. This document outlines the Swift evolution process and how a feature grows from a rough idea into something that can improve the Swift development experience for millions of programmers.

## Scope

The Swift evolution process covers all changes to the Swift language and the public interface of the Swift standard library, including new language features and APIs (no matter how small), changes to existing language features or APIs, removal of existing features, and so on. Smaller changes, such as bug fixes, optimizations, or diagnostic improvements can be contributed via the normal contribution process; see [Contributing to Swift](https://swift.org/community/#contributing).

## Goals

The Swift evolution process aims to leverage the collective ideas, insights, and experience of the Swift community to improve the Swift development experience. Its two primary goals are:

* Engage the wider Swift community in the ongoing evolution of Swift, and
* Maintain the vision and conceptual coherence of Swift.

There is a natural tension between these two goals. Open evolution processes are, by nature, chaotic. Yet, maintaining a coherent vision for something as complicated as a programming language requires some level of coordination. The Swift evolution process aims to strike a balance that best serves the Swift community as a whole.

## Participation

Everyone is welcome to propose, discuss, and review ideas to improve
the Swift language and standard library on the [swift-evolution
mailing list][swift-evolution-mailing-list]. Before posting a review,
please see the section "What goes into a review?" below.

The Swift [core team](https://swift.org/community/#core-team) is
responsible for the strategic direction of Swift. Core team members
initiate, participate in, and manage the public review of proposals
and have the authority to accept or reject changes to Swift.

## What goes into a review?

The goal of the review process is to improve the proposal under review
through constructive criticism and, eventually, determine the
direction of Swift. When writing your review, here are some questions
you might want to answer in your review:

* What is your evaluation of the proposal?
* Is the problem being addressed significant enough to warrant a change to Swift?
* Does this proposal fit well with the feel and direction of Swift?
* If you have used other languages or libraries with a similar feature, how do you feel that this proposal compares to those?
* How much effort did you put into your review? A glance, a quick reading, or an in-depth study?

Please state explicitly whether you believe that the proposal should be accepted into Swift.

## How to propose a change

* **Check prior proposals**: many ideas come up frequently, and may either be in active discussion on the mailing list, or may have been discussed already and have joined the [Commonly Rejected Proposals](commonly_proposed.md) list.  Please check the mailing list archives and this list for context before proposing something new.
* **Consider the goals of the upcoming Swift release**: Each major
Swift release is focused on a [specific set of goals](README.md)
described early in the release cycle. When proposing a change to
Swift, please consider how your proposal fits in with the larger goals
of the upcoming Swift release. Proposals that are clearly out of scope
for the upcoming Swift release will not be brought up for review. If you can't resist discussing a proposal that you know is out of scope, please include the tag `[Out of scope]` in the subject.
* **Socialize the idea**: propose a rough sketch of the idea on the [swift-evolution mailing list][swift-evolution-mailing-list], the problems it solves, what the solution looks like, etc., to gauge interest from the community.
* **Develop the proposal**: expand the rough sketch into a complete proposal, using the [proposal template](0000-template.md), and continue to refine the proposal on the evolution mailing list. Prototyping an implementation and its uses along with the proposal is *required* because it helps ensure both technical feasibility of the proposal as well as validating that the proposal solves the problems it is meant to solve.
* **Request a review**: initiate a pull request to the [swift-evolution repository][swift-evolution-repo] to indicate to the core team that you would like the proposal to be reviewed. When the proposal is sufficiently detailed and clear, and addresses feedback from earlier discussions of the idea, the pull request will be accepted. The proposal will be assigned a proposal number as well as a core team member to manage the review.
* **Address feedback**: in general, and especially [during the review period][proposal-status], be responsive to questions and feedback about the proposal.

## Review process

The review process for a particular proposal begins when a member of
the core team accepts a pull request of a new or updated proposal into
the [swift-evolution repository][swift-evolution-repo]. That core team
member becomes the *review manager* for the proposal. The proposal
is assigned a proposal number (if it is a new proposal), then enters
the review queue.

The review manager will work with the proposal authors to schedule the
review. Reviews usually last a single week, but can run longer for
particularly large or complex proposals.

When the scheduled review period arrives, the review manager will post
the proposal to the [swift-evolution mailing
list][swift-evolution-mailing-list] with the subject "[Review]"
followed by the proposal title and update the list of active
reviews. To avoid delays, it is important that the proposal authors be
available to answer questions, address feedback, and clarify their
intent during the review period.

After the review has completed, the core team will make a decision on
the proposal. The review manager is responsible for determining
consensus among the core team members, then reporting their decision
to the proposal authors and mailing list. The review manager will
update the proposal's state in the [swift-evolution
repository][swift-evolution-repo] to reflect that decision.

## Proposal states
A given proposal can be in one of several states:

* **Awaiting review**: The proposal is awaiting review. Once known, the dates
  for the actual review will be placed in the proposal document. When the review
  period begins, the review manager will update the state to *Active review*.
* **Scheduled for review (MONTH DAY...MONTH DAY)**: The public review of the proposal
  on the [swift-evolution mailing list][swift-evolution-mailing-list]
  has been scheduled for the specified date range.
* **Active review (MONTH DAY...MONTH DAY)**: The proposal is undergoing public review
  on the [swift-evolution mailing list][swift-evolution-mailing-list].
  The review will continue through the specified date range.
* **Returned for revision**: The proposal has been returned from review
  for additional revision to the current draft.
* **Withdrawn**: The proposal has been withdrawn by the original submitter.
* **Deferred**: Consideration of the proposal has been deferred
  because it does not meet the [goals of the upcoming major Swift
  release](README.md). Deferred proposals will be reconsidered when
  scoping the next major Swift release.
* **Accepted**: The proposal has been accepted and is either awaiting
  implementation or is actively being implemented.
* **Accepted with revisions**: The proposal has been accepted,
  contingent upon the inclusion of one or more revisions.
* **Rejected**: The proposal has been considered and rejected.
* **Implemented (Swift VERSION)**: The proposal has been implemented.
  Append the version number in parentheses—for example: Implemented (Swift 2.2).
  If the proposal's implementation spans multiple version numbers,
  write the version number for which the implementation will be complete.

[swift-evolution-repo]: https://github.com/apple/swift-evolution  "Swift evolution repository"
[swift-evolution-mailing-list]: https://swift.org/community/#swift-evolution  "Swift evolution mailing list"
[proposal-status]: https://apple.github.io/swift-evolution/

## Review announcement

When a proposal enters review, an email using the following template will be
sent to the swift-evolution mailing list and BCC'd to the swift-evolution-announce mailing list:

---

Hello Swift community,

The review of "\<\<PROPOSAL NAME>>" begins now and runs through \<\<REVIEW
END DATE>>. The proposal is available here:

> http://linkToProposal

Reviews are an important part of the Swift evolution process. All reviews
should be sent to the swift-evolution mailing list at

> <https://lists.swift.org/mailman/listinfo/swift-evolution>

or, if you would like to keep your feedback private, directly to the
review manager. When replying, please try to keep the proposal link at
the top of the message:

> Proposal link:
>>  http://linkToProposal

>  Reply text

>>  Other replies

##### What goes into a review?

The goal of the review process is to improve the proposal under review
through constructive criticism and, eventually, determine the direction of
Swift. When writing your review, here are some questions you might want to
answer in your review:

* What is your evaluation of the proposal?
* Is the problem being addressed significant enough to warrant a
  change to Swift?
* Does this proposal fit well with the feel and direction of Swift?
* If you have used other languages or libraries with a similar
  feature, how do you feel that this proposal compares to those?
* How much effort did you put into your review? A glance, a quick
  reading, or an in-depth study?

More information about the Swift evolution process is available at

> <https://github.com/apple/swift-evolution/blob/master/process.md>

Thank you,

-\<\<REVIEW MANAGER NAME>>

Review Manager

---
