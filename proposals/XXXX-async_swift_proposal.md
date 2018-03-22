# Async/Await for Swift

* Proposal: SE-XXXX
* Authors: [Chris Lattner](https://github.com/lattner), [Joe Groff](https://github.com/jckarter)

## Introduction

Modern Cocoa development involves a lot of asynchronous programming using closures and completion handlers, but these APIs are hard to use.  This gets particularly problematic when many asynchronous operations are used, error handling is required, or control flow between asynchronous calls gets complicated.  This proposal describes a language extension to make this a lot more natural and less error prone.

This paper introduces a first class [Coroutine model](https://en.wikipedia.org/wiki/Coroutine) to Swift. Functions can opt into to being *async*, allowing the programmer to compose complex logic involving asynchronous operations, leaving the compiler in charge of producing the necessary closures and state machines to implement that logic.

It is important to understand that this is proposing compiler support that is completely concurrency runtime-agnostic.  This proposal does not include a new runtime model (like "actors") - it works just as well with GCD as with pthreads or another API. Furthermore, unlike designs in other languages, it is independent of specific coordination mechanisms, such as futures or channels, allowing these to be built as library feature. The only runtime support required is compiler support logic for transforming and manipulating the implicitly generated closures.

This draws some inspiration from an earlier proposal written by [Oleg Andreev](https://github.com/oleganza), available [here](https://gist.github.com/oleganza/7342ed829bddd86f740a).  It has been significantly rewritten by [Chris Lattner](https://github.com/lattner) and [Joe Groff](https://github.com/jckarter).

## Motivation: Completion handlers are suboptimal

To provide motivation for why it is important to do something here, lets look at some of the problems that Cocoa (and server/cloud) programmers frequently face.

#### Problem 1: Pyramid of doom

Sequence of simple operations is unnaturally composed in the nested blocks.  Here is a
made up example showing this:

```swift
func processImageData1(completionBlock: (result: Image) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource in
        loadWebResource("imagedata.dat") { imageResource in
            decodeImage(dataResource, imageResource) { imageTmp in
                dewarpAndCleanupImage(imageTmp) { imageResult in
                    completionBlock(imageResult)
                }
            }
        }
    }
}

processImageData1 { image in
    display(image)
}
```

This "pyramid of doom" makes it difficult to keep track of code that is running, and the stack of closures leads to many second order effects.

#### Problem 2: Error handling

Handling errors becomes difficult and very verbose. Swift 2 introduced an error handling model for synchronous code, but callback-based interfaces do not derive any benefit from it:

```swift
func processImageData2(completionBlock: (result: Image?, error: Error?) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource, error in
        guard let dataResource = dataResource else {
            completionBlock(nil, error)
            return
        }
        loadWebResource("imagedata.dat") { imageResource, error in
            guard let imageResource = imageResource else {
                completionBlock(nil, error)
                return
            }
            decodeImage(dataResource, imageResource) { imageTmp, error in
                guard let imageTmp = imageTmp else {
                    completionBlock(nil, error)
                    return
                }
                dewarpAndCleanupImage(imageTmp) { imageResult in
                    guard let imageResult = imageResult else {
                        completionBlock(nil, error)
                        return
                    }
                    completionBlock(imageResult)
                }
            }
        }
    }
}

processImageData2 { image, error in
    guard let image = image else {
        error("No image today")
        return
    }
    display(image)
}
```

#### Problem 3: Conditional execution is hard and error-prone

Conditionally executing an asynchronous function is a huge pain.  Perhaps the best approach is to write half of the code in a helper "continuation" closure that is conditionally executed, like this:

```swift
func processImageData3(recipient: Person, completionBlock: (result: Image) -> Void) {
    let continuation: (contents: image) -> Void = {
      // ... continue and call completionBlock eventually
    }
    if recipient.hasProfilePicture {
        continuation(recipient.profilePicture)
    } else {
        decodeImage { image in
            continuation(image)
        }
    }
}
```

#### Problem 4: Many mistakes are easy to make

It's easy to bail out by simply returning without calling the appropriate block. When forgotten, the issue is very hard to debug:

```swift
func processImageData4(completionBlock: (result: Image?, error: Error?) -> Void) {
    loadWebResource("dataprofile.txt") { dataResource, error in
        guard let dataResource = dataResource else {
            return // <- forgot to call the block
        }
        loadWebResource("imagedata.dat") { imageResource, error in
            guard let imageResource = imageResource else {
                return // <- forgot to call the block
            }
            ...
        }
    }
}
```

When you do not forget to call the block, you can still forget to return after that.
Thankfully `guard` syntax protects against that to some degree, but it's not always relevant.

```swift
func processImageData5(recipient:Person, completionBlock: (result: Image?, error: Error?) -> Void) {
    if recipient.hasProfilePicture {
        if let image = recipient.profilePicture {
            completionBlock(image) // <- forgot to return after calling the block
        }
    }
    ...
}
```

#### Problem 5: Because completion handlers are awkward, too many APIs are defined synchronously

This is hard to quantify, but the authors believe that the awkwardness of defining and using asynchronous APIs (using completion handlers) has led to many APIs being defined with apparently synchronous behavior, even when they can block.  This can lead to problematic performance and responsiveness problems in UI applications - e.g. spinning cursor.  It can also lead to the definition of APIs that cannot be used when asynchrony is critical to achieve scale, e.g. on the server.

#### Problem 6: Other "resumable" computations are awkward to define

The problems described above are on specific case of a general class of problems involving "resumable" computations.   For example, if you want to write code that produces a list of squares of numbers, you might write something like this:

```swift
for i in 1...10 {
    print(i*i)
}
```

However, if you want to write this as a Swift sequence, you have to define this as something that incrementally produces values.  There are multiple ways to do this (e.g. using `AnyIterator`, or the `sequence(state:,next:)` functions), but none of them approach the clarity and obviousness of the imperative form.

In contrast, languages that have generators allow you to write something more close to this:

```swift
func getSequence() -> AnySequence<Int> {
    let seq = sequence {
        for i in 1...10 {
            yield(i*i)
        }
    }
    return AnySequence(seq)
}
```

It is the responsibility of the compiler to transform the function into a form that incrementally produces values, by producing a state machine.



## Proposed Solution: Coroutines

These problem have been faced in many systems and many languages, and the abstraction of [coroutines](https://en.wikipedia.org/wiki/Coroutine) is a standard way to address them.  Without delving too much into theory, coroutines are an extension of basic functions that allow a function to return a value *or be suspended*.  They can be used to implement generators, asynchronous models, and other capabilities - there is a large body of work on the theory, implementation, and optimization of them.

This proposal adds general coroutine support to Swift, biasing the nomenclature and terminology towards the most common use-case: defining and using asynchronous APIs, eliminating many of the problems working with completion handlers.  The choice of terminology (`async` vs `yields`) is a bikeshed topic which needs to be addressed, but isn't pertinent to the core semantics of the model.  See [Alternate Syntax Options](#alternate-syntax-options) at the end for an exploration of syntactic options in this space.

It is important to understand up-front, that the proposed coroutine model does not interface
with any particular concurrency primitives on the system: you can think of it as syntactic
sugar for completion handlers.  This means that the introduction of coroutines would not
change the queues that completion handlers are called on, as happens in some other systems.

### Async semantics

Today, function types can be normal or `throw`ing.  This proposal extends them to also be allowed to be `async`.  These are all valid function types:

```swift
   (Int) -> Int               // #1: Normal function
   (Int) throws -> Int        // #2: Throwing function
   (Int) async -> Int         // #3: Asynchronous function
   (Int) async throws -> Int  // #4: Asynchronous function, can also throw.
```

Just as a normal function (#1) will implicitly convert to a throwing function (#2), an async function (#3) implicitly converts to a throwing async function (#4).

On the function declaration side of the things, you can declare a function as being asynchronous just as you declare it to be throwing, but use the `async` keyword:

```swift
func processImageData() async -> Image { ... }

// Semantically similar to this:
func processImageData(completionHandler: (result: Image) -> Void) { ... }
```

Calls to `async` functions can implicitly suspend the current coroutine.  To make this apparent to maintainers of code, you are required to "mark" expressions that call `async` functions with the new `await` keyword (exactly analogously to how `try` is used to mark subexpressions that contain throwing calls).  Putting these pieces together, the first example (from the pyramid of doom explanation, above) can be rewritten in a more natural way:

```swift
func loadWebResource(_ path: String) async -> Resource
func decodeImage(_ r1: Resource, _ r2: Resource) async -> Image
func dewarpAndCleanupImage(_ i : Image) async -> Image

func processImageData1() async -> Image {
  let dataResource  = await loadWebResource("dataprofile.txt")
  let imageResource = await loadWebResource("imagedata.dat")
  let imageTmp      = await decodeImage(dataResource, imageResource)
  let imageResult   =  await dewarpAndCleanupImage(imageTmp)
  return imageResult
}
```

Under the hood, the compiler rewrites this code using nested closures like in example `processImageData1` above. Note that every operation starts only after the previous one has completed, but each call site to an `async` function could suspend execution of the current function.

Finally, you are only allowed to invoke an `async` function from within another `async` function or closure.  This follows the model of Swift 2 error handling, where you cannot call a throwing function unless you're in a throwing function or inside of a `do/catch` block.


#### Entering and leaving async code

In the common case, async code ought to be invoking other async code that has been dispatched by the framework the app is built on top of, but at some point, an async process needs to spawn from a controlling synchronous context, and the async process needs to be able to suspend itself and allow its **continuation** to be scheduled by the controlling context. We need a couple of primitives to
enable entering and suspending an async context:

```swift
// NB: Names subject to bikeshedding. These are low-level primitives that most
// users should not need to interact with directly, so namespacing them
// and/or giving them verbose names unlikely to collide or pollute code
// completion (and possibly not even exposing them outside the stdlib to begin
// with) would be a good idea.

/// Begins an asynchronous coroutine, transferring control to `body` until it
/// either suspends itself for the first time with `suspendAsync` or completes,
/// at which point `beginAsync` returns. If the async process completes by
/// throwing an error before suspending itself, `beginAsync` rethrows the error.
func beginAsync(_ body: () async throws -> Void) rethrows -> Void

/// Suspends the current asynchronous task and invokes `body` with the task's
/// continuation closure. Invoking `continuation` will resume the coroutine
/// by having `suspendAsync` return the value passed into the continuation.
/// It is a fatal error for `continuation` to be invoked more than once.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> ()) -> ()
) async -> T

/// Suspends the current asynchronous task and invokes `body` with the task's
/// continuation and failure closures. Invoking `continuation` will resume the
/// coroutine by having `suspendAsync` return the value passed into the
/// continuation. Invoking `error` will resume the coroutine by having
/// `suspendAsync` throw the error passed into it. Only one of
/// `continuation` and `error` may be called; it is a fatal error if both are
/// called, or if either is called more than once.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> (),
           _ error: @escaping (Error) -> ()) -> ()
) async throws -> T
```

These are similar to the "shift" and "reset" primitives of [delimited continuations](https://en.wikipedia.org/wiki/Delimited_continuation).  These enable a non-async function to call an `async` function.  For example, consider this
`@IBAction` written with completion handlers:

```swift
@IBAction func buttonDidClick(sender:AnyObject) {
  // 1
  processImage(completionHandler: {(image) in
    // 2
    imageView.image = image
  })
  // 3
}
```

This is an essential pattern, but is itself sort of odd: an `async` operation is being fired off immediately (#1), then runs the subsequent code (#3), and the completion handler (#2) runs at some time later -- on some queue (often the main one).  This pattern frequently leads to mutation of global state (as in this example) or to making assumptions about which queue the completion handler is run on.  Despite these problems, it is essential that the model encompasses this pattern, because it is a practical necessity in Cocoa development.  With this proposal, it would look like this:

```swift
@IBAction func buttonDidClick(sender:AnyObject) {
  // 1
  beginAsync {
    // 2
    let image = await processImage()
    imageView.image = image
  }
  // 3
}
```

These primitives enable callback-based APIs to be wrapped up as async coroutine APIs:

```swift
// Legacy callback-based API
func getStuff(completion: (Stuff) -> Void) { ... }

// Swift wrapper
func getStuff() async -> Stuff {
  return await suspendAsync { continuation in
    getStuff(completion: continuation)
  }
}
```

Functionality of concurrency libraries such as libdispatch and pthreads can
also be presented in coroutine-friendly ways:

```swift
extension DispatchQueue {
  /// Move execution of the current coroutine synchronously onto this queue.
  func syncCoroutine() async -> Void {
    await suspendAsync { continuation in
      sync { continuation }
    }
  }

  /// Enqueue execution of the remainder of the current coroutine
  /// asynchronously onto this queue.
  func asyncCoroutine() async -> Void {
    await suspendAsync { continuation in
      async { continuation }
    }
  }
}

func queueHopping() async -> Void {
  doSomeStuff()
  await DispatchQueue.main.syncCoroutine()
  doSomeStuffOnMainThread()
  await backgroundQueue.asyncCoroutine()
  doSomeStuffInBackground()
}
```

Generalized abstractions for coordinating coroutines can also be built. The simplest of these is a [future](https://en.wikipedia.org/wiki/Futures_and_promises), a value that represents a future value which may not be resolved yet.  The exact design for a Future type is out of scope for this proposal (it should be its own follow-on proposal), but an example proof of concept could look like this:

```swift
class Future<T> {
  private enum Result { case error(Error), value(T) }
  private var result: Result? = nil
  private var awaiters: [(Result) -> Void] = []

  // Fulfill the future, and resume any coroutines waiting for the value.
  func fulfill(_ value: T) {
    precondition(self.result == nil, "can only be fulfilled once")
    let result = .value(value)
    self.result = result
    for awaiter in awaiters {
      // A robust future implementation should probably resume awaiters
      // concurrently into user-controllable contexts. For simplicity this
      // proof-of-concept simply resumes them all serially in the current
      // context.
      awaiter(result)
    }
    awaiters = []
  }

  // Mark the future as having failed to produce a result.
  func fail(_ error: Error) {
    precondition(self.result == nil, "can only be fulfilled once")
    let result = .error(error)
    self.result = result
    for awaiter in awaiters {
      awaiter(result)
    }
    awaiters = []
  }

  func get() async throws -> T {
    switch result {
    // Throw/return the result immediately if available.
    case .error(let e)?:
      throw e
    case .value(let v)?:
      return v
    // Wait for the future if no result has been fulfilled.
    case nil:
      return await suspendAsync { continuation, error in
        awaiters.append({
          switch $0 {
          case .error(let e): error(e)
          case .value(let v): continuation(v)
          }
        })
      }
    }
  }

  // Create an unfulfilled future.
  init() {}

  // Begin a coroutine by invoking `body`, and create a future representing
  // the eventual result of `body`'s completion.
  convenience init(_ body: () async -> T) {
    self.init()
    beginAsync {
      do {
        self.fulfill(await body())
      } catch {
        self.fail(error)
      }
    }
  }
}
```

To reiterate, it is well known that this specific implementation has performance and API weaknesses, the point is merely to sketch how an abstraction like this could be built on top of `async`/`await`.

Futures allow parallel execution, by moving `await` from the call to the result when it is needed, and wrapping the parallel calls in individual `Future` objects:

```swift
func processImageData1a() async -> Image {
  let dataResource  = Future { await loadWebResource("dataprofile.txt") }
  let imageResource = Future { await loadWebResource("imagedata.dat") }
  
  // ... other stuff can go here to cover load latency...
  
  let imageTmp    = await decodeImage(dataResource.get(), imageResource.get())
  let imageResult = await dewarpAndCleanupImage(imageTmp)
  return imageResult
}
```

In the above example, the first two operations will start one after another, and the unevaluated computations are wrapped into a `Future` value.  This allows all of them to happen concurrently (in a way that need not be defined by the language or by the `Future` implementation), and the function will wait for completion of them before decoding the image.  Note that `await` does not block flow of execution: if the value is not yet ready, execution of the current `async` function is suspended, and control flow passes to something higher up in the stack.

Other coordination abstractions such as [Communicating Sequential Process channels](https://en.wikipedia.org/wiki/Communicating_sequential_processes) or [Concurrent ML events](https://wingolog.org/archives/2017/06/29/a-new-concurrent-ml) can also be developed as libraries for coordinating coroutines; their implementation is left as an exercise for the reader.

## Conversion of imported Objective-C APIs

Full details are beyond the scope of this proposal, but it is important to enhance the importer to project Objective-C completion-handler based APIs into `async` forms.  This is a transformation comparable to how `NSError**` functions are imported as `throws` functions.  Having the importer do this means that many Cocoa APIs will be modernized en masse.

There are multiple possible designs for this with different tradeoffs.  The maximally source compatible way to do this is to import completion handler-based APIs in two forms: both the completion handler and the `async` form.  For example, given:

```objc
// Before
- (void) processImageData:(void(^)())completionHandler;
- (void) processImageData:(void(^)(Image* __nonnull image))completionHandler;
- (void) processImageData:(void(^)(Image* __nullable image1, NSError* __nullable error))completionHandler;
- (void) processImageData:(void(^)(Image* __nullable half1, Image* __nullable half2, NSError* __nullable error))completionHandler;
- (void) processImageData:(void(^)(NSError* __nullable error))completionHandler;
```

The declarations above are imported both in their normal completion handler form, but also in their nicer `async` forms:

```swift
func processImageData() async
func processImageData() async -> Image
func processImageData() async throws -> Image
func processImageData() async throws -> (half1: Image, half2: Image)
func processImageData() async throws
```

There are many details that should be defined as part of this importing process - for example:
- What are the exact rules for the transformation?
- Are multiple result functions common enough to handle automatically?
- Would it be better to just import completion handler functions only as `async` in Swift 5 mode, forcing migration?
- What should happen with the non-Void-returning completion handler functions (e.g. in `URLSession`)?
- Should `Void`-returning methods that are commonly used to trigger asynchronous operations in response to events, such as `IBAction` methods, be imported as `async -> Void`?

Without substantial ObjC importer work, making a clean break and forcing migration in Swift 5 mode would be the most practical way to preserve overridability, but would create a lot of churn in 4-to-5 migration. Alternatively, it may be acceptable to present the `async` versions as `final` wrappers over the underlying callback-based interfaces; this would subclassers to work with the callback-based interface, but there are generally fewer subclassers than callers.

## Interaction with existing features

This proposal dovetails naturally with existing language features in Swift, here are a few examples:

#### Error handling

Error handling syntax introduced in Swift 2 composes naturally with this asynchronous model.

```swift
// Could throw or be interrupted:
func processImageData() async throws -> Image

// Semantically similar to:
func processImageData(completionHandler: (result: Image?, error: Error?) -> Void)
```

Our example thus becomes (compare with the example `processImageData2`):

```swift
func loadWebResource(_ path: String) async throws -> Resource
func decodeImage(_ r1: Resource, _ r2: Resource) async throws -> Image
func dewarpAndCleanupImage(i: Image) async throws -> Vegetable

func processImageData2() async throws -> Image {
  let dataResource  = try await loadWebResource("dataprofile.txt")
  let imageResource = try await loadWebResource("imagedata.dat")
  let imageTmp      = try await decodeImage(dataResource, imageResource)
  let imageResult   = try await dewarpAndCleanupImage(imageTmp)
  return imageResult
}
```

Coroutines address one of the major shortcomings of the Swift 2 error model,
that it did not interoperate well with callback-oriented asynchronous APIs and
required clumsy boilerplate to propagate errors across callback boundaries.


#### Closure type inference

Because the `await` keyword is used at all points where execution may be suspended, it is simple for the compiler to determine whether a closure is `async` or not: it is if the body includes an `await`.  This works exactly the same way that the presence of `try` in a closure causes it to be inferred as a throwing closure.  You can also explicitly mark a closure as `async` using the standard form of:

```swift
let myClosure = { () async -> () in ... }
```

#### `defer` and abandonment

Coroutines can be suspended, and while suspended, there is the potential for a coroutine's execution to be **abandoned** if all references to its continuation
closure(s) are released without being executed:

```swift
/// Shut down the current coroutine and give its memory back to the
/// shareholders.
func abandon() async -> Never {
  await suspendAsync { _ = $0 }
}
```

It is to be expected that, upon abandonment, any references captured in wait by the continuation should be released, as with any closure. However, there may be other cleanup that must be guaranteed to occur. `defer` serves the general
role of "guaranteed cleanup" in synchronous code, and it would be a natural
extension to add the guarantee that `defer`-ed statements also execute as part
of cleaning up an abandoned coroutine:

```swift
func processImageData() async throws -> Image {
  startProgressBar()
  defer {
    // This will be called when error is thrown, when all operations
    // complete and a result is returned, or when the coroutine is
    // abandoned. We don't want to leave the progress bar animating if
    // work has stopped.
    stopProgressBar()
  }

let dataResource  = try await loadWebResource("dataprofile.txt")
  let imageResource = try await loadWebResource("imagedata.dat")
  do {
    let imageTmp    = try await decodeImage(dataResource, imageResource)
  } catch _ as CorruptedImage {
    // Give up hope now.
    await abandon()
  }
  return try await dewarpAndCleanupImage(imageTmp)
}
```

This fills in another gap in the expressivity of callback-based APIs, where it is difficult to express cleanup code that must execute at some point regardless of whether the callback closure is really called. However, abandonment should not be taken as a fully-baked "cancellation" feature; if cancellation is important, it should continue to be implemented by the programmer where needed, and there are many standard patterns that can be applied. Particularly when coupled with error handling, common cancellation patterns become very elegant:

```
@IBAction func processImageData(sender: AnyObject) {
  beginAsync {
    do {
      let dataResource  = try await imageProcessor.loadWebResource("dataprofile.txt")
      let imageResource = try await imageProcessor.loadWebResource("imagedata.dat")
      let imageTmp      = try await imageProcessor.decodeImage(dataResource, imageResource)
      let imageResult   = try await imageProcessor.dewarpAndCleanupImage(imageTmp)
      display(imageResult)
    } catch CocoaError.userCancelled {
      // Ignore, user quit the kitchen.
    } catch {
      // Some really interesting error happened
      presentError(error)
    }
  }
}

@IBAction func stopImageProcessing(sender: AnyObject) {
  imageProcessor.cancel()
}
```

Internally, `imageProcessor` may use `NSOperation` or a custom `cancelled` flag. The intent of this section is to give a single example of how to approach this, not to define a normative or all-encompassing approach that should be used in all cases.

#### Completion handlers with multiple return values

Completion handler APIs may have multiple result arguments (not counting an error argument). These are naturally represented by tuple results in `async` functions:

```swift
// Before
func processImageHalves(completionHandler: (part1: Image?, part2: Image?, error: Error?) -> Void)

// After
func processImageHalves() async throws -> (Image, Image)
```

## Source Compatibility

This is a generally additive feature, but it does take `async` and `await` as keywords, so it will break code that uses them as identifiers.  This is expected to have very minor impact: the most pervasive use of `async` as an identifier occurs in code that works with dispatch queues, but fortunately keywords are allowed as qualified member names, so code like this doesn't need any change:

```swift
  myQueue.async { ... }
```

That said, there could be obscure cases that break.  One example that occurs in the Swift testsuite is of the form:

```swift
extension DispatchQueue {
  func myThing() {
    async {
        ...
    }
  }
}
```

This can be addressed by changing the code to use `self.async` or backticks.  The compiler should be able to detect a large number of these cases and produce a fixit.

## Effect on ABI stability

This proposal does not change the ABI of any existing language features, but does introduce a new concept that adds to the ABI surface area, including a new mangling and calling convention.

## Alternate Syntax Options

Here are a couple of syntax level changes to the proposal that are worth discussing, these don't fundamentally change the shape of the proposal.

#### Spelling of `async` keyword

Instead of spelling the function type modifier as `async`, it could be spelled as `yields`, since the functionality really is about coroutines, not about asynchrony by itself.  The recommendation to use `async/await` biases towards making sure that the most common use case (asynchrony) uses industry standard terms.  The other coroutine use cases would be much less common, at least according to the unscientific opinion of the proposal authors.

To give an idea of what this could look like, here's the example from above resyntaxed:

```swift
func loadWebResource(_ path: String) yields -> Resource
func decodeImage(_ r1: Resource, _ r2: Resource) yields -> Image
func dewarpAndCleanupImage(_ i : Image) yields -> Image

func processImageData1() yields -> Image {
  let dataResource  = yield loadWebResource("dataprofile.txt")
  let imageResource = yield loadWebResource("imagedata.dat")
  let imageTmp      = yield decodeImage(dataResource, imageResource)
  let imageResult   = yield dewarpAndCleanupImage(imageTmp)
  return imageResult
}
```

#### Make `async` be a subtype of `throws` instead of orthogonal to it

It would be a great simplification of the language model to make the `async` modifier on a function imply that the function is `throw`ing, instead of making them orthogonal modifiers.  From an intuitive perspective, this makes sense because many of the sorts of operations that are asynchronous (e.g. loading a resource, talking to the network, etc) can also fail.   There is also precedent from many other systems that use `async`/`await` for this; for example, .NET `Task`s and Javascript promises both combine error handling with async sequencing. One could argue that that's because .NET and Javascript's established runtimes both feature pervasive implicit exceptions; however, popular async frameworks for the Rust programming language, such as [tokio.rs](https://tokio.rs), have also chosen to incorporate error handling directly into their `Future` constructs, because doing so was found to be more practical and ergonomic than trying to compose theoretically-orthogonal `Future<T>` and `Result<T>` constructs.

If we made `async` a subtype of `throws`, then instead of four kinds of function type, we'd only have three:

```swift
    (Int) -> Int               // Normal function
    (Int) throws -> Int        // Throwing function
    (Int) async -> Int         // Asynchronous function, can also throw
```

The `try` marker could also be dropped from `try await`, because all `await`s would be known to throw.  For user code, you would never need the ugly `async throws` modifier stack.

A downside to doing this is that Cocoa in practice does have a number of completion handler APIs that do not take error arguments, and not having the ability to express that would make the importer potentially lose type information. Many of these APIs express failure in more limited ways, such as passing `nil` into the completion closure, passing in a `BOOL` to indicate success, or communicating status via side properties of the coordinating object; auditing for and recognizing all of these idioms would complicate the importer and slow the SDK modernization process. Even then, Swift subclassers overriding the `async` forms of these APIs would be allowed by the language to throw errors even though the error cannot really be communicated across the underlying Objective-C interface.

#### Make `async` default to `throws`

The other way to factor the complexity is to make it so that `async` functions default to `throw`ing, but still allow non-`throw`ing `async` functions to be expressed with `nonthrowing` (or some other spelling).  This provides this model:

```swift
    (Int) -> Int                     // Normal function
    (Int) throws -> Int              // Throwing function
    (Int) async -> Int               // Asynchronous function, can also throw.
    (Int) async(nonthrowing) -> Int  // Asynchronous function, doesn't throw.
```

This model provides a ton of advantages: it is arguably the right defaults for the vast majority of clients (reducing boilerplate and syntactic noise), provides the ability for the importer and experts to get what they want.  The only downside of is that it is a less obvious design than presenting two orthogonal axes, but in the opinion of the proposal authors, this is probably the right set of tradeoffs.

#### Behavior of `beginAsync` and `suspendAsync` operations

For async code to be able to interact with synchronous code, we need at least two primitive operations: one to enter a suspendable context, and another to suspend the current context and yield control back to the outer context. Aside from the obvious naming bikeshed, there are some other design details to consider. As proposed, `beginAsync` and continuation closures return `Void` to the calling context, but it may be desirable instead to have them return a value indicating whether the return was because of suspension or completion of the async task, e.g.:

```swift
/// Begin execution of `body`. Return `true` if it completes, or `false` if it
/// suspends.
func beginAsync(_ body: () async -> ()) -> Bool
/// Suspend execution of the current coroutine, passing the current continuation/// into `body` and then returning `false` to the controlling context
func suspendAsync<T>(_ body: (_ resume: (T) -> Bool) -> Void) async -> T
```

Instead of representing the continuation as a plain function value passed into the `suspendAsync` primitive, a specialized `Continuation<T>` type could be devised. Continuations are one-shot, and a nominal continuation type could statically enforce this by being a move-only type consumed by the resume operation. The continuation could also be returned by `beginAsync` or resuming a continuation instead of being passed into `suspendAsync`, which would put the responsibility for scheduling the continuation into the code that starts the coroutine instead of in the code that causes the suspension. There are tradeoffs to either approach.

## Alternatives Considered

#### Include `Future` or other coordination abstractions in this proposal

This proposal does not formally propose a `Future` type, or any other coordination abstractions. There are many rational designs for futures, and a lot of experience working with them. On the other hand, there are also completely different coordination primitives that can be used with this coroutine design, and incorporating them into this proposal only makes it larger.

Furthermore, the shape and functionality of a future may also be affected by Swift's planned evolution. A `Future` type designed for Swift today would need to be a `class`, and therefore need to guard against potentially multithreaded access, races to fulfill or attempts to fulfill multiple times, and potentially unbounded queueing of awaiting coroutines on the shared future; however, the introduction of ownership and move-only types would allow us to express futures as a more efficient move-only type requiring exclusive ownership to be forwarded from the fulfilling task to the receiving task, avoiding the threading and queueing problems of a class-based approach, as seen in Rust's [tokio.rs](https://tokio.rs) framework. tokio.rs and the C++ coroutine TR also both take the approach of making futures/continuations into templated/generic traits instead of a single concrete implementation, so that the compiler can deeply specialize and optimize state machines for composed async operations. tokio.rs and the C++ coroutine TR also both take the approach of making futures/continuations into templated/generic traits instead of a single concrete implementation, so that the compiler can deeply specialize and optimize state machines for composed async operations. Whether that is a good design for Swift as well needs further exploration.

#### Have async calls always return a `Future`

The most commonly cited alternative design is to follow the model of (e.g.) C#, where calls to async functions return a future (aka `Task` in C#), instead of futures being a library feature separable from the core language.  Going this direction adds async/await to the language instead of adding a more general coroutine feature.

Despite this model being widely know, we believe that the proposed design is
 superior for a number of reasons:

 - Coroutines are generally useful language features beyond the domain of async/await.  For example, building async/await into the compiler would require building generators in as well.
 - The proposed design eliminates the problem of calling an API (without knowing it is async) and getting a `Future<T>` back instead of the expected `T` result type.  C# addresses this by suggesting that all `async` methods have their name be suffixed with `Async`, which is suboptimal.
 - By encoding `async` as a first-class part of function types, closure literals can also be transparently `async` by contextual type inference. In the future, mechanisms like `rethrows` can be extended to allow polymorphism over asynchrony for higher-level operations like `map` to work as expected without creating intermediate collections of `Future<T>`, although this proposal does not propose any such abstraction mechanisms in the short term.
 - The C# model for await is a unary prefix keyword, which does not compose well in the face of chaining.  Wherein C# you may have to write something like `x = await (await foo()).bar()`, with the proposed design you can simply write `x = await foo().bar()` for the same reasons that you don't have to write `try` on every single call in a chain that can throw.
 - It is useful to be able to design and discuss futures as an independent standard library feature without tying the entire success or failure of coroutines as a language proposal to `Future`'s existence.
 - There are multiple different interesting abstractions besides futures to consider.  By putting the details of them in the standard library, other people can define and use their own abstractions where it makes sense.
 - Requiring a future object to be instantiated at every `await` point adds overhead. Since a major use case for this feature is to adapt existing Cocoa APIs, which already use callbacks, queues, target-action, or other mechanisms to coordinate the scheduling of the continuation of an async task, introducing a future into the mix would be an additional unnecessary middleman incurring overhead when wrapping these APIs, when in most cases there is already a direct consumer for the continuation point.
 - A design that directly surfaces a monadic type like `Future` as the result of an async computation heavily implies a compiler-driven coroutine transform, whereas this design is more implementation-agnostic. Compiler-transformed coroutines are a great compromise for integrating lightweight tasks into an existing runtime model that's already heavily callstack-dependent, or one aims to maintain efficient interop with C or other languages that heavily constrain the implementation model, and Swift definitely has both. It is conceivable that, in the eventual future, a platform such as Swift-on-the-server could provide a pure- or predominantly-Swift ABI where enough code is pure Swift to make cheap relocatable stacks the norm and overhead on C interop acceptable, as has happened with the Go runtime. This could make `async` a no-op at runtime, and perhaps allow us to consider eliminating the annotation altogether. The semantic presence of a future object between every layer of an async process would be an obstacle to the long-term efficiency of such a platform.
 
The primary argument for adding async/await (and then generators) to the language as first-class language features is that they are the vastly most common use-case of coroutines.  In the author's opinion, the design as proposed gives something that works better than the C# model in practice, while also providing a more useful/general language model.

#### Have a generalized "do notation" for monadic types

Another approach to avoiding the one-true-future-type problem of C# could be to have a general language feature for chaining continuations through a monadic interface. Although this provides a more general language feature, it still has many of the shortcomings discussed above; it would still perform only a shallow transform of the current function body and introduce a temporary value at every point the coroutine is "awaited". Monads also compose poorly with each other, and require additional lifting and transformation logic to plumb through higher-order operations, which were some of the reasons we also chose not to base Swift's error handling model on sugar over `Result` types. Note that the delimited continuation primitives offered in this proposal are general purpose and can in fact be used to represent monadic unwrapping operations for types like `Optional` or `Result`:

```swift
func doOptional<T>(_ body: (_ unwrap: (T?) async -> T) async -> T?) -> T? {
  var result: T?

  func unwrap(_ value: T?) async -> T {
    if let value = value {
      return value
    }
    suspendAsync { _ in result = nil }
  }

  beginAsync {
    body(unwrap)
  }
}
```

Monads that represent repeated or nondeterministic operations would not be representable this way due to the one-shot constraint on continuations, but representing such computations as straight-line code in an imperative language with shared mutable state seems like a recipe for disaster to us.

## Potential Future Directions

This proposal has been kept intentionally minimal, but there are many possible ways to expand this in the future.  For example:

#### New Foundation, GCD, and Server APIs

Given the availability of convenient asynchrony in Swift, it would make sense to introduce new APIs to take advantage of it.  Filesystem APIs are one example that would be great to see.  The Swift on Server working group would also widely adopt these features. GCD could also provide new helpers for allowing `() async -> Void` coroutines to be enqueued, or for allowing a running coroutine to move its execution onto a different queue.

#### Documentation

As part of this introduction it makes sense to extend the Swift API design guidelines and other documentation to describe and encourage best practices in asynchronous API design.

#### `rethrows` could be generalized to support potentially `async` operations

The `rethrows` modifier exists in Swift to allow limited abstraction over function types by higher order functions.  It would be possible to define a similar mechanism to allow abstraction over `async` operations as well. More generally, by modeling both `throws` and `async` as effects on function types, we can eventually provide common abstraction tools to abstract over both effects in protocols and generic code, simultaneously addressing the "can't have a Sequence that `throws`" and "can't have a Sequence that's `async`" kinds of limitations in the language today.

#### Blocking calls

Affordances could be added to better call blocking APIs from `async` functions and to hard wait for an `async` function to complete.  There are significant tradeoffs and wide open design space to explore here, and none of it is necessary for the base proposal.

#### Fix queue-hopping Objective-C completion handlers

One unfortunate reality of the existing Cocoa stack is that many asynchronous methods are
unclear about which queue they run the completion handler on.  In fact, one of the top hits
for implementing completion handlers on Stack Overflow includes this Objective-C code:

```objective-c
- (void)asynchronousTaskWithCompletion:(void (^)(void))completion;
{
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

    // Some long running task you want on another thread

    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) {
        completion();
      }
    });
  });
}
```

Note that it runs the completion handler on the main queue, not on the queue which it was
invoked on.  This disparity causes numerous problems for Cocoa programmers, who would
probably defensively write the `@IBAction` above like this (or else face a possible race
condition):

```swift
@IBAction func buttonDidClick(sender:AnyObject) {
  beginAsync {
    let image = await processImageData()
    // Do the update on the main thread/queue since it owns imageView.
    mainQ.async {
      imageView.image = image
    }
  }
}
```

This can be fixed in the Objective-C importer, which is going to be making thunks for the
completion-handler functions anyway: the thunk could check to see if the completion handler
is being run on a different queue than the function was invoked on, and if so, enqueue the
completion handler on the original queue.


## Thanks

Thanks to @oleganza for the original draft which influenced this!
