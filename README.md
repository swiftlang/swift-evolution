# Swift Programming Language Evolution

Swift is a powerful and intuitive programming language that is designed to make writing and maintaining correct programs easier. Swift is growing and evolving, guided by a community-driven process referred to as the Swift evolution process. This document outlines the Swift evolution process and how a feature grows from a rough idea into something that can improve the Swift development experience for millions of programmers.

## Scope

The Swift evolution process covers all changes to the Swift language and the public interface of the Swift standard library, including new language features and APIs (no matter how small), changes to existing language features or APIs, removal of existing features, and so on. Smaller changes, such as bug fixes, optimizations, or diagnostic improvements can be contributed via the normal contribution process; see [Contributing to Swift](http://www.swift.org/contributing.html).

## Goals

The Swift evolution process aims to leverage the collective ideas, insights, and experience of the Swift community to improve the Swift development experience. Its two primary goals are:

* Engage the wider Swift community in the ongoing evolution of Swift, and
* Maintain the vision and conceptual coherence of Swift.

There is a natural tension between these two goals. Open evolution processes are, by nature, chaotic. Yet, maintaining a coherent vision for something as complicated as a programming language requires some level of coordination. The Swift evolution process aims to strike a balance that best serves the Swift community as a whole.

## Participation

Everyone is welcome to propose, discuss, and review ideas to improve
the Swift language and standard library on the [swift-evolution
mailing list][swift-evolution-mailing-list].

The Swift [core team](www.swift.org/community.html#core-team) is
responsible for the strategic direction of Swift. Core team members
initiate, participate in, and manage the public review of proposals
and have the authority to accept or reject changes to Swift.

## How to propose a change

* **Socialize the idea**: propose a rough sketch of the idea on the [swift-evolution mailing list][swift-evolution-mailing-list], the problems it solves, what the solution looks like, etc., to gauge interest from the community.
* **Develop the proposal**: expand the rough sketch into a complete proposal, using the [proposal template](0000-template.md), and continue to refine the proposal on the evolution mailing list. Prototyping an implementation and its uses along with the proposal is encouraged, because it helps ensure both technical feasibility of the proposal as well as validating that the proposal solves the problems it is meant to solve.
* **Request a review**: initiate a pull request to the [swift-evolution repository][swift-evolution-repo] to indicate to the core team that you would like the proposal to be reviewed. When the proposal is sufficiently detailed and clear, and addresses feedback from earlier discussions of the idea, the pull request will be accepted. The proposal will be assigned a proposal number as well as a core team member to manage the review.
* **Address feedback**: in general, and especially [during the review period](#review), be responsive to questions and feedback about the proposal.

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
reviews. It is important that the proposal authors be available to
answer questions, address feedback, and clarify their intent during
the review period.

After the review has completed, the core team will make a decision on
the proposal. The review manager is responsible for determining
consensus among the core team members, then reporting their decision
to the proposal authors and mailing list. The review manager will
update the proposal's state in the [swift-evolution
repository][swift-evolution-repo] to reflect that decision.

## Proposal states
A given proposal can be in one of several states:

* **Review**: the proposal is awaiting or undergoing review. Once
  known, the dates for the actual review will be placed in the
  proposal document.
* **Under revision**: the proposal is undergoing revision by the
  author(s) based on feedback from the review.
* **Deferred**: consideration of the proposal has been deferred until
  the next major Swift release.
* **Accepted**: the proposal has been accepted and is either awaiting
  implementation or is actively being implemented. Once a proposal
  enters the "accepted" state, it becomes part of the Swift roadmap.
* **Dismissed**: the proposal has been considered and rejected.

## Active proposals
[Active proposals]: #active-proposals

### Active reviews

(No active reviews)

### Upcoming reviews

(No upcoming reviews)

### Accepted
* [Allow (most) keywords as argument labels](proposals/0001-keywords-as-argument-labels.md)

[swift-evolution-repo]: https://github.com/apple/swift-evolution  "Swift evolution repository"
[swift-evolution-mailing-list]: mailto:swift-evolution@swift.org  "Swift evolution mailing list"
