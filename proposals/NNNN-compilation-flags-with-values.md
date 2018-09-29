# Accept Values for Custom Compilation Flags

* Proposal: [SE-NNNN](NNNN-compilation-flags-with-values.md)
* Authors: [John Holdsworth](https://github.com/johnno1962)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#19585](https://github.com/apple/swift/pull/19585)
* Toolchain: [available here](http://johnholdsworth.com/swift-LOCAL-2018-09-28-a-osx.tar.gz)
* Decision Notes: TBD
* Bugs: [SR-8818](https://bugs.swift.org/browse/SR-8818)

## Introduction

At present, the Swift compiler frontend is able to accept "custom compiler flags" on invocation using the `-DFLAG_NAME` option. These flags can be used in `#if` conditionals, however, is not able to accept values for these options. This proposal puts forward a simple implementation where values can be supplied using `-DFLAG_NAME=VALUE` where VALUE can be integer, float, string or boolean literals. When the compiler is invoked with these options, the identifier `FLAG_NAME` (or perhaps `#FLAG_NAME` could be considered) and be used in expressions as a value with internal scope in a Swift source file compiled with the option.

As an example, it would be possible to invoke the compiler as follows:

```shell
$ swift -DBUILD_NUMBER=1234 -DTOLERANCE=0.9 -DBUILD_DATE='"Sun 23 Sep 2018"' file.swift
```
and refer to these variables from the code:
```swift
print("Build number \(BUILD_NUMBER), built on \(BUILD_DATE)")
```

Swift-evolution thread: [Be able to supply values such as “-DBUILD_DATE=21/12/1953” to Swift compiler](https://forums.swift.org/t/be-able-to-supply-values-such-as-dbuild-date-21-12-1953-to-swift-compiler/11119)

## Motivation

When building an application it is often useful to embed information in the binary determined at build time to aid with support such as a build number, build date or version. It is also useful to build an application with particular tuneable parameters proved from the test/production build configuration such as a tolerance for results, sample rate of a signal or a URL. Up until now, this needed to be stored in the application's source files or an `Info.plist` or another resource but often it is not convenient to extract values from resources and sometimes not desirable that such parameter values be quite so public.

## Proposed solution

If this proposal is accepted, the existing Swift compiler frontend flag `"-D"` would be adapted so it is able to take values. Operation of the option without values would not be affected, the custom parameter being assumed to have a value `true` and it would also be `true`  if any value is provided from the point of view of `#if` and co. unless it had the value `false`. Other values would be categorized as either integer, float, string or boolean values by a cursory parsing and be made available as a global symbol that can be referred to in expressions in a Swift source file across the module.

In fact, they would not be actual Swift variables such as a fileprivate declaration but a form of "alias" as they are in other compilers where the expression will be parsed as if the user has entered that sequence of characters at that place in the source. This allows parameters to have an omni-type, determined late according to their context in an expression. For example, a with compiler argument `-DNUMBER=10`, `NUMBER` could have `Int` or `Float` or `Double` type depending on it's context in the expression or declaration. 

## Detailed design

In terms of implementation this feature is implemented in two steps. When lexing an identifier, a check is made to see if it has the name of a custom compilation flag and if so, it's value extracted. If the extracted value is surrounded in `"` characters it is assumed to be a string literal or if the entirety of the parameter parses as an int it is taken to be an int literal and so-on for float/double or boolean otherwise an error is emitted. If a type is recognized for a custom parameter, a literal compiler token of the type determined is created with the original source code range and a bit flag set on the token.

During parsing, if a token is encountered which has been flagged as a custom compilation flag literal its value is looked up from the map of compilation flags and the value substituted as the "Text" of it's `AST` node as it is created but, with the original source location. This was found to be the best way to have syntax highlighting (SourceKit) work. If the token has string, int or float literal type, the reference to the flag is then colorized appropriately in the Xcode source editor. For example, a reference to a string parameter will be coloured red, a numeric flag blue rather than various shades of green or black of a normal identifier reference in the IDE so the user has an indication it is a parameter. Subsequent compilation proceeds as before with the parameter value substituted in. 

## Source compatibility

This is an additive feature as custom compilation flags currently cannot have values or be referred to in expressions.

## Effect on ABI stability

N/A, creates literals as would a conventional source.

## Effect on API resilience

N/A.

## Alternatives considered

This proposal raises the possibility of a Swift source that is unable to compile unless the compiler is invoked with particular parameters which is a bit of a departure. As such it may be desirable to have a syntax at the point where these flags are referred to such as `#BUILD_NUMBER`, `$BUILD_NUMBER` or `#flag(BUILD_NUMBER)` as a indicator for the developer that a custom compilation flag value is in use. To an extent, this ship has already sailed however, and custom compiler flags are referred to unadorned in `#if` conditionals so this would seem inconsistent. By convention, these parameters would likely be all uppercase which would generally be sufficient to differentiate them.

In some ways, the obvious thing to do is for the compiler to do is generate a fileprivate variable for each flag in each source and object file of the module. This would loose the late typing feature of the functionality, be wasteful when parameters are not referred to and be a good deal more complex to implement. Better to introduce the idea of an alias and apply them during early stages of parsing.

At present. the boolean expression evaluator for `#if` statements is very limited and it is not in the scope of this proposal to extend this to allow say: `#if TOLERANCE > 0.9`. If this is needed, a runtime `if` can be used instead though this may result in a warning that code `"Will never be executed"`.

Whether string literals should require surrounding double quotes is open to discussion. This can be confusing on the command line as they also have a role in shell. It was decided to require them in order to be able to distinguish cleanly the string `"0"` from the numeric value `0`.