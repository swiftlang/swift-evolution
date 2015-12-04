# Allow (most) keywords as argument labels

* Proposal: [SE-0001](https://github.com/apple/swift-evolution/blob/master/proposals/0001-keywords-as-argument-labels.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Status: **Accepted**

## Introduction

Argument labels are an important part of the interface of a Swift function, describing what particular arguments to the function do and improving readability. Sometimes, the most natural label for an argument coincides with a language keyword, such as `in`, `repeat`, or `defer`. Such keywords should be allowed as argument labels, allowing better expression of these interfaces.

## Motivation

In some functions, the best argument label for a particular parameter
happens to coincide with a language keyword. For example, consider a
module-scope function that finds the index of a particular value in a
collection. A natural name for this would be `indexOf(_:in:)`:

	indexOf(value, in: collection)

However, because `in` is a keyword, one would actually have to use backticks to escape the `in`, e.g.:

	indexOf(value, `in`: collection)

When defining new APIs in Swift, authors will tend to pick other
non-keyword words (e.g., `within` for this example), even if they
aren't ideal. However, this issue also comes up when importing
Objective-C APIs under the "omit needless words" heuristics, requiring
escaping to use those APIs. For example:

	event.touchesMatching([.Began, .Moved], `in`: view)
	NSXPCInterface(`protocol`: SomeProtocolType.Protocol)


## Proposed solution

Allow the use of all keywords except `inout`, `var`, and `let` as argument labels. This affects the grammar in three places:

* Call expressions, such as the examples above. Here, we have no grammatic ambiguities, because "<keyword> \`:\`" does not appear in any grammar production within a parenthesized expression list. This is, by far, the most important case.

* Function/subscript/initializer declarations: aside from the three exclusions above, there is no ambiguity here because the keyword will always be followed by an identifier, ‘:’, or ‘_’. For example:

```
func touchesMatching(phase: NSTouchPhase, in view: NSView?) -> Set<NSTouch>
```

  Keywords that introduce or modify a parameter—-currently just
"inout", "let", and "var"—-will need to retain their former
meanings. If we invent an API that uses such keywords, they will still
need to be back-ticked:

```
func addParameter(name: String, `inout`: Bool)
```

* Function types: these are actually easier than #2, because the parameter name is always followed by a ‘:’:

```
(NSTouchPhase, in: NSView?) -> Set<NSTouch>
(String, inout: Bool) -> Void
```

## Impact on existing code

This functionality is strictly additive, and does not break any existing
code: it only makes some previously ill-formed code well-formed, and
does not change the behavior of any well-formed code.

## Alternatives considered

The primarily alternative here is to do nothing: Swift APIs will
continue to avoid keywords for argument labels, even when they are the
most natural word for the label, and imported APIs will either
continue to use backticks to will need to be renamed. This alternative
leaves a large number of imported APIs (nearly 200) requiring either
some level of renaming of the API or backticks at the call site.

A second alternative is to focus on `in` itself, which is by far the
most common keyword argument in imported APIs. In a brief survey of
imported APIs, `in` accounted for 90% of the conflicts with existing
keywords. Moreover, the keyword `in` is only used in two places in the
Swift grammar--for loops and closures--so it could be made
context-sensitive. However, this solution is somewhat more complicated
(because it requires more context-sensitive keyword parsing) and less
general.

