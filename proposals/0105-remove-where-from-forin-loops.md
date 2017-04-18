# Removing Where Clauses from For-In Loops

* Proposal: [SE-0105](0105-remove-where-from-forin-loops.md)
* Author: [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-June/000199.html)

## Introduction

This proposal removes `where` clauses from `for-in` loops, where they are better expressed (and read) as guard conditions.

Swift Evolution Discussion: [\[Pitch\] Retiring `where` from for-in loops](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160606/020566.html)

## Motivation

As syntactic sugar, the for loop's `where` clause is rarely used, hard to discover, and elevates one style (`continue` on condition, aka filtering) above other related styles: `break` on condition (`while` or `until`), `return` on condition (`unless`), `throw` on condition, and abort (`fatalError()`) on condition. The `where` clause supports a fluent style that is difficult to document separately at its point of use and may be hard to breakpoint and debug. Eliminating `where` in favor of `guard` statements addresses all these points: better commenting, better breakpointing and debugging, and full domain coverage over filtering and early exit in a way that `where` cannot.

#### Frequency of Use

Where clauses are rarely used. In the Swift standard library, they occur three times, compared to about 600 uses of `for-in`.

```
private/StdlibUnittest/StdlibUnittest.swift.gyb:    for j in instances.indices where i != j {
public/core/Algorithm.swift:  for value in rest where value < minValue {
public/core/Algorithm.swift:  for value in rest where value >= maxValue {
```

I pulled down a random sample of popular Swift repositories from GitHub and found one use of `for-in-where` among my sample vs over 650 `for-in` uses.

```
Carthage/Source/CarthageKit/Algorithms.swift: for (node, var incomingEdges) in workingGraph where incomingEdges.contains(lastSource) {
```

#### Confusion of Use

Consider the following two code snippets:

```swift
print("for in")
var theArray = [1, 2, 3, 4, 5, 6, 7, 8, 9]
for x in theArray where x % 2 == 1 { print (x) }

print("while")
var anArray = [1, 2, 3, 4, 5, 6, 7, 8, 9]
while let x = anArray.popLast() where x % 2 == 1 { print(x) }
```

In the first, the where clause acts as a filter, using syntactic sugar for `continue` when its condition is not met. In while loops, it’s a conjoined Boolean, and will `break` when its condition is not met. In my experience offering peer support for new Swift developers, the `where` clause is a source of confusion when it is considered and/or used.

#### Completeness of Guard Conditions

Guard conditions can `continue` (mimicking the current use of `where`), `break`, `return`, or otherwise exit scope. This offers more flexible and complete behavior.

```swift
for x in sequence {
    guard condition else { continue } // current where behavior
    guard condition else { break } 
    guard condition else { return } 
    guard condition else { throw error } 
    guard condition else { fatalError() } // etc.
}
```

Removing where from for-in loops reduces cognitive burden when interpreting intent. The logic is easier to read and follow. And the Swift grammar is simpler. 

#### SE-0099

Upon accepting [SE-0099](0099-conditionclauses.md), the core team removed `where` clauses from condition clauses. The team wrote, "[T]he 'where' keyword can be retired from its purpose as a [B]oolean condition introducer." 

#### Malformed Grammar

In Swift's current form, the where-clause in for-loops inconsistently applied. Unlike `switch` statements and `do` loops, a `for-in` loop's where-clause is separated from the pattern it modifies.

```swift
for case? pattern in expression where-clause? code-block

case-item-list → pattern where-clause? | pattern where-clause? , case-item-list

catch pattern? where-clause? code-block
```

This separation makes the clause harder to associate with the pattern, can confuse users as to whether it modifies the expression or the pattern, and represents an inconsistency in Swift's grammar. The where-clause really should have been designed like this:

```swift
for case? pattern where-clause? in expression code-block
```

### Other Where Clause Uses

This proposal does not affect where clause use in generics. Using generic constraints unamibiguously offers positive utility.

Retiring `where` from `catch` clauses and `switch` statements is less clear cut. 

```swift
case_item_list : pattern where_clause? | pattern where_clause? ',' case_item_list
catch_clause : 'catch' pattern? where_clause? code_block
```

##### Case:

* Instances of `case.*:` in the standard library: 1337 (!)
* Instances of `case.*where.*:` in the standard library: 1-ish
* Instances of `case.*:` in my Apple sample code collection: 40 (!)
* Instances of `case.*where.*:` in my Apple sample code collection: 7
* Instances of `case.*:` in popular 3rd party source code: Over 1400
* Instances of `case.*where.*:` in popular 3rd party source code: 17

```
public/core/String.swift:        // case let x where (x >= 0x41 && x <= 0x5a):
```

##### Catch:

* Instances of `catch` in popular 3rd party source code: 75
* Instances of `catch.*where ` in popular 3rd party source code: 0
* Instances of `catch` in the standard library: 18
* Instances of `catch.*where ` in the standard library: 0

Unlike generic constraints, nothing prevents semantic disjunction in switch-case and catch `where` clauses, both provide expressive potential that could be missed.

## Detailed Design

This proposal removes the where clause from the for-in loop grammar:

```swift
for case? pattern in expression code-block
```

## Impact on Existing Code

Code must be refactored to move the where clause into `guard` (or, for less stylish coders, `if`) conditions.

## Alternatives Considered

* Not accepting this proposal, leaving the grammar intact.

* Including `catch` and `case` under the umbrella of this proposal. I think the general Swift user base would be extremely upset. Redesigning `switch` and `catch` statements to allow disjoint expressions a la SE-0099 would be difficult and disruptive. 

* Change `where` in `catch` and `case` clauses to `if`, restricting `where` clauses strictly to type constraints without  burning a new keyword. As Xiaodi Wu puts it, "Replacing `where` with `if` is unambiguous and eliminates the implication of a subordinate semantic relationship that can't be enforced, while still exposing all of the expressiveness made possible by `where` in that particular scenario."

```swift
    switch json {
    case let json as NSArray if json.count > 0:
        // handle non-empty array
    case let json as NSDictionary if json.allKeys.count > 0:
        // handle non-empty dict
    default:
        break
    }
```
* Extending the syntactic sugar in `for-in` loops to include `while`, `unless`, and `until`. This adds all four variations on `break` and `continue` to the `for-in` vocabulary, and might include a simultaneous renaming of `where` to `if`.

## Acknowledgements

Big thanks to Joe Groff, Brent Royal-Gordon, Xiaodi Wu
