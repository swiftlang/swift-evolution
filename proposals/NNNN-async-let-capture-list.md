# Async-let capture list

* Proposal: [SE-NNNN](NNNN-async-let-capture-list.md)
* Authors: Dan Jabbour (https://github.com/picnicbob)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Not yet implemented
* Review: ([pitch](https://forums.swift.org/t/pitch-async-let-capture-list/89153))

## Summary of changes

Add a capture list to async let declarations to synchronously capture
and scope variables for the right-hand side of the equals. 

## Motivation

There is currently no pattern for capturing and scoping a variable
for the right-hand side of an `async let` declaration. Because the
right-hand side is always executed asynchronously, even the capture
list of a right-hand side closure will be executed asynchronously
making it essentially useless.

I want a way to synchronously capture and declare a variable on the
left-hand side of the `async let` for use in the right-hand
(asynchronous) context.

This would be especially useful for creating `Sendable` types from
non-sendable types for use on the right-hand side without cluttering
the left-hand scope with variables that will never be used there,
much the same as capture lists in closures work already.

## Proposed solution

Adding a capture list to the left-hand side of the `async let` would
allow variables to be prepared for and scoped to only the right-hand
side.

Imagine a remote server that generates avatar images for a user to
choose from using the following Swift interface:

```swift
class User {
	var name: String = "Player 1"
}

struct Server: Sendable {
	private struct ImageRequest: Sendable {
		var name: String
		var seed: UInt64 = .random(in: UInt64.min...UInt64.max)
	}
	private func avatarImage(for request: ImageRequest) async throws -> CGImage {
		let data = try await URLSession.shared.data(for: <#T##URLRequest#>)
		try Task.checkCancellation()
		return <#CGImage#>
	}
}
```

There are many ways to asynchronously request three images from the
server including `Task`, `TaskGroup`, or `async let`. Each one has
tradeoffs and none are particularly succinct:

```swift
extension Server {
	/// - warning: This does not respect task cancellation
	func generateAvatarImages_Task(for user: User) async throws -> [CGImage] {
		let task1 = Task { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		let task2 = Task { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		let task3 = Task { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		return try await [task1.value, task2.value, task3.value]
	}
	/// - warning: This implementation is indented 2-levels deep
	func generateAvatarImages_TaskGroup(for user: User) async throws -> [CGImage] {
		try await withThrowingTaskGroup { taskGroup in
			taskGroup.addTask { [request = ImageRequest(name: user.name)] in
				try await self.avatarImage(for: request)
			}
			taskGroup.addTask { [request = ImageRequest(name: user.name)] in
				try await self.avatarImage(for: request)
			}
			taskGroup.addTask { [request = ImageRequest(name: user.name)] in
				try await self.avatarImage(for: request)
			}
			return try await taskGroup.reduce(into: [], { $0.append($1) })
		}
	}
	/// - warning: `request1` `request2` and `request3` are all in-scope by the end of this implementation
	func generateAvatarImages_AsyncLet(for user: User) async throws -> [CGImage] {
		var request1 = ImageRequest(name: user.name)
		async let image1 = self.avatarImage(for: request1)
		let request2 = ImageRequest(name: user.name)
		async let image2 = self.avatarImage(for: request2)
		let request3 = ImageRequest(name: user.name)
		async let image3 = self.avatarImage(for: request3)
		request1.name = "dummy" // why do I still have access to this? I just broke async safety.
		return try await [image1, image2, image3]
	}
}
```

Just like closures have capture lists to synchronously declare
a variable scoped only to the closure itself, the proposed improvement
adds a capture list to `async let` that declares variables available
only to the right-hand side of the equals:

```swift
extension Server {
	/// This sure looks nice
	func generateAvatarImages_AsyncLetCaptureList(for user: User) async throws -> [CGImage] {
		async[request = ImageRequest(name: user.name)] let image1 = self.avatarImage(for: request)
		async[request = ImageRequest(name: user.name)] let image2 = self.avatarImage(for: request)
		async[request = ImageRequest(name: user.name)] let image3 = self.avatarImage(for: request)
		return try await [image1, image2, image3]
	}
}
```
## Detailed design

The design is simple: An optional square-bracket capture list much
like the existing closure capture list that goes between the `async`
and `let` of the `async let` call with optional leading whitespace
and required trailing whitespace.

Valid examples:
```swift
async let myVar = ...
async[] let myVar = ...
async [] let myVar = ...
async[

] let myVar = ...
async [

] let myVar = ...

async
let myVar = ...
async[]
let myVar = ...
async []
let myVar = ...

async[capture1, capture2, capture3] let myVar = ...
async [capture1, capture2, capture3] let myVar = ...
async[
	capture1,
	capture2,
	capture3,
] let myVar = ...
async [
	capture1,
	capture2,
	capture3,
] let myVar = ...
async
[
	capture1,
	capture2,
	capture3,
] let myVar = ...

async[capture1, capture2, capture3]
let myVar = ...
async [capture1, capture2, capture3]
let myVar = ...

async
[capture1, capture2, capture3]
let myVar = ...
async
[
	capture1,
	capture2,
	capture3,
]
let myVar = ...
```

## Source compatibility

This change should not affect existing code as the existing
`async let` syntax is still valid and treated as an empty
capture list.

## ABI compatibility

This proposal is purely an extension of the ABI of the
standard library and does not change any existing features.

## Implications on adoption

As this change is simply constraining the scope of a variable this
feature can be freely adopted and un-adopted in source code with no
deployment constraints and without affecting source or ABI
compatibility.

## Future directions

This is envisioned as a one-time improvement to existing functionality
and has no long-term goals or future implications.

## Alternatives considered

One alternative to a capture list on the left-hand side is
special-casing a right-hand closure to synchronously execute
its capture list. In such an implementation the code could be written:

```swift
extension Server {
	func generateAvatarImages_AsyncLetClosureCaptureList(for user: User) async throws -> [CGImage] {
		async let image1 = { [request = ImageRequest(name: user.name)] in
			self.avatarImage(for: request)
		}()
		async let image2 = { [request = ImageRequest(name: user.name)] in
			self.avatarImage(for: request)
		}()
		async let image3 = { [request = ImageRequest(name: user.name)] in
			self.avatarImage(for: request)
		}()
		return try await [image1, image2, image3]
	}
}
```

While equally effective it adds the requirement that the async code be
contained in a closure which is otherwise unnecessary in this example.
It also puts the synchronously captured parameters on the right-hand side
of the `async let` equation which has historically been fully asynchronous.


## Acknowledgments

Vive la Swift!
