# Making `.self` After `Type` Optional

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Tanner Nelson](https://github.com/tannernelson)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Allow Types to be passable to functions without needing to explicitly reference `.self`. This is currently allowed for functions with only one parameter. 

Here is the initial [Bug Report](https://bugs.swift.org/browse/SR-899) that led to this proposal. 

## Motivation

Inconsistencies in the requirement of `.self` are confusing to developers. Additionally, the `.self` requirement is unnecessary given Swift's robust type safety and can clutter a clean API.

Take the following example of a web framework built in Swift.

### Desired Code

```swift
app.get("users", Int, "posts", String) { request, userId, postName in
	print("You requested the post named \(postName) from user #\(userId)")
}
// http://api.example.io/users/5/posts/foo
// prints "You requested the post named foo from user #5"
```

Here we are trying to specify the type of item we would like to receive in our handler closure by simply passing the name of the type.

### Current State

However, the compiler currently complains that `.self` is required after type names. The compiling code looks like the following:

```swift
app.get("users", Int.self, "posts", String.self) { request, userId, postName in
...
```

or, by tricking the compiler a bit:

```swift
let i = Int.self
let s = String.self

app.get("users", i, "posts", s) { request, userId, postName in
...
```

With `.self` required, more code is necessary that ultimately provides less clarity and concision.

### Inconsistency 

The current state of requiring `.self` in some places, and not requiring it in others is confusing to developers.

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

### From Joe Groff

"As the designer in question, I've come around to this as well; our type system is sufficiently stronger than that other language that I think the consequences of accidentally typing `let x = Int` when you meant `let x = Int()` are far easier to understand."

### Community Response

"It seemed like there was general agreement to do something about the “.self” requirement when referencing types. I would personally like to see it go away."

"+1 for junking the .self requirement"

"Nice to see that this might be fixed. Evolution is making me happier and happier lately :)"

"Swift's type-checking engine is strong enough to merit not needing the redundant `.self` safety check. It feels like I'm doing something wrong when I need to use `.self`."

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
