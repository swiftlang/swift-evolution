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

Everyone is welcome to propose and discuss ideas to improve the Swift language and standard library on the Swift [mailing lists](http://www.swift.org/mailing_lists.html). The discussion of the evolution of the Swift language occurs on the [swift-evolution](mailto:swift-evolution@swift.org) mailing list, while discussion of the evolution of the Swift standard library occurs on the [swift-stdlib-evolution](mailto:swift-stdlib-evolution@swift.org) mailing list. It is on these mailing lists where ideas evolve into concrete, detailed proposals based on community feedback.

The Swift [core team](http://www.swift.org/community.html#core-team) is responsible for the strategic direction of the Swift language and standard library. Ideas that have garnered general support within the community are discussed by the core team on the appropriate forum ([swift-review](mailto:swift-review@swift.org) for the language and [swift-stdlib-review](mailto:swift-stdlib-review@swift.org) for the standard library). Accepted proposals become part of the Swift [roadmap](roadmap.md).

## How to Propose a Significant Change

* **Socialize the idea**: propose a rough sketch of the idea on the appropriate "evolution" mailing list, the problems it solves, what the solution looks like, etc., to gauge interest from the community.
* **Develop the proposal**: expand the rough sketch into a complete proposal, using the [proposal template](0000-template.md), and continue to refine the proposal on the appropriate evolution mailing list. Prototyping an implementation along with the proposal is encouraged, because it helps ensure both technical feasibility of the proposal as well as validating that the proposal solves the problems it is meant to solve.
* **Officially propose the change**: initiate a pull request to the swift-evolution repository to indicate to the core team that you would like the proposal to be reviewed. When the proposal is sufficiently detailed and clear, the pull request will be accepted. The proposal will be assigned a proposal number as well as a core team member to guide the proposal through the review process. The core team member will post the proposal to the appropriate "review" list ([swift-review](mailto:swift-review@swift.org) or [swift-stdlib-review](mailto:swift-stdlib-review@swift.org)) for discussion among the core team.
* **Iterate based on feedback from the core team**: continue to revise the proposal based on feedback from the core team (and, likely, the evolution mailing list), then initiate another pull request when the proposal is ready to be reconsidered.

## Proposal States
A given proposal can be in one of several states:

* **Review**: the proposal is awaiting review by the core team. This is the initial state for any proposal entering the system.
* **Under revision**: the proposal is undergoing revision by the author(s) based on feedback from the core team.
* **Deferred**: consideration of the proposal has been deferred until the next major Swift release.
* **Accepted**: the proposal has been accepted and is either awaiting implementation or is actively being implemented. Once a proposal enters the "accepted" state, it becomes part of the Swift roadmap.
* **Dismissed**: the proposal has been considered and rejected.

## Active proposals
[Active proposals]: #active-proposals

### Review

### Accepted
* [Allow (most) keywords as argument labels](proposals/0001-keywords-as-argument-labels.md)
