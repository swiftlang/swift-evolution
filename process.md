# Evolving Swift

[Swift](http://swift.org) is a powerful and intuitive modern programming language. It was designed from the start to minimize potential programming errors, helping you write and maintain correct code. Swift hasn't reached a stopping point. It continues to change and evolve with an active and involved community. 

Anyone can participate in this process. All it takes is a love of the language and a desire to help make it better. You are invited to join in and help leverage the collective ideas and insight of the Swift community to improve the Swift development experience. Your contributions can improve Swift for millions of programmers.

This document explains how a feature grows from rough ideas to an implementation incorporated into the language standard.  

## So you've got a great idea! Now what?

Congratulations on your idea. Before moving further, perform this sanity check to test whether your change is appropriate for this repository:
* Is it an evolutionary change to the Swift language or to the Swift standard library public interface?
* Is it a new language feature or API? (no matter how small!)
* Does it change any existing language features and APIs? 
* Does it propose to remove any existing features from the language?

If so, great. You're starting off at the right place!

Smaller changes such as bug fixes, optimizations, and diagnostic improvements can be contributed via the normal contribution process. See [Contributing to Swift](https://swift.org/community/#contributing) for details.

#### What is this Repo?
The [Swift Evolution](https://github.com/apple/swift-evolution) repository provides a central hub for the collection and dissemination of proposed, accepted, and rejected language changes. Its goals are to:

* Engage the wider Swift community in the ongoing evolution of Swift, and
* Maintain the vision and conceptual coherence of Swift.

## Decision Making

The natural tension between engagement and coherence requires a balance that serves the entire Swift community. Open evolution processes are, by nature, chaotic. Maintaining a coherent vision for something as complicated as a programming language requires coordination and leadership. There are some basic ground rules you'll need to know about before engaging in this process. 

The ultimate responsibility for adopting changes lies with the Swift [core team](https://swift.org/community/#core-team). The team establishes the strategic direction of Swift. Core team members initiate, participate in, and manage the public review of proposals and have the authority to accept or reject changes to Swift.

The majority of work and discussion do not take place here on Github. You participate on the [mailing list](https://lists.swift.org/mailman/listinfo/swift-evolution) tied to this repository. This list provides the platform to propose, discuss, and review ideas to improve the Swift language and standard library.

Using a mailing list establishes a public record of all proposed changes and their ensuing discussions. Participants can explore archives to determine whether a topic has already been discussed and/or voted on, and what the arguments for and against those changes were. The Swift Evolution archives are available at [lists.swift.org](https://lists.swift.org/pipermail/swift-evolution/).

## Working Towards a Proposal

Follow these steps to develop your Swift-enhancement idea towards a formal proposal:

* **Refine your thoughts**. Start by [expressing your idea](https://pbs.twimg.com/media/CJ0R2yAUsAAifE9.jpg) clearly, with a cogent set of arguments. Try to incorporate arguments both for and against your concept before you begin pitching other members of the community. If you have the luxury of Swift-using friends in real life, share your thoughts in person or through social media and see whether they think your ideas are strong enough to move forward with. 
* **Search for previous discussion**. Check the Swift Evolution repository and email archives.
* **Start a discussion on the mailing list.** Propose a rough sketch of your idea on the mailing list. Make sure to detail the problems it solves, what the solution looks like, etc., and gauge interest from the community.

The mailing list offers a diverse membership that includes participants that range from workaday devs to Apple Swift team members, compiler experts to language enthusiasts. Share your thoughts and see how the conversation goes. It can take days or weeks for an idea to percolate through the community before you're ready to start writing a proposal. Don't rush the discussion but don't abandon it either. Every idea needs an advocate. If you believe in your enhancement, commit to shepherding it through the proposal and review process.

## Creating Your Proposal

When the initial discussion has reached a natural stopping point, and you think there's sufficient support in the community for your idea to be adopted, it's time to develop a formal proposal and submit it to the Swift Evolution repository. 

Use the [proposal template](https://github.com/apple/swift-evolution/blob/master/0000-template.md) as your jumping off point. Fill out each section and consider adding any further material to support and motivate your proposal. Already accepted proposals offer a great resource for discussion topics. Use the mailing list discussions you participated to expand your rough sketch into a comprehensive proposal including arguments both for and against. 

Next return to the mailing list and present your preliminary proposal. As you receive feedback, refine your write-up. Again, wait for refinements to coalesce before moving forward.

#### Extra Credit

Where possible, prototype an implementation of your enhancement and provide code demonstrating its utility. This extra step helps validate your proposal. It exhibits the technical feasibility of your pitch and demonstrates that your proposal solves the problems it is meant to.

## Requesting a Review

Before your proposal is accepted and can be voted on, you must submit it to the core team:

* Fork the Swift Evolution repository and add your markdown-styled proposal. Initiate a pull request back to the official repository. 
* You may go through a period of back and forth requests with the core team until the proposal is sufficiently clear and detailed to move forward.
* When the proposal is considered ready and it addresses feedback from earlier discussions of the idea, and a core team member accepts the pull request and becomes your proposal's *review manager*.


## The Review Process

A review manager works with you once the proposal enters the review queue. Among other tasks, the manager schedules your review. Reviews usually last a week but can run longer for large or complex proposals or shorter for simple requests with general consensus. Accepted proposals are stored on the Swift Evolution repository in the [proposals folder](https://github.com/apple/swift-evolution/tree/master/proposals). Reviews dates are listed on [the master review schedule](https://github.com/apple/swift-evolution/blob/master/schedule.md).

When the scheduled review period arrives, the review manager posts your proposal to the mailing list, tagging the subject line with "[Review]" followed by the proposal title. Be available during your review to answer questions, address feedback, and clarify your
intent.

Once the review has completed, the core team makes its decision on
your proposal. The review manager determines the core team 
consensus and reports their decision back to you and the mailing list. The review manager updates the proposal's state at the repository to reflect that decision.

#### Proposal States
A given proposal can be in one of several states:

* **Awaiting review**: the proposal is awaiting review. Once known,
  the dates for the actual review will be placed in the proposal
  document and updated in the [review schedule](schedule.md). When the
  review period begins, the review manager will update the state to
  *under review*.
* **Under review**: the proposal is undergoing public review on the [swift-evolution mailing list][swift-evolution-mailing-list]. 
* **Under revision**: the proposal is undergoing revision by the
  author(s) based on feedback from the review.
* **Deferred**: consideration of the proposal has been deferred
  because it does not meet the [goals of the upcoming major Swift
  release](README.md). Deferred proposals will be reconsidered when
  scoping the next major Swift release.
* **Accepted**: the proposal has been accepted and is either awaiting
  implementation or is actively being implemented. Once a proposal
  enters the "accepted" state, it gets placed into its [target Swift
  release](README.md).
* **Rejected**: the proposal has been considered and rejected.

## Participating in the Review

After scheduling and announcement, the review process takes place on the evolution mailing list. Your review manager sends out a review request to the list (and summarizes its results at the end of the review period). All mailing list participants may participate in the proposal review. 

A successful review isn't just a simple up and down vote: it improves the proposal under review as well as evaluating it. Constructive criticism and refinement help mold proposals and, eventually, determine the direction Swift will take. The best reviews include the following information:

* What is your evaluation of the proposal?
* Is the problem being addressed significant enough to warrant a change to Swift?
* Does this proposal fit well with the feel and direction of Swift?
* If you have you used other languages or libraries with a similar feature, how do you feel that this proposal compares to those?
* How much effort did you put into your review? A glance, a quick reading, or an in-depth study?

Always state explicitly whether or not you believe that the proposal should be accepted into Swift.
