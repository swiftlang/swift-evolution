# Shorthand Argument Renaming

* Proposal: [SE-NNNN](NNNN-shorthand-argument-renaming.md)
* Author: [Frédéric Blondiau](https://github.com/fblondiau)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Swift automatically provides shorthand argument names to inline closures which cleverly allows us to write

    reversed = names.sort( { $0 > $1 } )

This proposal suggests to use these new "names"

    reversed = names.sort( { #0 > #1 } )

Swift-evolution thread: [Shorthand Argument Renaming](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160530/019554.html)

## Motivation

The $n notation is generally used with positional parameters using one-based numbering.  Nearly everywhere, $1 is referring to argument 1; $2, to argument 2... with a special meaning for $0 (which could be the name of the function, or the full list of parameters).

A short way of accessing arguments is quite handy, but today the $n notation feels strange to Swift newcomers... like imported from UNIX scripting (but here zero-based, anyway) or from PHP variables.

The "$" symbol, today used only in these shorthand argument names, would be freed up for other usages (for example to create a new custom operator).

## Proposed solution

The #n notation is easy to spot in source code, and is more Swift-like -- as it is already used to access some other compiler related features, like #function for example.

Swift 3 already brings a lot of significant changes... this one may appear like a very small one, not even worth it.

But a focus of Swift 3 is to improve consistency of syntax, even in small ways... replacing $n with #n takes part in this goal : Swift is zero-based, and should not use $n, as languages using $n are one-based.

## Detailed design

n./a.

## Impact on existing code

$n just needs to be rewritten #n

## Alternatives considered

Using a default argument named "arguments" (like "error" in catch, "newValue" in setters or "oldValue" in a didSet observer) and access it like a Tuple

    reversed = names.sort( { arguments.0 > arguments.1 } )

was a first idea, but this was (of course) much less convenient.

So using _.0 or _.1 was has been considered, and even just .0 or .1

But, while association between tuples and function parameters in Swift has been removed, using this syntax would have brought back confusion.
