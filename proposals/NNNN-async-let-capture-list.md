# Async-let closure captures

* Proposal: [SE-NNNN](NNNN-async-let-capture-list.md)
* Authors: [Dan Jabbour](https://github.com/picnicbob)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Not yet implemented
* Upcoming Feature Flag: `AsyncLetClosureBody`
* Review: ([pitch](https://forums.swift.org/t/pitch-async-let-capture-list/89153))

## Summary of changes

When the initializer of an `async let` is a closure literal, that closure
becomes the body of the child task, and its capture list is evaluated
synchronously in the enclosing function before the child task is created.

## Motivation

There is currently no pattern for capturing and scoping a variable for the
right-hand side of an `async let` declaration. SE-0317 describes the
right-hand side as an implicit `@Sendable` closure, so everything to the right
of the equals sign runs inside the child task. That includes the *creation* of
any closure literal written there, so even the capture list of a right-hand
side closure is evaluated asynchronously, in the child task, concurrently with
the code that follows. Capture lists normally mean "take this value now, in
this scope, and carry it into the closure." Inside an `async let` they
silently mean something different.

The result is that a programmer who writes the obvious thing gets surprising
behavior, and a programmer who wants a variable that is prepared synchronously
and scoped to the child task has no way to say so. This is especially useful
for creating `Sendable` values from non-`Sendable` ones for use on the
right-hand side, without cluttering the enclosing scope with variables that
will never be used there, much as closure capture lists work already.

Imagine a remote server that generates avatar images for a user to choose from
using the following Swift interface:

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

There are many ways to asynchronously request three images from the server
including `Task`, `TaskGroup`, or `async let`. Each one has tradeoffs and none
are particularly succinct:

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

The `async let` version is the most compact, but it is the only one that
cannot scope each request to the call that uses it. Writing a closure with a
capture list on the right-hand side looks like it should fix that, and it does
not, because the capture list is still evaluated in the child task.

## Proposed solution

When the initializer of an `async let` is a closure literal, the closure is used
*as* the child task's body rather than being a value created inside it. Its
capture list is evaluated at the point of the declaration, in the enclosing
function, in the same way as the capture list of the closure passed to
`Task { }` or `addTask { }`. Only once the captures have been formed does the
child task begin running the closure's body:

```swift
extension Server {
	func generateAvatarImages_AsyncLetClosure(for user: User) async throws -> [CGImage] {
		async let image1 = { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		async let image2 = { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		async let image3 = { [request = ImageRequest(name: user.name)] in
			try await self.avatarImage(for: request)
		}
		return try await [image1, image2, image3]
	}
}
```

Each `request` is created synchronously, handed to exactly one child task, and
not visible anywhere else. The type of `image1` is the closure's result type
(`CGImage`), not a function type.

This keeps the syntax programmers are most likely to write and gives it the
semantics they are most likely to expect. It adds no new syntax to `async let`
and reuses the existing closure capture list rather than duplicating it.

## Detailed design

### The rule

An `async let` initializer is a *task-body closure* if it is a closure
expression, written directly and without surrounding parentheses, and:

* the closure takes no parameters: it has either no signature or an explicit
  empty parameter list, such as `() async throws -> T in`, and it does not use
  anonymous parameters such as `$0`, and
* the `async let` pattern has no type annotation, or has a type annotation
  that is not a function type.

For a task-body closure:

1. The capture list, if any, is evaluated in the enclosing function when
   execution reaches the `async let` declaration, in source order, before the
   child task is created. These expressions follow the ordinary rules of the
   enclosing context: they may contain `try` and `await` if the enclosing
   function allows them, and an error thrown while forming a capture propagates
   out of the enclosing function immediately rather than being deferred to the
   `await` of the `async let`.
2. Capture specifiers behave as in any closure. `weak`, `unowned`, and
   `name = expression` are all valid, and `var` is not. Implicit captures of
   local variables and `self` are formed at the same point.
3. A child task is created whose body is the closure. The closure is
   type-checked as `@Sendable @concurrent () async throws -> T`, where `T` is the
   type of the binding. Because it is the task body, `try` and `await` inside
   the closure are required as they are in any closure.
4. Captured values are checked using the same isolation-crossing diagnostics
   that apply to the closure passed to `Task { }`: they must be `Sendable` or
   satisfy region-based isolation rules for being sent to a new task.

### What is not special-cased

Only a closure literal that is the *entire* initializer expression is
special-cased. The following keep their existing meaning, in which the
initializer is evaluated entirely inside the child task:

* A parenthesized closure: `async let f = ({ ... })`.
* A closure that takes parameters.
* A closure bound with a function-type annotation:
  `async let f: () -> Int = { ... }`.
* A closure that is immediately called: `async let x = { [y = 1] in y }()`.
* A closure that appears anywhere inside a larger expression, such as an
  operand, argument, or ternary branch.

The rule is therefore purely syntactic and local: a reader can tell from the
declaration alone which semantics apply. In particular, there is no question
about which closure is special when there are several. Neither closure here is
a task-body closure, so neither capture list is evaluated synchronously:

```swift
async let three = { [x = 1] in x }() + { [y = 2] in y }()
```

### Preserving the existing meaning

A programmer who actually wants a closure *value* produced asynchronously,
which is the only thing a bare closure literal means today, can write
`async let f = ({ ... })` or annotate the binding with a function type. Both
forms are reserved to preserve the existing behavior.

### Diagnostics

When the feature is not enabled, a closure literal as the entire `async let`
initializer produces a warning that its meaning will change, with fix-its to
parenthesize the closure (keeping today's behavior) or to add an explicit
function-type annotation.

## Source compatibility

This proposal changes the meaning of existing, valid code. Today
`async let f = { ... }` declares `f` with a function type, produced by a child
task that creates the closure. Under this proposal the same source declares `f`
with the closure's result type.

Code that awaited such a binding and called the result, such as `await f()`,
fails to type-check under the new rule rather than silently changing behavior.
This is expected to be rare, since creating a closure in a child task only to
return it is not a sensible pattern, and the migration to the old behavior is
mechanical (parentheses, as above). The new rule is behind the upcoming feature
flag `AsyncLetClosureBody`, so existing code is unaffected until a module opts in.

There is also a behavioral change for code that compiles both ways. Capture
lists of affected closures move from the child task to the enclosing function,
so a capture expression may run at a different time and on a different task.
The `async let` task function is already `@concurrent`, so the child task may
begin running before the originating task makes any further progress, and
evaluating the capture expressions first is therefore within the schedules the
current rule already permits. The exception is code that depends on the
identity of the executing task or thread when the capture expression runs. For
example, code that holds a mutex across the `async let` declaration, and
releases it before the `await`, could have a capture expression that acquires
the same mutex. Today it waits for the release and proceeds, and under this
proposal it would deadlock. This pattern is contrived: `async let` can only
appear in an `async` function, and the standard `Mutex.withLock` takes a
synchronous closure, so it cannot be written with the standard `Mutex`.

## ABI compatibility

This proposal has no ABI impact. It changes when capture expressions are
evaluated and which values are passed to the task-creation entry point, but it
does not change any runtime entry point, calling convention, or mangling.

## Implications on adoption

This feature can be adopted per module through the upcoming feature flag.
`async let` bindings are local, so adopting or un-adopting the feature does not
affect a library's public interface, source compatibility, or ABI. Package
authors who depend on the new semantics must require a tools version that
supports the flag.

## Future directions

### Autoclosures

Autoclosure arguments could receive similar treatment, so their captures are
formed in the enclosing scope. This is less pressing than for `async let`
because autoclosures are overwhelmingly non-escaping, and it is out of scope
for this proposal.

### `do` expressions

If Swift gains `do` expressions, they could be used as an `async let`
initializer, giving a way to run a multi-statement block as the child task
without a closure, and they would be a natural place for the same
synchronous-capture rule.

### Single-call initializers

Scoping a capture to one child task still requires a closure, even if the task
would otherwise be a single function call. A separate proposal could address
that case.

## Alternatives considered

### A capture list on `async let`

The original version of this proposal added a capture list between `async` and
`let`:

```swift
async[request = ImageRequest(name: user.name)] let image1 = self.avatarImage(for: request)
```

This is declarative, and it covers the single-function-call case without a
closure. The Language Steering Group preferred not to add special-case syntax
to `async let` for something already expressible with closure syntax, since
closures have many modifiers and the concern is gradually duplicating all of
them on `async let`. It also leaves the surprising semantics of a closure
capture list inside `async let` in place, which this proposal fixes directly.

### Special-casing an immediately-called closure

The Language Steering Group suggested special-casing `async let x = { ... }()`
so that the called closure is evaluated in the enclosing function and becomes
the task body:

```swift
async let image1 = { [request = ImageRequest(name: user.name)] in
	try await self.avatarImage(for: request)
}()
```

This shares the goal and most of the benefits of this proposal, and it does not
break any existing declaration, since the type of `image1` is unchanged. It was
not adopted for three reasons.

First, it casts a wide net. Putting an `async let` body in a single
immediately-called closure is common, and every such declaration would change
when its capture list runs, although only a small subset ever had a capture list
or cared. Declarations without captures would be affected for no benefit.

Second, it is less declarative. The trailing call adds nothing to the meaning
"use this closure as the child task," so the rule keys on a syntactic shape
rather than on what the programmer asked for.

Third, it leaves open why one closure is special and two are not. In
`{ [x = 1] in x }() + { [y = 2] in y }()` it is reasonable to expect both
captures to be synchronous, and a rule based on called closures has to explain
why they are not.

The tradeoff is that this proposal changes the type of existing declarations of
the form `async let f = { ... }`. That is a source break, but a loud one,
confined to code that creates a closure in a child task and returns it. The
called-closure design instead changes behavior silently for a much larger body
of code.

### Running `async let` synchronously to the first `await`

The initializer could instead run on the enclosing executor until its first
suspension point, as `Task.immediate` does. That would fix captures, function
arguments, and any other expression, but it is a much larger semantic change
for existing code, since it changes which executor runs arbitrary initializer
expressions rather than only the formation of captures. This proposal limits the
changed evaluation rules to capture formation in a single syntactic form.

### Evaluating all closure captures in an `async let` initializer synchronously

Every closure literal anywhere in an `async let` initializer could capture
synchronously. This would change the meaning of any initializer containing a
closure argument, such as `async let x = items.map { [y] in ... }`, where the
capture is evaluated as part of the call.

## Acknowledgments

Thank you to John McCall and the Language Steering Group for the early direction
towards closure captures instead of duplicating closure features, present and
future, on the left-hand side of `async let` as in the original proposal.

Vive la Swift!
