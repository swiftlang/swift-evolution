# Asynchronous Main Semantics

* Proposal: [SE-0323](0323-async-main-semantics.md)
* Authors: [Evan Wilde](https://github.com/etcwilde)
* Review Manager: [Doug Gregor](https://github.com/DougGregor/)
* Status: **Accepted**
* Implementation: [apple/swift#38604](https://github.com/apple/swift/pull/38604)

## Introduction

Program setup generally occurs in the main function where developers expect to
perform operations before other parts of the program are run.
Objective-C, C++, and C have initializers that are run before the main
entrypoint runs and can interact with Swift's concurrency systems in ways that
are hard to reason about.
In the Swift concurrency model, the developer-written asynchronous main
function is wrapped in a task and enqueued on the main queue when the main
entrypoint is run.
If an initializer inserts a task on the main queue, that task may be executed
before the main function, so setup is performed after initializer tasks are run.

Swift-evolution thread: [Pitch: Revisit the semantics of async main](https://forums.swift.org/t/pitch-revisit-the-semantics-of-async-main/51254)

## Motivation

Initializers in Objective-C, C++, and C can run code before the main entrypoint
while initializing global variables. If an initializer spawns a task on the main
queue, this initializer task will be enqueued before the task containing the
user-written asynchronous main function. This results in the initializer task
possibly being executed before the main function.
Comparatively, the synchronous main function is run immediately after the
initializers run, but before the tasks created by the initializers.

Hand-waving around the Swift/C++ interoperability, the example below
demonstrates a C++ library that is incompatible with the current asynchronous
main function semantics because it expects that the `deviceHandle` member of the
`AudioManager` is initialized before the task is run.  Instead, the program
asserts because the main function is executed after the task, so the
`deviceHandle` is not initialized by the time the task is run.

```c++
struct MyAudioManager {
  int deviceHandle = 0;

  MyAudioManager() {
    // 2. The constructor for the global variable inserts a task on the main
    //    queue.
    dispatch_async(dispatch_get_main_queue(), ^{
      // 4. The deviceHandle variable is still 0 because the initialization
      //    hasn't run yet, so this assert fires
      assert(deviceHandle != 0 && "Device handle not initialized!");
    });
  }
};

// 1. The global variable is dynamically initialized before the main entrypoint
MyAudioManager AudioManager;
```

```swift
@main struct Main {
  // 3. main entrypoint implicitly wraps this function in a task and enqueues it
  static func main() async {
    // This line should be used to initialize the deviceHandle before the tasks
    // are run, but it's enqueued after the crashing task, so we never get here.
    AudioManager.deviceHandle = getAudioDevice();
  }
}
```

This behaviour is different from the behaviour of code before Swift concurrency.
Before Swift concurrency, the developer is able to run any setup code necessary
before explicitly starting a runloop to execute tasks that were enqueued on the
main queue.

## Proposed Solution

I propose the following changes:
 - Run the main function up to the first suspension point synchronously.
 - Make the main function implicitly `MainActor` protected.

The asynchronous main function should run synchronously up to the first
suspension point to allow initialization of state that is required before the
tasks created by initializers are run.
At the suspension point, the current function suspends and other tasks on the
main queue are allowed to run.
This behaviour is consistent with the semantics of `await`, yielding for other
tasks to be executed.

```swift
@main struct Main {
  static func main() async {
    // Executed synchronously before tasks created by the initializers run
    AudioManager.device = getAudioDevice()

    // At this point, the continuation is enqueued on the main queue.
    // Other code on the main queue can be run at this point.
    await doSomethingCool()
  }
}
```

The main entrypoint starts on the main thread.
In order to ensure that there are no suspension points related to thread
hopping, the main function will need to run on the MainActor.
This has the added benefit of making accesses to other MainActor operations
synchronous.
Since the main function must run on the main thread, it cannot be run on other
global actors, so we will need to ban that.

```swift
@MainActor
var variable : Int = 32

@main struct Main {
  static func main() async {
    // not a suspension point because main is implicitly on the MainActor
    print(variable)
  }
}
```

## Detailed Design

Asynchronous functions are broken into continuation functions at each suspension
point.
There is an entry function and separate continuation functions for each
suspension.
The example below is a high-level analog of how the asynchronous main function
is broken:

```swift
@main struct Main {
  static func main() async {
    print("Hello1")
    await foo()
    await bar()
  }
}
```

The asynchronous main function above is broken into three synchronous
continuation functions.
`_main1` is the entrypoint to the main function, while `_main2` is enqueued by
`_main1`, and `_main3` is enqueued by `_main2`.

```swift
@main struct Main {
  static func _main3() {
    bar()
  }
  static func _main2() {
    foo()
    enqueue(_main3)
  }
  static func _main1() {
    print("Hello1")
    enqueue(_main2)
  }
}
```

The snippet below describes how the main entrypoint starts the program, by
enqueuing the first continuation, `_main1`, before starting a runloop to run
the tasks enqueued on the main queue.

```swift
// The main entrypoint to the program with old async main semantics
func @main(_ argc: Int32, _ argv: UnsafeMutablePointer<Optional<UnsafeMutablePointer<Int8>>>) {
  enqueue(_main1)
  drainQueues()
}
```

Instead of enqueuing the first continuation, we can execute it directly and let
it enqueue the next continuation.

```swift
// The main entrypoint to the program with the new async main semantics
func @main(_ argc: Int32, _ argv: UnsafeMutablePointer<Optional<UnsafeMutablePointer<Int8>>>) {
  _main1()
  drainQueues()
}
```

## Source Compatibility

There are no changes to the source representation of the asynchronous main
function. It will still be written with the same syntax as what is proposed in
[Structured Concurrency](0304-structured-concurrency.md).

Enforcing that the main function be run on the MainActor will result in new
error messages on code that previously compiled when the main function was
annotated with a non-MainActor global actor. Additionally, there will be new
warning messages emitted when accessing variables or calling functions protected
by the MainActor due to the unnecessary `await` keywords.

There shouldn't be any change at call-sites, where folks are calling the main
function from another function. The main function is asynchronous, so an await
will already be required. The change will be that this suspension now may
involve a hop to the main actor.

## Effect on ABI Stability

These changes can be implemented entirely in the compiler, so we will not need
to change the runtime. I can't think of anywhere else where there may be issues
with ABI and the main function.

## Effect on API Resilience

This shouldn't affect the API resilience.

## Alternatives Considered

### Separate Synchronous Setup Function

```swift
@main struct Main {
  // Effectively like the synchronous main, run by the main entrypoint of the
  // program.
  static func setup() {
  }

  // Behaves the same way as it does currently
  static func main() async {
  }
}
```

We could allow programmers to implement a secondary `setup` function that is run
after the initializers, but before the concurrency systems are running, allowing
programmers to setup any necessary global state.

This makes design makes it very clear where setup is to be done and disallows
any implicit asynchronous behaviour from creeping in. A benefit of this is that
you can't accidentally insert an `await` between lines that are initializing
state.

I don't see anything technically wrong with this approach, but I think that the
model described in the proposal is more consistent with how synchronous code is
written as well as being more aesthetically pleasing.

### Global Runloop

Python 3.4 introduced an `asyncio` concurrency library which was driven with an
event loop object. One would need two main functions, one synchronous, and the
other asynchronous. In the synchronous function, you would initialize any
necessary state, grab the event loop with the `asyncio.get_event_loop()`
function, and tell it to run the asynchronous main function.

Python has since migrated to `asycio.run()` to reduce the boilerplate of
grabbing the event loop and ensuring that it gets closed appropriately, but the
issue of using multiple main function still exists.

In order to implement this design, we need to provide an analog to the event
loop type, providing a function to run asynchronous code inside of. The problem
with providing this type is that it is available from everywhere, not just the
main function, which would enable programmers to call asynchronous code from a
synchronous function, the model for which hasn't been designed
yet.

Additionally, this design results in the programmer writing two main functions,
an asynchronous main function to perform asynchronous work and setup work, and
another function that gets the event loop and executes the asynchronous main
function. We can do this work implicitly to reduce the amount of boilerplate
code that a developer needs to write.

## Acknowledgments

 - Thanks Doug for helping with this proposal and suggesting that we extend the
   main function to be MainActor instead of just running on the main thread.
