# Deprecate the default keyword

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-deprecate-the-default-keyword.md)
* Author(s): [Ross O'Brien](https://github.com/narrativium)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Deprecate the 'default' keyword, and replace it in switch statements with the 'else' keyword.

Swift-evolution thread: [link to the discussion thread for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/011237.html)

## Motivation

It is often desirable for a property to have a default state. The word 'default' may be desirable for the name of a constant or variable. In enumerations in particular, having a case named 'default' would be clearly understood. But because 'default' is a keyword in Swift, using it as an enumerated case requires the use of backticks, written thus:

enum Behaviour
{
    case `default`
    case edgeCase
}

'default''s sole meaning as a keyword in Swift is to signify the non-matching case in a switch statement, ensuring all cases are handled. This is a carryover from C; Swift-style switch statements match patterns and have where clauses, and behave more like a series of if-else-else conditionals than a mapping of value to case. As a result, 'default' has a synonym in Swift, 'case _', which Swift also recognises as matching any switched expression. As a result, 'default''s meaning as a keyword is redundant, and should be deprecated as a keyword to free its use for other purposes.

## Proposed solution

We propose to deprecate 'default' as a keyword. We propose to replace it in switch statements with the existing keyword 'else', whose meaning from if-else statements is already clear.

## Detailed design

This proposal removes a keyword from Swift, and replaces it with the existing keyword 'else'.

This would be legal code:
		switch footballTeam.numberOfPlayersOnPitch
		{
		case 11:
			print("enough players")
		case 0..<10:
			print("not enough players")
		else:
			print("too many players")
		}


## Impact on existing code

As 'default' would be deprecated, existing code would be broken and would not compile. However it seems that it should be straightforward to migrate existing code automatically, replacing 'default' with 'else' in switch statements.

## Alternatives considered

Haskell uses the 'otherwise' keyword. However, 'else' matches up more nicely with 'case' than 'otherwise' does, and 'else' is already a keyword in the language which developers will be familiar with.

'default' could simply be deprecated and not replaced. As mentioned, 'case _' already satisfies the uses of 'default'. However, it requires more understanding of wildcards, and is subjectively less readable than 'else'.
