# "Raw" mode string escaping

* Proposal: [SE-NNNN](NNNN-raw-string-escaping.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: TBD
* Status: **Implementation ready**

* Implementation: [apple/swift#NNNNN](https://github.com/johnno1962/swift/commits/master)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-6362](https://bugs.swift.org/browse/SR-6362)

## Introduction

During the discussion on multi-line spring literals a mode for raw-escaped strings was discussed but postponed for later consideration. This proposal picks up this idea and suggests the smallest of changes be made to the Swift lexer to allow the entry of all string literals that contain unknown backslash escapes by prefixing them with "r" adopting the precedent from the Python language.

## Motivation

One area where this form of quoting would be useful is entering regular expressions. As patterns can often contain elements such as \w or \S these do not translate well to the existing string literal syntax resulting in strings such as 

    let sentence = "\\w+(\\s+\\w+)\\."
    
This is sometimes referred to as the "picket fencing" problem.

## Proposed solution

The proposal suggests a new "raw" string literal syntax by prefixing any string with an "r" character which alters slightly the behaviour of the compiler in realising the literal.

    let sentence = r"\w+(\s+\w+)*\."
    
In raw single line and multi-line literals, it is proposed existing escapes \\, \", \t, \r, \n, \u or \( are processed as before. You will always need to be able to escape " and if you do you'll need to have a way of escaping \ and \( is too useful to leave out so why not just say existing escapes are processed as is. Otherwise, if character following the \ is not one of those currently recognised it is not an escape and both characters are literally included in the string rather than give an error on compilation. This would seem to be the simplest rule. The one exception is \<actual_newline> which it could be argued should still report an error in non-triple quoted strings.

Some examples of raw mode literals and their existing literal equivalents:

r"\\\n\(var)\\n\"" == "\\\n\(var)\\n\""

r"\?\y\=" == "\\?\\y\\="

r"\
" == compiler error?


## Detailed design

The changes are confined to the file lib/Parse/Lexer.cpp and involves check for a flag whether the string was prefixed by r when processing unknown backslash escapes and is localised to the function Lexer::lexCharacter in the code. If the "r" introducer was present, both the backslash and the unknown character are passed into the literal in Lexer::getEncodedStringSegment otherwise the existing behaviour is retained of emitting an error. A further minor change is also required to the main switch statement in Lexer::lexImpl.

## Source compatibility

This is a purely additive change. The syntax proposed is not currently valid Swift.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

Some might argue for a "pure" raw unescaping string where no escapes are recognised at all but would seem an extreme position that would be less useful in practice. How then would you include a newline or " in a string? It would also be more difficult to implement.