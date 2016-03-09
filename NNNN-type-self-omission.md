# Making `.self` After `Type` Optional

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Tanner Nelson](https://github.com/tannernelson)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Allow Types to be passable to functions without needing to explicitly reference `.self`. This is currently allowed for functions with only one parameter. 

Here is the initial [Bug Report](https://bugs.swift.org/browse/SR-899) that led to this proposal. 

## Motivation

`.self` is unnecessary and can clutter a clean API.

 Take the following example of a web framework built in Swift.

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

With `.self` required, more code is necessary that ultimately provides less clarity and concision. The current state of requiring `.self` in some places, and not requiring it in others is confusing to developers.

Here is a demonstration of the current inconsistency. 
```swift
func test<T: Any>(type: T.Type, two: String) {
    print(type)
}

func test<T: Any>(type: T.Type) {
    print(type)
}

test(Int.self)
test(Int)

test(Int.self, two: "")
test(Int, two: "") //Expected member name or constructor call after type name
``` 

## Proposed solution

Make the use of `.self` optional everywhere. 

## Detailed design

Types can be passed anywhere by simply typing the name of the Type. This will require coming up with an alternative way to disambiguate generics `Foo<T>` from less than expressions `Foo < T`. This is currently done by looking for a `.` or a `(` which makes the `.self` member variable required.

Ideas
- Require spaces around less than expressions
- Remove less than overload for comparing a type
- (Your idea here)

If at all possible, challenges in disambiguation should be a burden to the compiler, not the developer. 

## Impact on existing code

Current Swift code uses a combination of just `Type` and `Type.self`. Making `.self` optional will not break any code.

## Alternatives considered

#### Making `.self` required

This fixes the confusion of being able to use both methods, but `.self` is unnecessary and clutters clean syntax.

#### Making `Type` (without `.self`) required

This would be less confusing to developers, but would break old code. 

