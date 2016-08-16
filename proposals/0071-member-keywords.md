# Allow (most) keywords in member references

* Proposal: [SE-0071](0071-member-keywords.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000122.html)

## Introduction

The [Swift API Design
Guidelines](https://swift.org/documentation/api-design-guidelines/)
consider enum cases as values that use the lowerCamelCase naming
conventions. This means that case names that previously did not
conflict with keywords (such as `Default`, `Private`, `Repeat`) now
cause conflicts, a problem that is particularly acute when the naming
conventions are applied by the Clang importer (per
[SE-0005](0005-objective-c-name-translation.md)). To
mitigate this issue, this proposal allows the use of most keywords
after a ".", similarly to how
[SE-0001](0001-keywords-as-argument-labels.md)
allows keywords are argument labels.

* [\[Idea\] Allowing most keywords after "."](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011169.html)
* [\[Review\] SE-0071: Allow (most) keywords in member references](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015760.html)

## Motivation

[SE-0005](0005-objective-c-name-translation.md)
started lower-camel-casing importer enum cases, which created a number
of enum types whose names conflict with keywords. For example:

```swift
enum UITableViewCellStyle : Int {
  case \`default\`
  case value1
  case value2
  case subtitle
}

enum SCNParticleImageSequenceAnimationMode : Int {
  case \`repeat\`
  case clamp
  case autoReverse
}
```

The need to use back-ticks to declare the enumeration is not terribly
onerous, especially given that these are Objective-C APIs with
very-long names (`UITableViewCellStyleDefault`,
`SCNParticleImageSequenceAnimationModeRepeat`). However, at the use
site, the back-ticks are messy:

```swift
let cell = UITableViewCell(style: .`default`, reuseIdentifier: nil)
particleSystem.imageSequenceAnimationMode = SCNParticleImageSequenceAnimationMode.`repeat`
```

## Proposed solution

Allow the use of keywords after the `.` in a member access, except for
those keywords that have special meaning in the language: `self`,
`dynamicType`, `Type`, `Protocol`, (*note*: this list should track the
evolution of the actual language). For example, the above example
would become:

```swift
let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
particleSystem.imageSequenceAnimationMode = SCNParticleImageSequenceAnimationMode.repeat
```

## Impact on existing code

This change doesn't break any existing code; the back-ticks will
continue to work as they always have. As we did with
[SE-0001](0001-keywords-as-argument-labels.md),
we can provide warnings with Fix-Its that remove spurious back-ticks
at use sites. While not semantically interesting, this helps
developers clean up their code.
