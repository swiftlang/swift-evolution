# Nested extensions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Author 1](https://github.com/swiftdev), [Author 2](https://github.com/swiftdev)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

By removing the restriction that extensions can only be used as top-level declarations, this important feature of Swift could become more powerful and solve issues some users have with access control.

Swift-evolution thread: [Enhancing access levels without breaking changes](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170403/035319.html)

## Motivation

Currently, access control is a very hot topic for Swift, and all of the options discussed so far had strong resistance from different parts of the community.

This concept tries to avoid all objections that were raised against the various modells (of course, it triggers fresh ones at the same time ;-), and because it is purely additive, it removes the pressure to address the current issues in Swift 4.
Although it wasn't a motivation, the proposal also offers an answer to the question if (and how) properties should be allowed in extensions.

SE-0169 would render major parts of this idea useless, so I think it's qualified to be discussed in this stage.

## Proposed solution

Remove the restriction that extensions can only be declared on top-level of a file.

This proposal explicitly does not suggest to change the effect of access modifiers *inside* extensions (a method marked private in an extension will only be visible inside that extension), nor to change the meaning of access modifiers *on* extensions - although it would make much sense to get rid of the special treatment that `private` receives in top-level extensions.

## Detailed design

There isn't much to add here:
Extensions should be allowed in type declarations and other extensions (I'm skipping methods in this draft - I see neither big problems associated with extensions declared inside methods, nor convincing use cases for them).

- The rules should be the same as for nested types, so marking a member of an extension `private` would restrict its visiblity to the scope of this extension.

- The goals of SE-0169 could be achieved in this model by simply putting an extension inside a type declaration, while keeping `private` members protected.

Nested extensions should also be allowed to contain stored properties of the enclosing class, thus enabling better visibility management for those as well:

- Stored properties in extensions have been requested before, but this approach enables them quite naturally, as the rule that you can only declare stored properties inside the declaration of a type is respected.

- It would also be possible to levearage the "default access level" feature of extensions to group properties that should have the same visibility.

Because there is no natural limit of nesting extensions, this feature enables developers to design more sophisticated systems of access rights, without increasing Swifts complexity for users that are happy with "puplic-internal-private" and don't see the need for additional keywords or other changes in the language.

## Future enhancements

For extensions of an enclosing type, that type could be easily inferred, so some repetition could be eliminated easily.

## Source compatibility

Purely additive

## Effect on ABI stability

There are some pitfalls associated with ABI, but I don't think its stability would be affected.

## Effect on API resilience

None known

## Alternatives considered

SE-0169, SE-0159, renaming `fileprivate` and/or `private`

All of those possibilities have their own strengths and weaknesses, and there is a huge dissent which of those are important: No matter which would be choosen, at least one group of Swift users is punished.
