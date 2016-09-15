# Allow trailing commas in parameter lists and tuples

* Proposal: [SE-0084](0084-trailing-commas.md)
* Authors: [Grant Paul](https://github.com/grp), [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Rejected**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000171.html)

## Introduction

Swift permits trailing commas after the last element in array or dictionary literal. This proposal extends that to parameters and tuples.

Original swift-evolution discussion: [Allow trailing commas in argument lists](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012112.html)


## Motivation

Trailing commas offer linguistic sugar for flexible design. Ignored by the compiler, they enable developers to easily reorder elements and to comment out and uncomment in list-based features on an as-needed basis:

```swift
let strings = [
   "abc",
   "cde",
   "fgh",
//   "ijk",
]
```

Parameter declarations would benefit from the same support. Complex declarations, especially those with defaults, could be moved around and commented without having to spend unnecessary time adjusting where the final comma should and should not appear.

```swift
func padStringToLength(
    sourceString: String,
    destinationCount: Int,
    paddingStyle: StringPaddingStyle = .Left,
    paddingCharacter: Character = " ",
) -> String {
    /* ... */
}

padStringToLength(
    sourceString: "source",
    destinationCount: 4,
    paddingStyle: .Right,
    paddingCharacter: "",
)
```

Tuples would see the same benefits. With trailing commas, reversing the order of this tuple would take just two line-level adjustments:

```swift
let tuple: (
    string: String,
    number: Int,
) = (
   string: "string",
   number: 0,
)
```


## Detailed Design

With this design, the Swift compiler will simply ignore final parameter and tuple commas as it does in collections. This includes function calls, function declarations, tuple type definitions, and tuple literals.

Zero-element tuples and parameter lists would not support trailing commas. Single-element tuples would not allow trailing commas but single-element parameter lists would, consistent with the existing prohibition on named single-element tuples.

## Advantages of Acceptance

Trailing commas best offer support for situations that express variadic properties. All three of the following scenarios share this nature:

* Call sites with variadic arguments
* Call sites with defaulted arguments
* Definition sites with large complex multi-line argument lists or tuple members

It's easiest to make the case for call sites, the first two of these uses, as they exactly mirror the way collections parse members. Supporting the third style of trailing commas requires the consideration of real world modern Swift. 

Allowing cut and paste or commenting of entire parameter lines means simple changes do not ripple out to affect other lines. In this, trailing commas serve programmer intent and limit the effect in diff comparisons. As Joe Groff points out, one edit becomes one diff, without extra housekeeping for other affected lines. When considered together, the use cases for these scenarios are common enough to be considered something other than a "special case".

> "Having used, more or less continuously for my 20 years as a professional programmer, both a language that allows trailing commas and one that does not, I come down pretty strongly on the side of allowing trailing commas (for all the reasons already stated in this thread). If it means requiring a newline after the last comma to make some people feel better about it, so be it."  - John Siracusa

> "I was skeptical of this until a week or two ago, when I had some code where I ended up commenting out certain parameters. Removing the now-trailing commas was an inconvenience. So, +1 from me." - Brent Royal-Gordon

> "We should be consistent in either accepting or rejecting trailing commas everywhere we have comma-delimited syntax. I'm in favor of accepting it, since it's popular in languages where it's supported to enable a minimal-diff style, so that changes to code don't impact neighboring lines for purely syntactic reasons.
>
> If you add an argument to a function, without trailing comma support, a comma has to be added to dirty the previous line In response to observations that tuples and function arguments are somehow different from collection literals because they generally have fixed arity, I'll note that we have a very prominent variadic function in the standard library, "print", and that adding or removing values to a "print" is a very common and natural thing to do
>
> We've generally shied away from legislating style; see our rationale behind not requiring `self.` ([example](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160104/005478.html)) In languages where trailing commas are pervasively allowed, such as Perl, Python, Ruby, and modern Javascript, I haven't seen any indication that this is a major problem. Less blood has definitely been shed over it than over bracing style and other style wars." - Joe Groff

## Impact on Existing Code

The acceptance of SE-0084 will not affect existing code.

## Alternatives Considered

* Chris Lattner: A narrower way to solve the same problem would be to allow a comma before the `)`, but *only* when there is a newline between them.

* Vlad S suggests introducing "newlines as separators for any comma-separated list, not limited by funcs/typles but also array/dicts/generic type list etc."
