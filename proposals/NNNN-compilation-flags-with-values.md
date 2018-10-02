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

At present, the Swift compiler frontend is able to accept "custom compiler flags" on invocation using the `-DFLAG_NAME` option. These flags are currently used in `#if` conditionals and it is not possible to supply values for these options. This proposal puts forward a simple implementation where values can be supplied using `-DFLAG_NAME=VALUE` where VALUE can be integer, float, string or boolean literals. When the compiler is invoked with these options, a new construct `#flag("FLAG_NAME"[, default: <expression>])` can be used in expressions to refer to the literal value of the option as if it had been typed at that position in the source. The identifier `FLAG_NAME` can be used in `#if` conditional compilation directives as before.

As an example, it would be possible to invoke the compiler as follows:

```shell
$ swift -DBUILD_NUMBER=1234 -DTOLERANCE=0.9 -DBUILD_DATE='"Sun 23 Sep 2018"' file.swift
```
and refer to these variables from the code:
```swift
print("Build number \(#flag("BUILD_NUMBER")), built on \(#flag("BUILD_DATE"))")
```

As a refinement for embedding resources in executables, if the `FLAG_NAME` argument starts with an `@` the value of the flag will be used as the path to a file which contains the body of a raw string encoded in utf-8. The result will be a string literal as if the file was read in. For example:
```swift
let sql = #flag(“@LONG_SQL_FILE")
```
Or for a binary resource you could use:
```swift
let image = Data(base64Encoded: #flag(“@IMAGE_BASE64_FILE"))
```

Swift-evolution thread: [Be able to supply values such as “-DBUILD_DATE=21/12/1953” to Swift compiler](https://forums.swift.org/t/be-able-to-supply-values-such-as-dbuild-date-21-12-1953-to-swift-compiler/11119)

## Motivation

When building an application it is often useful to embed information in the binary determined at build time to aid with support such as a build number, build date or version. It is also useful to build an application with particular tuneable parameters proved from the test/production build configuration such as a tolerance for results, sample rate of a signal or a URL. Up until now, this needed to be stored in the application's source files or an `Info.plist` or another resource but often it is not convenient to extract values from resources and sometimes not desirable that such parameter values be quite so public.

## Proposed solution

If this proposal is accepted, the existing Swift compiler frontend flag `"-D"` would be adapted so it is able to take values. Operation of the option without values would not be affected, the custom parameter defaulting to have a value `true` and it would also be `true`  if any value is provided from the point of view of `#if` `#conditionals` unless it had the specific value `false`. Other values would be categorized as either integer, float, string or boolean values by a cursory parsing and be made available as through the new construct `#flag("FLAG_NAME")` that can be used in expressions in a Swift source file across the module.

This new construct is a form of "alias" as they are in other compilers where the expression will be parsed as if the user has entered that sequence of characters at that place in the source. This allows parameters to have an omni-type, determined late according to their context in an expression. For example, a with compiler argument `-DNUMBER=10`, `#flag("NUMBER")` could have `Int` or `Float` or `Double` type depending on it's context in the expression or declaration. 

## Detailed design

In terms of implementation, when parsing the new `#flag` construct, a check is made to see if it has the name argument of a custom compilation flag and if so, it's value extracted. The extracted value is sent to a new sub-instance of the Lexer and a token extracted. If this token is a string, numeric or boolean literal it is used as the AST "Expr" at the location in the source of the `#flag` construct or an error reported. With luck, the string identifying the parameter will be colorized according to the type of the literal in the IDE. If a compilation flag of that name is not found, the parser looks for a `, default:` argument to substitute for it or if there is no default specified an error is reported. If the flag name specified starts with an `@` the filepath in the compilation flag's value (with the `@` removed) is loaded and used as the body of an  uninterpreted raw string literal. 

## Source compatibility

This is an additive feature as custom compilation flags currently cannot have values or be referred to in expressions.

## Effect on ABI stability

N/A, creates literals as would a conventional source.

## Effect on API resilience

N/A.

## Alternatives considered

Initial versions of the proposal allowed users to refer to the compilation flag value as a sort of per-module global with a name such as `BUILD_NUMBER`, `#BUILD_NUMBER`, `$BUILD_NUMBER` or `#flag(BUILD_NUMBER)`. It was felt this didn't identify references to compilation flags sufficiently explicitly for developers.

In some ways, the obvious thing to do is for the compiler to do is generate a fileprivate variable for each flag in each source and object file of the module. This would loose the late typing feature of the functionality and be wasteful when parameters are not referred to. Better to introduce the idea of an alias referred to using the new construct and apply them during early stages of parsing.

At present. the boolean expression evaluator for `#if` statements is very limited and it is not in the scope of this proposal to extend this to allow say: `#if TOLERANCE > 0.9`. If this is needed, a runtime `if` can be used instead though this may result in a warning that code `"Will never be executed"`.

Whether string literals should require surrounding double quotes when supplied on the command line is open to discussion. This can be confusing as `"` also has a role in shell. It was decided to require them in order to be able to distinguish cleanly the string `"0"` from the numeric value `0`.

It was decided to repurpose the `-D` flag rather than add a new option for these parameter values as to an extent not being able to provide a value is more unexpected than expected. This also creates a single less confusing shared namespace between conditionals and the new `#flag` construct.