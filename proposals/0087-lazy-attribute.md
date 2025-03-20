# Rename `lazy` to `@lazy`

* Proposal: [SE-0087](0087-lazy-attribute.md)
* Author: [Anton3](https://github.com/Anton3)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://forums.swift.org/t/rejected-se-0087-rename-lazy-to-lazy/2778)

## Introduction

Make `lazy` declaration modifier an attribute by renaming it to `@lazy`. Example:

```swift
struct ResourceManager {
  @lazy var resource: NSData = loadResource()
}
```

Swift-evolution thread: [link to the discussion thread for that proposal](https://forums.swift.org/t/idea-make-lazy-an-attribute/2424)

## Motivation

Swift's rule for attribues/keywords is that keywords usually modify type of variable; attributes do not.

`lazy` clearly does not modify type of its variable, it only delays side effects of its initializer.
Type of `resource` in the example above is still `NSData`.

Many other similar declaration modifiers are already attributes:

- `@available`,
- `@objc`,
- `@nonobjc`,
- `@NSCopying`,
- `@NSManaged`,
- `@IBOutlet`, etc

## Detailed design

Remove `lazy` keyword, add `@lazy` attribute and add migration rule to replace them.

## Future directions

Many people look forward to "Property behaviours" proposal for Swift 4.
It allows to create declaration modifiers using Swift language.

`@lazy` is one of the main candidates for being extracted into standard library.
But to do so, we must first make it an attribute.
Because it is a breaking change, the earlier, the better.

## Impact on existing code

This is a breaking change, but migration is trivial.
