# Allow Single Dollar Sign as Valid Identified

* Proposal: [SE-NNNN](NNNN-allow-single-dollar-sign-as-valid-identifier)
* Author: [Ankur Patel](https://github.com/ankurp)
* Review manager: TBD
* Status: **Awaiting review**

## Introduction

Currently, the Swift compiler does not throw any errors when `$`
character (U+0024) is used as an identifier by itself. For example:

```swift
let $ = 10
// OR
let $ : (Int) -> (Int) = { $0 * $0 }
// OR
class $ {}
```

Swift language should continue to support the use of `$` as a valid
identifier in future versions of Swift (>= 3.1).

## Motivation

Currently a lot of projects depend on the following library
[Dollar](https://github.com/ankurp/Dollar), which uses `$` character (U+0024)
as a namespace because it was a valid identifier since Swift was released.
The core team has decided to remove it as a valid character by merging this
[Pull Request](https://github.com/apple/swift/pull/3901)

The reason behind the removal of `$` character as a valid identifier is
to make the behavior consistent as `$` when suffixed with a valid identifier,
(i.e. \$[a-zA-Z_....]), will raise an error:

```swift
ERROR at line 1, col 5: expected numeric value following '$'
var $a = 5
```

Also they wish to reserve `$` for future debugging tools.

## Proposed solution

Allow `$` character (U+0024) to be used as a valid identifier without use of
any tick marks `` `$` ``.

## Impact on existing code

This proposal will preserve existing syntax of allowing `$` to be used as a
valid identifier by itself, so there will be no impact on existing code. But
if `$` (U+0024) character is removed from being used as a valid identifier
then it will impact a lot of developers who use the
[Dollar](https://github.com/ankurp/Dollar) library.

## Alternatives considered

The primarily alternative here is to allow for the breaking change and use 
`` `$` `` as the identifier in the [Dollar](https://github.com/ankurp/Dollar)
library.
