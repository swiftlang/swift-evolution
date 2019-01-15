# Trailing commas in all expression lists

* Proposal: [SE-NNNN](NNNN-trailing-commas.md)
* Authors: [Nate Chandler](https://github.com/nate-chandler)
* Review Manager: TBD
* Status: **Implemented**
* Implementation: [apple/swift#21876](https://github.com/apple/swift/pull/21876)
* Previous Proposal: [SE-0084](0084-trailing-commas.md)

## Introduction

Currently, you can use trailing commas when writing array and dictionary literals.  Using this feature, you can conveniently toggle any expression's inclusion in your collection literal just by commenting and uncommenting the line the expression appears on.  This document proposes bringing that convenience to all expression lists.

Swift-evolution thread: [[Pitch] Trailing commas in all expression lists](https://forums.swift.org/t/pitch-trailing-commas-in-all-expression-lists/19527)

## Motivation

Today, you can easily add or remove any item, even the last, from a collection literal by commenting it in or out:

```swift
let colors = [
    "red",
    "green",
    "blue",
//    "cerulean"
]
```

Unfortunately, in Swift today, that convenience is not fully available in the other expression lists.

For example, in a multi-line function call, it is a breeze to comment out any argument

```swift
print(
    "red",
//    "green", // ok
    "blue",
    "cerulean"
)
```

*except* the last; commenting it out raises an error:

```swift
print(
    "red",
    "green",
    "blue", // error: unexpected ',' separator
//    "cerulean"
)
```

The problem is that current Swift does not accept a comma after the last expression in an argument list.

It is possible to work around that limitation by adopting a different whitespace style

```swift
print(
    "red"
  , "green"
  , "blue" // no error: the comma is now at the beginning of the next line
//  , "cerulean"
)
```

but doing so has several downsides:

- that style may be inconsistent with the formatting of collection literals since those do not need to work around the same limitation
- formatting tools may not produce the desired indentation
- that style is not widely adopted

Moreover, this is just a workaround.  Developers who don't adopt this particular whitespace style won't be afforded the convenience of uniformly commenting their function arguments in and out.

Rather than forcing developers to use a particular whitespace style, Swift should consistently allow every argument passed to a multi-line function to be commented in and out.  

To afford developers this convenience analogous contexts, Swift should consistently accept a single trailing comma in non-empty every expression list.

## Proposed solution

Rather than allowing trailing commas in more expression lists in an ad hoc fashion, this document proposes uniformly allowing trailing commas in all non-empty expression lists:

Allowing trailing commas in these positions provides the convenience already available in collection literal expressions lists to all expression lists.  Every expression--including the last--would be able to be included/excluded from the expression list just by commenting out the line(s) it appears on.

Moreover, accepting trailing commas in these positions makes the language consistent.  Currently, trailing commas are accepted only in two particular expression lists, namely when the expression list is a collection literal.  With the change, trailing commas would consistently be accepted in every expression list.

With this change, trailing commas will be accepted in the following positions:

- array literals (already allowed) 
```swift
["red", "green",]
```
- dictionary literals (already allowed)
```swift
["red" : 4, "green" : 8,]
```
- object literals 
```swift
#colorLiteral(red: 0.0, green: 0.482, blue: 0.655, alpha: 1.0,)
```
- free function calls
```swift
print("red", "green",)
```
- method calls
```swift
foo.print("red", "green",)
```
- initializer calls
```swift
let instance = Widget("red", "green",)
```
- subscript reads
```swift
foo["red", "green",]
```
- subscript writes
```swift
foo["red", "green",] = "yellow"
```
- super method calls
```swift
super.print("red", "green",)
```
- super initializer calls
```swift
super.init("red", "green",)
```
- super subscript reads
```swift
super["red", "green",]
```
- super subscript writes
```swift
super["red", "green",] = "yellow"
```
- enum instantiations
```swift
let e = E.foo("red", "green",)
```
- tuple instantiations
```swift
let t = ("red", "green",)
```
- key-path subscripts
```swift
let path = \Gadget[0, 1,]
```

Trailing commas will *not* be accepted in empty expression lists.  Text like the following will not parse:

```
    let arrr: [Int] = [,] // error: unexpected ',' separator

    let subs = arrr[,] // error: expected expression in container literal

    print(,) // error: unexpected ',' separator

    let empT = (,) // error: unexpected ',' separator
```

## Detailed design

Swift will accept an optional trailing comma in every non-empty expression list.

The grammatical productions from The Swift Programming Language will be modified as follows:

<pre>
expression-list -> expression <b>,opt</b> | expression , expression-list
function-call-argument-list -> function-call-argument <b>,opt</b> | function-call-argument , function-call-argument-list
tuple-element-list -> tuple-element <b>,opt</b> | tuple-element , tuple-element-list
playground-literal -> #colorLiteral(red : expression, green : expression, blue : expression, alpha : expression <b>,opt</b>)
playground-literal -> #fileLiteral(resourceName : expression <b>,opt</b>)
playground-literal -> #imageLiteral(resourceName : expression <b>,opt</b>)
</pre>

With these few changes to the grammatical productions, trailing commas will be accepted in all the places described in the [previous section](#proposed-solutions).

## Future directions

This document proposes changing the language to accept trailing commas in every expression list.  There is a reasonable further easing of the restriction on trailing commas: allow trailing commas in every comma-separated list.

The same observations about language consistency and developer convenience both apply to eliminating the restriction entirely.  The observations don't, however, carry the same force in that broader context.

Swift currently has a minor inconsistency in that it accepts trailing commas in only some expression lists.  The change proposed here would makes the language consistent: Swift would accept trailing commas in every non-empty expression list.  The further change to allow trailing commas in every comma-separated list would also make the language consistent; it is not, however, the minimal change which would make the language consistent.  The change in this proposal is.

Regarding convenience, by far the most common comma-separated lists are expression lists, especially function calls.  Consequently, given the smaller change outlined in this proposal, the further easing of the restriction on trailing commas to allow them in every comma-separated list would provide significantly less additional advantage than the smaller language change would provide over the current state of affairs.

For those reasons, that larger change is deferred.  This proposal does, however, leave open the door for accepting trailing commas in every comma-separated list.

## Source compatibility

N/A

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

- Allow trailing commas in function calls, function declarations, tuple type definitions, and tuple literals (SE-0084).

SE-0084 was [rejected](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000171.html).

- Only allow trailing commas in expression lists when the surrounding whitespace satisfies some condition.  For example, allow a trailing comma whenever it is separated by a newline from the list closing token (parenthesis or bracket).

Rationale: The grammar generally avoids legislating style.

