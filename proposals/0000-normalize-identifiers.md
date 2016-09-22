# Normalize Unicode Identifiers

* Proposal: [SE-NNNN](0000-normalize-identifiers.md)
* Author: [João Pinheiro](https://github.com/joaopinheiro)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal aims to introduce identifier normalization in order to prevent the unsafe and potentially abusive use of invisible or equivalent representations of Unicode characters in identifiers.

Swift-evolution thread: [Initial discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160620/021446.html), [Proposal draft](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160725/025555.html)

## Motivation

Even though Swift supports the use of Unicode for identifiers, these aren't yet normalized. This allows for different Unicode representations of the same characters to be considered distinct identifiers.

For example:

    let Å = "Angstrom"
    let Å = "Latin Capital Letter A With Ring Above"
    let Å = "Latin Capital Letter A + Combining Ring Above"

In addition to that, *default-ignorable* characters like the *Zero Width Space* and *Zero Width Non-Joiner* (exemplified below) are also currently accepted as valid parts of identifiers without any restrictions.

    let ab = "ab"
    let a​b = "a + Zero Width Space + b"

    func xy() { print("xy") }
    func x‌y() { print("x + <Zero Width Non-Joiner> + y") }

The use of default-ignorable characters in identifiers is problematical, first because the effects they represent are stylistic or otherwise out of scope for identifiers, and second because the characters themselves often have no visible display. It is also possible to misapply these characters such that users can create strings that look the same but actually contain different characters, which can create security problems.

## Proposed solution

Normalize Swift identifiers according to the normalization form NFC recommended for case-sensitive languages in the Unicode Standard Annexes [15](UAX15) and [31](UAX31) and follow the [Normalization Charts](NormalizationCharts).

[UAX15]: http://www.unicode.org/reports/tr15/
[UAX31]: http://www.unicode.org/reports/tr31/
[NormalizationCharts]: http://unicode.org/charts/normalization/

In addition to that, prohibit the use of *default-ignorable* characters in identifiers except in the special cases described in [UAX31](UAX31), listed below:

* Allow Zero Width Non-Joiner (U+200C) when breaking a cursive connection
* Allow Zero Width Non-Joiner (U+200C) in a conjunct context
* Allow Zero Width Joiner (U+200D) in a conjunct context

## Impact on existing code

The impact of this proposal on real-world code should be minimal. There is the potential for this change to affect cases where people may have used distinct (but identical looking) identifiers with different Unicode representations, but such cases could arguably be considered incorrect or broken code already.

## Alternatives considered

The option of ignoring *default-ignorable* characters in identifiers was also discussed, but it was considered to be more confusing and less secure than explicitly treating them as errors.

## Unaddressed Issues

There was some discussion around the issue of Unicode confusable characters, but it was considered to be out of scope for this proposal. Unicode confusable characters are a complicated issue and any possible solutions also come with significant drawbacks that would require more time and consideration.
