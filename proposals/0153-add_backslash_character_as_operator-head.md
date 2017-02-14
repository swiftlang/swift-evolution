# Feature name

* Proposal: [SE-0153](0153-add_backslash_character_as_operator-head.md)
* Author: [Nicolas Fezans](https://github.com/nicoFe)
* Review Manager: TBD
* Status: **Awaiting review**

*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

This is a rather simple proposal to add '\' (backslash character) as a valid 
operator-head in the swift grammar. '\' is apparently currently only used inside 
string literals but would be useful as an operator and new operator character. 
It is both in the ASCII set and accessible on most keyboards.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170130/031461.html)

## Motivation

The "problem" was identified while developing some code during linear algebra as
I attempted to define the '\' operator as in MATLAB/Scilab/Octave (i.e. to solve 
linear systems of equations: A\B means "solve the linear system A*X=B for X"). 

Since the '\' character is not part of the swift grammar (expect within string 
literals) it is not possible to define it as an operator. It seems however that 
it would be meaningful to allow '\' as an operator itself as well as a character 
that can be used in a longer operator name.

## Proposed solution

Include '\' in the list of allowed 'operator-head' characters in the swift 
grammar. Based on the current summary of the grammar [Summary of the Swift 3.0.1 grammar](https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/zzSummaryOfTheGrammar.html), 
the line

operator-head → /  =  ­  +  !  *  %  <  >  &  |  ^  ~  ?

would be replaced by 

operator-head → /  =  ­  +  !  *  %  <  >  &  |  ^  ~  ? \

Since any 'operator-head' is automatically also an 'operator-character' that 
would also allow to define operator with '\' at any position (e.g. '\/' , '/\' , 
'\+\-' etc.).


## Detailed design

The problem and the proposed solution are so simple, that a detailed design does 
not seem relevant here.

## Source compatibility

This is not a source-breaking change (only new freedom added in the grammar).

## Effect on ABI stability

No effect on ABI stability expected.

## Effect on API resilience

On the long term, I would expect some of the enabled operator names to be part 
of some public APIs but my understanding is that it should not be breaking ABI.

## Alternatives considered

None. The only real alternative is to not do it, which could be motivated by 
having a different and better use of the '\' character outside of the string 
literals.

