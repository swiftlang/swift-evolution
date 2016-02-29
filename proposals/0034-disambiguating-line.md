# Disambiguating Line Control Statements from Debugging Identifiers

* Proposal: [SE-0034](https://github.com/apple/swift-evolution/blob/master/proposals/0034-disambiguating-line.md)
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: **Accepted** ([Implementation Bug](https://bugs.swift.org/browse/SR-840))
* Review manager: [Chris Lattner](https://github.com/lattner)

## Introduction

In being accepted, Swift Evolution SE-0028 (https://github.com/apple/swift-evolution/blob/master/proposals/0028-modernizing-debug-identifiers.md) overloads
the use of `#line` to mean both an identifier that maps to a calling site's line number within a file and acts as part of a line control statement. This proposal nominates `#setline` to replace `#line` for file and line syntactic source control.

The discussion took place on-line in the [*\[Discussion\]: Renaming #line, the line control statement*](http://comments.gmane.org/gmane.comp.lang.swift.evolution/5815) thread.

## Motivation

Swift uses the the following grammar to define line control statements:

```
line-control-statement → #line
line-control-statement → #line line-number file-name
line-number → A decimal integer greater than zero
file-name → static-string-literal
```

The accepted implementation of SE-0028 disambiguates the two uses by requiring #line (the control statement) to appear at the first column. This is a stop-gap solution best remedied by renaming #line. 

The core team was not satisfied with the 'first token on a line' whitespace behavior required for overloading `#line`. Chris Lattner requested a discussion about renaming the old `#line` directive to something more specific and tailored to its purpose: "Once that name and syntax is settled, we can rename the directive and remove the whitespace rule." 

## Detailed design

```
line-control-statement → #setline
line-control-statement → #setline line-number file-name
line-number → A decimal integer greater than zero
file-name → static-string-literal­
```

## Alternatives considered

A more flexible grammar was suggested, however, as Kevin Ballard pointed out: 

> This feature isn't something end users are going to use. And it's not something that will ever reasonably apply to anything except `#file` and `#line`. This feature is only ever intended to be used by tools that auto-generate source files. The most important concerns here really should just be that whatever we use is trivial to generate correctly by even the simplest of tools and is readable. And since this won't ever apply to anything beyond `#file` and `#line`, there's no need to try to generalize this feature at all.

A variety of other keywords were put forward in the discussion and can be found in the online discussion.