# Making `.self` After `Type` Optional

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Tanner Nelson](https://github.com/tannernelson)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Allow Types to be passable to functions without needing to explicitly reference `.self`. This is currently allowed for functions with only one parameter. [Bug Report](https://bugs.swift.org/browse/SR-899)

## Motivation

`.self` is unnecessary and can clutter a clean API. Take the following example of a web framework built in Swift.

### Desired Code

```swift
app.get("users", Int, "posts", String) { request, userId, postName in
	print("You requested the post named \(postName) from user #\(userId)")
}
// http://api.example.io/users/5/posts/foo
// prints "You requested the post named foo from user #5"
```

### Current State

```swift
app.get("users", Int.self, "posts", String.self) { request, userId, postName in
...
```

or

```swift
let i = Int.self
let s = String.self

app.get("users", i, "posts", s) { request, userId, postName in
...
```

With `.self` required, more code is necessary that ultimately provides less clarity and concision. Additionally, the current state of requiring `.self` in some places, and not requiring it in others is confusing to developers.

## Proposed solution

Make the use of `.self` optional everywhere. 

## Detailed design

Types can be passed anywhere by simply typing the name of the Type.

## Impact on existing code

Current Swift code uses a combination of just `Type` and `Type.self`. Making `.self` optional will not break any code.

## Alternatives considered

#### Making `.self` required

This fixes the confusion of being able to use both methods, but `.self` is unnecessary and clutters clean syntax.

#### Making `Type` (without `.self`) required

This would be less confusing to developers, but would break old code. 

