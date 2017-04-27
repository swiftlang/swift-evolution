# Modernizing Swift's Debugging Identifiers

* Proposal: TBD
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

This proposal aims to eliminate Swift's use of "[screaming snake case](https://en.wikipedia.org/wiki/Snake_case)" like `__FILE__` and `__FUNCTION__` and replacing identifier instances with common [octothorpe-prefixed](https://en.wiktionary.org/wiki/octothorpe) [lower camel case](https://en.wikipedia.org/wiki/CamelCase) `#identifier` representations.

*The Swift-Evolution discussion of this topic took place in the "[Review] SE-0022: Referencing the Objective-C selector of a method" thread and then in its own "[Proposal] Eliminating Swift's Screaming Snake Case Identifiers" thread*

## Motivation

Swift's pre-processor offers built-in `__FILE__`, `__LINE__`, `__COLUMN__`, and `__FUNCTION__` identifiers. These expand to string and integer literals corresponding to a current location in source code. This feature provides high utility for logging, both tracing execution through logged messages and enabling developers to [capture error context](http://ericasadun.com/2015/08/27/capturing-context-swiftlang/).

The current identifiers owe their syntax to C's `__FILE__` and `__LINE__` macros. These are built into C's preprocessor and expanded before running the C-language parser. Swift's implementation differs from C's but offers similar functionality and, unfortunately, similar symbols. This proposal aims to break free of the historic chains of their unsightly screaming camel case, which look like boa constrictors [trying to digest](https://s-media-cache-ak0.pinimg.com/originals/59/ea/ee/59eaee788c31463b70e6e3d4fca5508f.jpg) fully swallowed keywords.

## Proposed solution

Using octothorpe-prefixed keywords offers several advantages:

* They match the existing `#available` keyword  (D. Gregor)
* They match SE-0022's already-accepted `#selector(...)` approach that reference a method's Objective-C selector (D. Gregor)
* They support targeted code completion (D. Gregor)
* They add a compiler-supported expression type that doesn't steal keywords, introducing a convention where `#` means "invoke compiler substitution logic here" (J. Rose)
* They'd provide short-term solutions for a yet-as-undesigned macro system  (D. Gregor)

## Detailed design

This proposal renames the following identifiers:

* `__FILE__` -> `#file`. 
* `__LINE__` -> `#line`
* `__COLUMN__` -> `#column`
* `__DSO_HANDLE__` -> `#dsoHandle`

This proposal adds `#filename` to avoid using `lastPathComponent` on #file references.

This proposal eliminates `__FUNCTION__`. It introduces `#symbol`, (e.g. Swift.Dictionary.Init(x:Int,y:String)), which summarizes context including module, type, and function. 

* A fully qualified symbol enables users to access exactly the information 
they desire. 
* It should contain parameter type information to properly
identify member overloads.

Each identifier will still expand at the call site,
ensuring that the behavior matches that from the current suite.

## Alternatives Considered

#### `#sourceLocation`

[SR-198](https://bugs.swift.org/browse/SR-198) requested the coalescing of the existing file, line, and function identifiers, potentially supporting a module representation as well. [Andrew Bennett](https://bugs.swift.org/secure/ViewProfile.jspa?name=bnut) offered an initial design: 
```swift
public struct SourceLocation: CustomDebugStringConvertible {
    init(file: String = __FILE__, line: Int = __LINE__, column: Int = __COLUMN__, function: String = __FUNCTION__) {
        self.file = file
        self.line = line
        self.column = column
        self.function = function
    }

    public let file: String
    public let line: Int
    public let column: Int
    public let function: String

    public var debugDescription: String {
        return "\(function) @ \(file):\(line):\(column)"
    }
}
```

#### Summarizing with `#context`

A `#context` identifier would provide a compound type to provide a *common*
well-defined tuple or struct summary of the current context with 
addressable elements. Offering addressable elements with a single 
identifier provides clean implementation. It permits developers 
to customize output based on current build settings without having 
to decompose the `#symbol` identifier output in logging routines.

Choosing which elements to represent could be problematic. Chris Lattner 
writes, "Splitting out module, type, method, or other information is prone to issues given that we allow nesting of types, nesting of functions, and perhaps nesting of modules some day.  Providing all of the different things that clients could want seems like a never-ending problem."

In support of addressable elements, Joseph Lord writes, "Module information would be useful for a logging library, possibly to print the information but possibly also to allow different log levels (e.g. info, debug, warning, error, criticalError) to be configured for each module in a project so that log spam is manageable and possibly adjustable at runtime."

In support of summaries, Remy Demerest writes, "[I] love the idea that source location would be one object that you can print to get the full story while still retaining the possibility to use each individual components as needed, which is probably the rarer case. I never find myself wanting only some of properties and usually don't include them simply because it takes longer to write the format properly, if I can get them all in one go it's certainly a win."

Other developers have expressed concern as to whether the fully qualified
`#symbol` name would be overly complicated. Dany St-Amant writes, "The fully qualified name could be quite long on occasion as I would expect it to include class hierarchy, nested class and nested function...Revealing the fully qualified name is useful for fixing bug and understanding the code flow, but some people could see it as a security concern, as it reveal how your code is structured."

## Implementation notes

Although the octothorpe-delineated `#line` identifier already exists in Swift for resetting line numbers (J. Lawrence), context can distinguish between uses. Joe Groff writes, "I'd prefer to use #line for this, and constrain the use of the current #line directive by context; like Chris said, we could require it to be the first thing after a newline, or we could adopt the `#line = ...` syntax a few people suggested."
