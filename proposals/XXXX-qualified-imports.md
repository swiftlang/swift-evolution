# Qualified Imports Revisited

* Proposal: [SE-NNNN](NNNN-first-class-qualified-imports.md)
* Authors: [Robert Widmann](https://github.com/codafi), [TJ Usiyan](https://github.com/griotspeak)
* Status: **Awaiting review**
* Review manager: TBD


## Introduction

We propose a complete overhaul of the qualified imports syntax and semantics.

## Motivation

The existing syntax for qualified imports from modules is needlessly explicit, does not compose, and has a default semantics that dilutes the intended meaning of the very operation itself.  Today, a qualified import looks something like this

```swift
import struct Foundation.Date
```

This means that clients of Foundation that wish to see only `Date` must know the exact kind of declaration that identifier is.  In addition, though this import specifies exactly one class be imported from Foundation, the actual semantics mean Swift will recursively open all of Foundation's submodules so you can see, and use, every other identifier anyway - and they are not filtered from code completion.  Qualified imports deserve to be first-class in Swift, and that is what we intend to make them with this proposal.

## Proposed solution

The grammar and semantics of qualified imports will change completely with the addition of *import qualifiers* and *import directives*.  We also introduce two new contextual keywords: `using` and `hiding`, to facilitate fine-grained usage of module contents.

## Detailed design

Qualified import syntax will be revised to the following

```
import-decl -> import <import-path> <(opt) import-directive-list>
import-path -> <identifier>
            -> <identifier>.<identifier>
import-directive-list -> <import-directive>
                      -> <import-directive> <import-directive-list>
import-directive -> using (<identifier>, ...)
                 -> hiding (<identifier>, ...)
```

This introduces the concept of an import *directive*.  An import directive is a file-local modification of an imported identifier. A directive can be one of 2 operations:

1) *using*: The *using* directive is followed by a list of identifiers for top-level nominal declarations within the imported module that should be exposed to this file.  

```swift
// The only visible parts of Foundation in this file are 
// Foundation.Date, Foundation.DateFormatter, and Foundation.DateComponents
//
// Previously, this was
// import struct Foundation.Date
// import struct Foundation.DateFormatter
// import struct Foundation.DateComponents
import Foundation using (Date, DateFormatter, DateComponents)
```

2) *hiding*: The `hiding` directive is followed by a list of identifiers within the imported module that should be hidden from this file.

```swift
// Imports all of Foundation except `Date`
import Foundation hiding (Date)
```

As today, all hidden identifiers do not hide the type, they merely hide that type’s 
members and its declaration.  For example, this means values of hidden types are
still allowed.  Unlike the existing implementation, using their members is forbidden.

```swift
// Imports `DateFormatter` but the declaration of `Date` is hidden.
import Foundation using (DateFormatter)

var d = DateFormatter().date(from: "...") // Valid
var dt : Date = DateFormatter().date(from: "...") // Invalid: Cannot use name of hidden type.
d.addTimeInterval(5.0) // Invalid: Cannot use members of hidden type.
```

Import directives chain to one another and can be used to create a fine-grained module import:

```swift
// This imports Swift.Int, Swift.Double, and Swift.String but hides Swift.String.UTF8View
import Swift using (String, Int, Double) 
             hiding (String.UTF8View)
```

Directive chaining occurs left-to-right:

```swift
// This says to 1) Use Int 2) Hide String. It is invalid
// because 1) Int is available 2) String is not, error.
import Swift using (Int) hiding (String)
// Valid.  This will be merged as `using (Int)`
import Swift using () using (Int)
// Valid.  This will be merged as `hiding (String, Double)`
import Swift hiding (String) hiding (Double) hiding ()
// Valid (if redundant). This will be merged as `using ()`
import Swift using (String) hiding (String)
```

Because import directives are file-local, they will never be exported along with the module that declares them.

## Impact on existing code

Existing code that is using qualified module import syntax (`import {func|class|typealias|class|struct|enum|protocol} <qualified-name>`) will be deprecated and should be removed or migrated. 

## Alternatives considered

A previous iteration of this proposal introduced an operation to allow the renaming of identifiers, especially members.  The original intent was to allow file-local modifications of APIs consumers felt needed to conform to their specific coding style.  On review, we felt the feature was not as significant as to warrant inclusion and was ripe for abuse in large projects.
