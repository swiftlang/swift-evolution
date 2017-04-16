# Nested extensions

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Tino Heth](https://github.com/tinoheth)
* Review Manager: TBD
* Status: **Awaiting review**

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

This proposal explicitly does not suggest to change the effect of access modifiers *inside* extensions (a method marked `private` in an extension will only be visible inside that extension).

The meaning of access modifiers *on* nested extensions is the default to use for all of its entities that aren't marked explicitely with a modifier.

## Detailed design

There isn't much to add here, but to clarify the implications:
Extensions should be allowed in type declarations and other extensions (I'm skipping methods in this draft - I see neither big problems associated with extensions declared inside methods, nor convincing use cases for them).

- Nesting would be allowed for extensions of all types that are visible in a given file.

- The rules should be the same as for nested types, so marking an entity in an extension `private` would restrict its visiblity to the scope of this extension.

- The goals of SE-0169 could be achieved in this model by simply putting an extension inside a type declaration, while keeping `private` members protected from regular extensions.

Nested extensions should also be allowed to contain stored properties of the enclosing type, thus enabling better visibility management for those as well:

- Stored properties in extensions have been requested before, but this approach enables them quite naturally, as the rule that you can only declare stored properties inside the declaration of a class or struct is respected.

- It would also be possible to levearage the "default access level" feature of extensions to group properties that should have the same visibility.

Because there is no natural limit of nesting extensions, this feature enables developers to design more sophisticated systems of access rights, without increasing Swifts complexity for users that are happy with "puplic-internal-private" and don't see the need for additional keywords or other changes in the language.

To illustrate the expressiveness:

You could create a property of a type that is only visible to a certain method of a different type - not even the owning type would be able to access it.

#### Extending nested types

Extending inner types is possible with a `extension OuterType.InnerType`-syntax, which is left untouched - but name resolution should follow the existing rules that, for example, apply when you create an instance of an inner type.

Therefor, it would be allowed to skip a prefix of the full identifier inside the declaration of an enclosing type.

## Possible future enhancements

- Repetition could be eliminated easily by assuming that a "typeless" nested extensions should belong to the enclosing type.

- Add a shorthand to declare single-method extensions to save one level of indentation for those. As increased indention is the major drawback of this proposal, that would be quite desirable.

## Source compatibility

Purely additive

## Effect on ABI stability

There are some pitfalls associated with ABI, but I don't think its stability would be affected.

## Effect on API resilience

None known

## Alternatives considered

Status quo, SE-0169, SE-0159, several choices for renaming `fileprivate` and/or `private`, https://github.com/apple/swift-evolution/pull/681, removing all modifiers except `open` and `internal`

All of those possibilities have their own strengths and weaknesses, and there is a huge dissent which of those are important: No matter which would be choosen, at least one group of Swift users is punished.
