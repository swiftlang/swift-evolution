# Disallow arbitrary expressions in selectors

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Alex Hoppen](https://github.com/ahoppen)
* Status: **Draft**
* Review manager: TBD

## Introduction

It is currently possible to write arbitrary expressions inside `#selector` like the following: `#selector(callThisFunc().bar)`. This complicates the implementation of proposals [SE-0064](https://github.com/apple/swift-evolution/blob/master/proposals/0064-property-selectors.md) (*Referencing Objective-C selector of property getters and setters*) and [SE-0062](https://github.com/apple/swift-evolution/blob/master/proposals/0062-objc-keypaths.md) (*Referencing Objective-C key-paths*) **a lot**. 

This proposal restricts expressions inside selectors to be a sequence of property or method refernces. I believe this will not be a major restrictions since arbitrary expressions in selectors are probably rarely used, have some rough edges and removing them would simplify the compiler.

## Proposed solution

I propose allowed expressions inside `#selector` (and once implemented `#keyPath`) to be a series of instance or class members separated by `.` and allow disambiguating the last component using `as`.

## Detailed design

### Examples

```swift
class Address: NSObject {
  dynamic var street: String
  dynamic var town: String
  
  init(street: String, town: String) {
    self.street = street
    self.town = town
  }
}

class Person: NSObject {
  dynamic var name: String
  dynamic var homeAddress: Address
  
  func workAddress() -> Address {
    // ...
  }
  
  func workAddress(formatter: AddressFormatter) -> String {
    // ...
  }

  init(name: String, homeAddress: Address) {
    self.name = name
    self.homeAddress = homeAddress
  }
}

let me: Person = ...
```

The following examples will continue to work:

```swift
let _ = #selector(getter: Person.name)
let _ = #selector(getter: me.name)

let _ = #selector(getter: Person.homeAddress.street)
// Could also be written as
let _ = #selector(getter: Address.street)

let _ = #selector(Person.workAddress as () -> Address)
let _ = #selector(Person.workAddress(formatter: ))
```

I propose removing this kind of selector:

```swift
// Should produce selector "street". Note that the method workAddress() is never 
// called and its return type only used during type checking
let _ = #selector(getter: me.workAddress().street) 

// The above can be rewritten in a cleaner way like the following
let _ = #selector(getter: Address.street)
```

The proposed way to rewrite the selector elimininates potential confusion about the fact that calling a method inside `#selector` actually doesn't invoke it.

### Grammar

<pre>
selector → #selector(<i>selector-modifer<sub>opt</sub></i> <i>selector-path</i>)

selector-modifier → getter:
selector-modifier → setter:

selector-path → <i>type-identifier</i> . <i>selector-member-path</i> <i>as-disambiguation<sub>opt</sub></i>
selector-path → <i>selector-member-path</i> <i>as-disambiguation<sub>opt</sub></i>

selector-member-path → <i>identifier</i>
selector-member-path → <i>unqualified-name</i>
selector-member-path → <i>identifier</i> . <i>selector-member-path</i>

as-disambiguation → as <i>type-identifier</i>
</pre>

For a further rationale on why arbitrary expressions are no longer possible, see the [discussion](https://bugs.swift.org/browse/SR-1239?focusedCommentId=13958&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel#comment-13958) on bugs.swift.org.

## Impact on existing code

Code that currently uses this feature needs to be rewritten as described in the example above. I believe, however, that the feature is rarely used so it will affect only very little source code and where it is currently used the proposed update is actually more readable.

## Alternatives considered

The only alternative I see is trying to keep the current semantics and implement them for the `getter:`/`setter:` selectors.