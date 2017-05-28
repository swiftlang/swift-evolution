# Remove C-style Semicolons for end of line

* Author(s): [João Nunes](https://github.com/jonasman)
* Status: *Proposed* (December 12, 2015)

## Introduction

The C-style end of the line Semicolons appears to be a carry-over from C and Objective-C and its use is optional. 
It is rarely used and pollutes the readability of the language. 

The value of a Semicolon is very limited and I believe its removal should be seriously considered.


## Advantages of Semicolons

It allows the programmer to write 2 or more consecutive instructions of code in one line.

## Disadvantages of Semicolons

1. Makes the code "ugly"
1. Affects the redability of the code when multiple code instructions are writen in one line
1. The usage of Semicolon must be decided before hand for every project in the coding style guidelines
1. If the Semicolon did not exist, I doubt it would be considered for inclusion in Swift 3.

## Proposed Approach

I suggest that the Semicolon be deprecated in Swift 2.x and removed entirely in Swift 3, with coverage removed from the Swift Programming Language to match the revisions in the current 2.2 update.

## Alternatives considered

Not removing Semicolon from Swift, keeping two ways of terminating lines.

## Impact on existing code

I searched all my personal and professional projects and found no evidence of the usage of a Semicolon in the end of the lines.
The coding style guidelines used in my professional projects also don't recommend the use of a Semicolon to terminate a line of code.

