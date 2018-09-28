# Accept Values for Custom Compilation Flags

* Proposal: [SE-NNNN](NNNN-compilation-flags-with-values.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#19585](https://github.com/apple/swift/pull/19585)
* Toolchain: [available here](http://johnholdsworth.com/swift-LOCAL-2018-09-28-a-osx.tar.gz)
* Decision Notes: ...
* Bugs: [SR-8818](https://bugs.swift.org/browse/SR-8818)

## Introduction

At present, the Swift compiler frontend is able to accept "custom compiler flags" using the `-DFLAG_NAME` option which can be used in `#if` conditionals. It is not able to accept values for these options however. This proposal puts forward a simple implementation where values can be supplied using `-DFLAG_NAME=VALUE` where VALUE can be integer, float, string or boolean literal and when the compiler is invoked with these options, the identifier `#FLAG_NAME` can be used in expressions to refer to that value as a literal.

As an example, it would be possible to invoke the compiler as follows:

```shell
$ swift -DBUILD_NUMBER=1234 -DTOLERANCE=0.9 -DBUILD_DATE='"Sun 23 Sep 2018"' file.swift
```
and refer to these variables from the code:
```swift
print("Build number \(#BUILD_NUMBER), built on \(#BUILD_DATE)")
```

Swift-evolution thread: [Be able to supply values such as “-DBUILD_DATE=21/12/1953” to Swift compiler](https://forums.swift.org/t/be-able-to-supply-values-such-as-dbuild-date-21-12-1953-to-swift-compiler/11119)

## Motivation

When building an application it is often useful to embed information in the binary to aid with support such as a build number, build date or version. It is also useful to build an application with particular tuneable parameters proved from the test/production build configuration such as a tolerance for results, sample rate of a signal or a URL. Up until now, this needed to be stored in the application's `Info.plist` or another resource file but often it is not convenient to extract values from resources and sometimes it is not desirable that parameter values be quite so public.

## Proposed solution

If this proposal is accepted, the existing Swift compiler frontend flag `"-D"` would be adapted so it is able to take values. Operation of the option without values would not be affected, the custom parameter being assumed to have a value `true` and if a value is provided it would be `true` from the point of view of #conditionals unless it has the value `false`. Other values would be categorized as either integer, float, string or boolean values by a early parsing of their value and be made available as a global symbol prefixed by a # that can be referred to in expressions in a Swift source file across the module. They would not be actual Swift variables such as a fileprivate declaration. Instead they would be a form of "alias" as they are in other compilers where the expression will be parsed as if the user has entered that sequence of characters at that place in the source. This allows parameters to have an omni-type, determined late according to their context in an expression. For example, a compiler argument `-DNUMBER=10` could have `Int` or `Float` or `Double` type depending on it's context in the expression or declaration. 

## Detailed design

In terms of implementation this feature is implemented in two steps. When lexing a #identifier, a check is made to see if it has the name of a custom compilation flag and if so, it's value extracted. If the extracted value is surrounded in `"` characters it is assumed to be a string literal or if the entirety of the parameter parses as an int the it is an int literal then likewise for float/double and boolean otherwise an error is emitted.

If the type is recognized for a custom parameter, a literal token is created of that type but with the original source code range and a bit flag set on the token object. During parsing, if a token is encountered which has been flagged as a custom compilation flag literal it is looked up and the value substituted as the "Text" of it's `AST` node as it is created but with the original source location. This was found to be the best way to have syntax highlighting (SourceKit) work as it should. If the token has string, int, float or boolean literal type, the reference to the flag is colorized appropriately in the Xcode source editor. For example, a reference to a string parameter will be coloured red, a numeric flag blue rather than the green or black of a normal identifier so the user has an indication it is an alias.

## Source compatibility

This is an additive feature as custom compilation flags currently cannot have values or be referred to in expressions.

## Effect on ABI stability

N/A, creates literals as would a conventional source.

## Effect on API resilience

N/A.

## Alternatives considered

This proposal raises the possibility of a Swift source that is unable to compile unless the compiler is invoked with particular parameters which is a bit of a departure. The original proposal placed compilation flags into the global namespace which is more consistent with their treatment in #conditionals but, requiring a # prefix when flags are referred to in expressions provides a indicator this is not an ordinary variable reference.

In some ways, the obvious thing to do is for the compiler to do is generate a fileprivate variable for each flag in each source and object file of the module. This would loose the late typing feature of the functionality, be wasteful when parameters are not referred to and be a good deal more complex to implement. Better to introduce the idea of an alias and apply them early during parsing.

It is not intended that any form of compile time expression evaluator be implemented i.e. `#if TOLERANCE > 0.9` is outside the scope of this proposal. If this is needed, the runtime `if` can be used though this may result in warnings that code `"Will never be executed"`.

Whether string literals should require surrounding double quotes which can be confusing on the command line as shell will strip them off is open to discussion. It was decided to require them to be able to distinguish the string `"0"` from the numeric value `0`.