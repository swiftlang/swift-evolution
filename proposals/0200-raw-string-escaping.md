# "Raw" mode string literals

* Proposal: [SE-0200](0200-raw-string-escaping.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Active Review (March 16...26, 2018)**
* Implementation: [apple/swift#13055](https://github.com/apple/swift/pull/13055)
* Bugs: [SR-6362](https://bugs.swift.org/browse/SR-6362)

## Introduction

During the discussion on multi-line string literals a mode for "raw-mode" strings was discussed but postponed for later consideration. This proposal looks to move this idea forward and suggests the smallest of changes be made to the Swift lexer to allow the entry of single and multi-line "raw" string literals by prefixing them with "r". This adopts the precedent from the Python language. In raw literals, the \ character would have no special meaning.

## Motivation

One area where this form of quoting would be useful is entering regular expressions. As patterns can often contain elements such as \w or \S these do not translate well to the existing string literal syntax resulting in strings such as 

    let sentence = "\\w+(\\s+\\w+)\\."
    
This is sometimes referred to as the "picket fencing" problem. Another example is entering windows file paths.

## Proposed solution

The proposal suggests a new "raw" string literal syntax by prefixing any string with an "r" character which alters slightly the behaviour of the compiler in realising the literal. The \ character would loose it role as an escaping introducer altogether.

    let sentence = r"\w+(\s+\w+)*\."

Some examples of raw mode literals and their existing literal equivalents:

	r"\n\(var)\n" == "\\n\\(var)\\n"

	r"\?\y\=" == "\\?\\y\\="

	r"c:\windows\system32" == "c:\\windows\\system32"

	r"""
		Line One\
		Line Two\
		""" == "Line One\\\nLineTwo\\"

## Detailed design

The changes are confined to the file lib/Parse/Lexer.cpp and involves check for a flag whether the string was prefixed by r disabling processing processing of backslash escapes and is localised to the function Lexer::lexCharacter in the code. If the "r" introducer was present, both the backslash and the unknown character are passed into the literal in Lexer::getEncodedStringSegment. A further minor change is also required to the main switch statement in Lexer::lexImpl and Token.h to convey the flag from parsing to code generation phases.

## Source compatibility

This is a purely additive change. The syntax proposed is not currently valid Swift.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

An alternative proposal where known escapes retained their functionality and anything else passed through was considered but found to be too difficult to reason about in practice.
