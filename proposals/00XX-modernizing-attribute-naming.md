# Modernizing Attribute Case and Attribute Argument Naming

* Proposal: TBD
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

Two isolated instances of [snake case](https://en.wikipedia.org/wiki/Snake_case) 
remain in the Swift attribute grammar. This proposal updates those elements to bring
them into compliance with modern Swift language standards and applies a new
consistent pattern to existing attributes.

*The Swift-Evolution discussion of this topic took place in the [\[Discussion\] Modernizing Attribute Case and Attribute Argument Naming](http://article.gmane.org/gmane.comp.lang.swift.evolution/7335) thread. Hat tip to Michael Well, Dmitri Gribenko, Brent Royal-Gordon, Shawn Erickson, Dany St-Amant*

## Motivation

Two elements of Swift attribute grammar retain *lower_snake_case* patterns: Swift's `warn_unused_result` attribute and its `mutable_variant` argument. 
This pattern is being actively eliminated from Swift in an effort to modernize
the language and adopt common naming patterns. Renaming these elements fall into 
two separate problems: one trivial, one forward-looking.

##Detail Design

####Updating the `mutable_variant` argument

The `mutable_variant` argument refactor is minimal. It should use the lower camel case Swift standard for arguments and be renamed `mutableVariant`. 


####Updating the `warn_unused_result` attribute

In the current version of Swift, most native attributes use lowercase naming: for example `@testable` and `noescape`. The most natural approach is to mimic this with `@warn-unused-result`, namely `@warnunusedresult`.

While this lower case pattern matches other compound attribute examples: `objc`, `noescape`, `nonobjc`, and `noreturn`, the re-engineered version of `warnunusedresult` is hard to read. It looks like a continuous string of lowercase characters instead of punching clear, identifiable semantic elements.  Using lowercase for complex attributes names, including future names yet to be introduced into the language, becomes confusing when used with longer compound examples.

For this reason, I recommend the Swift team adopt an upper camel case convention for attributes, matching the existing Cocoa participants: `UIApplicationMain`, `NSManaged`, `NSCopying`, `NSApplicationMain`, `IBAction`, `IBDesignable`, `IBInspectable`, and `IBOutlet`. This approach avoids the otherwise confusing long name issue.

#### Renaming Elements

Using upper camel case, Swift 3's renamed elements look like this:

```swift
@Autoclosure // was @autoclosure, treated as a single word
@Available // was @available
@ObjC // was @objc
@NoEscape // was @noescape
@NonObjC // was @nonobjc
@NoReturn // was @noreturn
@Testable // was @testable
@WarnUnusedResult // was @warn-unused-result
@Convention  // was @convention
@NoReturn // was @noreturn
```

#### Redeclaring `sort`

The following is the public declaration of `sort()` in Swift 2.2:

```swift
@warn_unused_result(mutable_variant="sortInPlace")
public func sort() -> [Self.Generator.Element]
```

Here is the proposed public declaration of `sort()` in Swift 3:

```swift
@WarnUnusedResult(mutableVariant: "sortInPlace")
public func sort() -> [Self.Generator.Element]
```

Changes between the Swift 2.2 and Swift 3 declarations include:

* The upper camel case `WarnUnusedResult` replaces the lower snake case `@warn_unused_result`.
* The `mutable_variant` argument label becomes `mutableVariant`
* An argument colon replaces Swift 2.2's equal sign as proposed in SE-0040 "[Replacing Equal Signs with Colons For Attribute Arguments](https://github.com/apple/swift-evolution/blob/master/proposals/0040-attributecolons.md)".

#### SE-0030 Impact

Joe Groff's Swift-Evolution [SE-0030 Property Behaviors](https://github.com/apple/swift-evolution/blob/master/proposals/0030-property-behavior-decls.md) proposal introduces property implementation patterns using attributes to declare behavior function names, for example: `@lazy` and `@deferred`. 

It is likely that at least some of these property behaviors will be Apple-supplied.
I'd recommend against enforcing upper camel casing these. Lowercasing or lower camel casing custom behaviors may better match the keywords they are replacing.

Assuming that Swift starts accepting user-defined attributes, whether Apple-supplied or end-customizable, it needs a way to differentiate potential conflicts. Joe Groff points out that the most obvious solution for these conditions uses namespacing, for example `@Swift.Autoclosure`, `@UIKit.UIApplicationMain`, `@Cocoa.IBOutlet`, `@Swift.NoReturn`, `@Swift.lazy` (or `@Stdlib.lazy`), `@CustomModule.dispatchedOnce`, etc. 

```swift
@AttributeName // built-in, upper camel case
@attributebehaviorname // casing to be determined by Swift team
@Module.AttributeName // case follows source's convention, not determined
```

Name collisions should be limited enough that fully-qualified attributes would be rare, as they already are with top-level calls such as differentiating NSView's `print` function (print a view) from Swift's (output to the console or custom stream).

Joe Groff writes, "Once we open the floodgates for user-defined attributes, I think traditional namespacing and name lookup makes a lot of sense. We could conceptually namespace the existing hardcoded attributes into appropriate modules (Swift for the platform-neutral stuff, Foundation/AppKit/UIKit as appropriate for Apple-y stuff)."

## Alternatives Considered

Reaction to upper-case naming has been mildly mixed. I personally believe the redesign is more readable. Others object to using uppercase outside of types, even though Cocoa imports are already doing so.  Although the Swift team might prefer using lower camel case `@autoClosure, @available, @objC, @noEscape, @nonObjC, @noReturn, @testable, @warnUnusedResult, @convention, @noReturn`, this would be out of step with system-supplied imported attributes, specifically `UIApplicationMain`, `NSManaged`, `NSCopying`, `NSApplicationMain`, `IBAction`, `IBDesignable`, `IBInspectable`, and `IBOutlet`

Dany St-Amant suggests that attributes be case-insensitive, enabling coders to choose their casing. "[Maybe] cases could be ignored, making everybody writing code happy, and everyone reading code of others unhappy"