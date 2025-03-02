# Improving the approachability of data-race safety

[SE-0434]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0434-global-actor-isolated-types-usability.md

> This document is an official feature [vision document](https://forums.swift.org/t/the-role-of-vision-documents-in-swift-evolution/62101). The Language Steering Group has endorsed the goals and basic approach laid out in this document. This endorsement is not a pre-approval of any of the concrete proposals that may come out of this document. All proposals will undergo normal evolution review, which may result in rejection or revision from how they appear in this document.

## Introduction

Swift's built-in support for concurrency has three goals:

1. Extend memory safety guarantees to low-level data races.
2. Maintain progressive disclosure for non-concurrent code, and make basic use of concurrency simple and easy.
3. Make advanced uses of concurrency to improve performance natural to accomplish and reason about.

The Swift 6 language mode provides a baseline of correctness that meets the first goal, but sometimes it comes at the cost of the second, and it can be frustrating to adopt. Now that we have a lot more user experience under our belt as a community, it’s reasonable to ask what we can do in the language to address that problem. This document lays out several potential paths for improving the usability of Swift 6, focusing on two primary use cases:

1. Simple situations where programmers aren’t intending to use concurrency at all.
2. Adapting an existing code base that uses concurrency libraries which predate Swift's native concurrency model.

While performance is not our immediate focus, it’s something we need to keep in mind during this exercise: we don’t want these usability wins to create pervasive regressions or to make it frustratingly difficult to achieve a high level of performance.

A key tenet of our thinking in this vision is that we want to drastically reduce the number of explicit concurrency annotations necessary in projects that aren’t trying to leverage parallelism for performance. This is important for many kinds of programming, such as UI programming and scripts, where concurrency is often localized and large swathes of the code are generally expected to be constrained to the main actor. At the same time, we want to maintain a smooth path for experienced programmers to opt in to concurrency and maintain the safety of complete data-race checking.

As we see it, there should be three phases on the progressive disclosure path for concurrency:

1. **Write sequential, single-threaded code**. By default, programmers writing executable projects will write sequential code; there is no runtime parallelism, and therefore no data-race safety errors are surfaced to the programmer.
2. **Write asynchronous code without data-race safety errors**. When programmers need functionality that can suspend, they can start introducing basic uses of async/await. Programmers won’t have to confront data-race safety at this point, because they aren’t yet introducing parallelism into their code. This is an important distinction, because there are many library APIs that perform work asynchronously, but they don’t need to use the programmer’s shared mutable state from a concurrent task. In these cases, programmers don’t have to understand data-race safety just to call an async API.
3. **Introduce parallelism to improve performance.** When the programmer is ready to embrace concurrency to get better performance, they can explicitly offload work from the main actor to the cooperative thread pool, leverage tasks and structured concurrency, etc, all while relying on the compiler to prevent mistakes that risk a data race.

## Mitigating false positive data-race safety errors in sequential code

A lot of code is effectively “single-threaded”. For example, most executables, such as apps, command-line tools, and scripts, start running on the main actor and just stay there unless some part of the code actually does something concurrent (like creating a `Task`). If there isn’t any use of concurrency, the entire program will run sequentially, and there’s no risk of data races — every concurrency diagnostic is necessarily a false positive! It would be good to be able to take advantage of that in the language, both to avoid annoying programmers with unnecessary diagnostics and to reinforce progressive disclosure. Many people get into Swift by writing these kinds of programs, and if we can avoid needing to teach them about concurrency straight away, we’ll make the language much more approachable.

Now, “If nothing in the program uses concurrency, suppress all the concurrency diagnostics” requires what compiler writers call a *whole-program analysis*, and rules like that tend not to work out well on multiple levels. For one, it would require the compiler to look at all of the code in the program all at once; this might be okay for small scripts, but it would scale poorly as the program got more complex. More importantly, it would make the first adoption of concurrency extremely painful: programmers would be hit by a tidal wave of errors in code they haven’t changed. And, of course, many libraries do use concurrency behind the scenes; importing even a single library like that would force concurrency-safety diagnostics everywhere.

A better approach is to locally state our assumption that the sequential parts of the program are “single-threaded”. Rather than having to assume the possibility of concurrency, Swift would know that these parts of the code will all run sequentially, which it can use to prove that there aren’t any data races. There can still be concurrent parts of the program elsewhere, but Swift would stop them from accessing the single-threaded bits. Fortunately, this is something that Swift can already model quite well!

### Single-threaded code and its challenges under Swift 6

The easiest and best way to model single-threaded code is with a global actor. Everything on a global actor runs sequentially, and code that isn’t isolated to that actor can’t access its data. All programs start running on the global actor `MainActor`, and if everything in the program is isolated to the main actor, there shouldn’t be any concurrency errors.

Unfortunately, it’s not quite that simple right now. Writing a single-threaded program is surprisingly difficult under the Swift 6 language mode. This is because Swift 6 defaults to a presumption of concurrency: if a function or type is not annotated or inferred to be isolated, it is treated as non-isolated, meaning it can be used concurrently. This default often leads to conflicts with single-threaded code, producing false positive diagnostics in cases such as:

* global and static variables,
* conformances of main-actor-isolated types to non-isolated protocols,
* class deinitializers,
* overrides of non-isolated superclass methods in a main-actor-isolated subclass, and
* calls to main-actor-isolated functions from the platform SDK.

To see this, let’s explore the first of those cases in more detail. A mutable global variable (or an immutable one that stores a non-`Sendable` value) is only memory-safe if it’s used in a single-threaded way. If the whole program is single-threaded, there’s no problem, and the variable is always safe to use. But since Swift 6 presumes concurrency by default, it requires a variable like this to be explicitly isolated to a global actor, like `@MainActor`. A function that uses that variable is then also required to be statically isolated to `@MainActor`:

```swift
class AudioManager {
  @MainActor
  static let shared = AudioManager()
  
  func playSound() { ... }
}

class Model {
  func play() {
    AudioManager.shared.playSound() // error: Main actor-isolated static property 'shared' can not be referenced from a nonisolated context
  }
}
```

And this in turn means that functions that call those functions must also be `@MainActor`, and so on until the `@MainActor` annotation has been laboriously propagated throughout the entire transitive tree of callers. Because main actor isolation is so common, many programmers have resorted to reflexively writing `@MainActor` everywhere, an onerous annotation burden that goes against Swift’s goals of making the simplest things easy.

Because the default programming model presumes concurrency, it is also hard on programmers who haven’t yet learned about concurrent programming, because they are confronted with the concept of data-race safety and actor isolation too early simply by using these basic language features:

```swift
class AudioManager {
  static let shared = AudioManager() // error: Static property 'shared' is not concurrency-safe because non-'Sendable' type 'AudioManager' may have shared mutable state
}
```

Analogous problems arise with all the other kinds of false positives listed above. For example, when using values from generic code, the value’s type usually must conform to one or more protocols. However, actor-isolated types cannot easily conform to protocols that aren’t aware of that isolation: they can declare the conformance, but it’s often impossible to write a useful implementation because the value’s properties will not be available. This is exactly the same kind of conflict as with global variables, where we have generally single-threaded code but a presumption of concurrency from the protocol, except that *this* conflict usually can’t be solved with annotations at all — the only fixes are to change the protocol, avoid all the isolated storage, or dangerously assert (with `assumeIsolated`) that the method is only used dynamically from the right actor.

### Allowing modules to default to being “single-threaded”

We believe that the right solution to these problems is to allow code to opt in to being “single-threaded” by default, on a module-by-module basis. This would change the default isolation rule for unannotated code in the module: rather than being non-isolated, and therefore having to deal with the presumption of concurrency, the code would instead be implicitly isolated to `@MainActor`. Code imported from other modules would be unaffected by the current module’s choice of default. When the programmer really wants concurrency, they can request it explicitly by marking a function or type as `nonisolated` (which can be used on any declaration as of [SE-0449](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md)), or they can define it in a module that doesn’t default to main-actor isolation. This doesn’t fundamentally change anything about Swift’s isolation model; it just flips the default, effectively creating a model in which code is single-threaded except where it explicitly requests concurrency. Modules that don’t want this could of course continue to use the current rules.

Making a module be isolated to the main actor by default would directly fix several of the false positive problems listed above for single-threaded code. Global variables would default to being isolated to the main actor, avoiding the diagnostic when they’re declared. Functions in the module would also default to being isolated to the main actor, allowing them to freely use both those isolated global variables and any main-actor-isolated functions and variables imported from the platform SDK. Class overrides and protocol conformances aren’t quite so easy, but we think we can extend them in ways that allow a natural solution with main actor isolation. We’ll get to how later in this document.

### Default concurrency rules for executable and library modules

As mentioned above, executable targets tend to center around the main actor. Command-line tools and scripts all start on the main actor and continue to run there unless they explicitly do something that introduces concurrency. Similarly, most UI programs make heavy use of single-threaded UI frameworks that privilege the main actor. This kind of code would be greatly improved by adopting a single-threaded model by default. Furthermore, since many new Swift programmers find themselves first writing this kind of code, this would also be a significant improvement to Swift’s progressive disclosure: programmers writing code in this mode should not run into data-race safety issues and diagnostics until they intentionally introduce concurrency. We feel that this amounts to a compelling argument that executable targets should default to inferring main actor isolation.

The same argument does not apply to libraries. Most library functions are meant to be usable from any context, and libraries usually avoid using any global or shared mutable state. Swift also already asks a little more of library authors in general; for example, access control is usually a more significant concern for library authors than for app developers. It would be reasonable for library targets to default to `nonisolated` the same way they do today in Swift 6.

Specific libraries could still decide to default to the main actor, such as when they’re libraries of UI widgets, or if a library is used for code organization within an executable project.

### Risks of a language dialect

Adding a per-module setting to specify the default isolation would introduce a new permanent language dialect. In a sense, Swift adds a new language dialect whenever it adds an upcoming language feature flag, but these are seen as “temporary” because it’s expected that those features will eventually be rolled into a future language mode. Permanent language dialects can be problematic for a variety of reasons:

* They can harm readability if readers have to know which dialect the code uses before they can understand the code.
* They can harm usability if programmers have to consciously program differently based on the dialect in use in the code or if code cannot be easily moved between projects using different dialects.
* They can harm tools such as IDEs if the tool has to know which dialect the code uses before it can work correctly; this is particularly challenging for code files that may be used in multiple dialects, such as a `.h` file in a C/C++/Objective-C IDE.
* When dialects are platform-dependent, they can harm portability and basic workflows (such as testing) if it is difficult to make the same code build as multiple dialects.

Some of these problems do not seem to apply to this proposed dialect because it only affects the isolation of declarations. Most IDE services, such as syntax highlighting and code completion, do not need to know the isolation of the surrounding context. And there’s no good reason for a module to build with a different default isolation on different platforms, so the dialect does not seem to introduce any portability concerns.

Readability does seem to be a fair concern. It is often useful to know what isolation a function will run under, and with this change, that would be dialect-specific. However, it is worth noting that the dynamic isolation of a function is already not always statically knowable because of the way that e.g. synchronous `nonisolated` functions inherit their callers’ isolation. And it would be reasonable for IDEs to be able to present isolation information for the current context: even without this dialect change, it is not always easy to understand how Swift’s isolation inference rules will apply to any particular declaration.

Programmers will probably not consciously program differently under these different dialects, and the compiler should provide reasonable guidance if they make a mistake. Moving code from a single-threaded module to a nonisolated module might be somewhat more arduous, however. To some degree, this is inherent and arguably even good: the programmer may be moving this code in an effort to generalize it to work concurrently, and any new diagnostics represent real problems that the programmer didn’t have to deal with before this generalization. But when the programmer is not trying to generalize the code to use concurrency, this could be frustrating, and it might be good for IDEs to offer assistance, such as tools to make the single-threaded assumptions of a piece of code explicit.

On balance, we feel that the costs of this particular dialect are modest and manageable.

## Isolated conformances

When checking a conformance to a protocol, Swift 6 often requires implementations to be nonisolated when the requirement is, including when the requirement is synchronous or the parameters are not Sendable. This makes it difficult to implement nonisolated protocols with any kind of isolated type: global-actor-isolated types, certainly, but also actors themselves. This restriction is very important when writing concurrent code, but it's a common source of false positives in single-threaded programs. Even worse, there's often no good solution to the problem: a correct implementation of the protocol for an isolated type usually requires access to the isolated data, and the only way to get that is to assert that the calling context is actually isolated, which completely subverts the static isolation safety that Swift 6 tries to provide.

In many ways, isolation's interaction with protocol requirements is similar to its interaction with function values. In both situations, we have an abstract signature that doesn't express isolation by default, which Swift wants to interpret as an affirmative statement that the isolation of the implementation doesn't matter. Over the last few years, Swift has gradually added more ways to handle isolated function values:

- A function value can have a type like `() -> Bool` that says it's not sendable. These functions can have any kind of isolation as long as it's the same as the current concurrency domain. Since the function can't be used from a different context, there's no need for it to spell out its isolation explicitly in its type; Swift just checks that the isolation actually matches whenever it makes a new non-`Sendable` function value.

- A function value can have a type like `@MainActor () -> Bool` that says it's isolated to a specific global actor. These functions can either be non-isolated or isolated to that actor, and Swift just treats them as the latter unconditionally when calling them.

- A function value can have a type like `@isolated(any) () -> Bool` that says it might be isolated to a specific actor that it carries around with it dynamically. These functions can be isolated to anything, and the caller has to be prepared to handle it.

Each of these ideas also works with protocol conformances. If we know that we only intend to use a protocol conformance from the current concurrency domain, we don't really care whether the implementation requires some sort of isolation as long as the current context has that isolation. Similarly, if we know that the implementation of a protocol might be isolated to a specific global actor, we can handle that whenever we use the conformance exactly as if the protocol requirements were declared isolated to that actor. And we could even do that dynamically with a statically-unknown isolation, the same way Swift already does with `@isolated(any)` function values.

The most important of these for our model of single-threaded code is to be able to express global-actor-isolated conformances. When a type is isolated to a global actor, its methods will be isolated by default. Normally, these methods would not be legal implementations of nonisolated protocol requirements. When Swift recognizes this, it can simply treat the conformance as isolated to that global actor. This is a kind of *isolated conformance*, which will be a new concept in the language.

Now, an isolated conformance is less flexible than a nonisolated conformance. For example, generic types and functions from nonisolated modules (including all current declarations) will still be interpreted as requiring nonisolated conformances. This will mean that they can't be called with a type that only has an isolated conformance, but it will also allow them to freely use the conformance from any concurrency domain, the same way they can today. Generic types and functions in "single-threaded" modules will default to allowing conformances isolated to the module's default global actor. Since those functions will themselves be isolated to that global actor, they won't have any problem using those conformances.

A generic function that can work with both isolated and nonisolated conformances should be able to declare that it can accept an isolated conformance. It would then be restricted to only use the conformance from the current concurrency domain, as if it were a sort of "non-sendable conformance". This is an important tool for generic libraries such as the standard library, many of which will never use conformances concurrently and so are fine with accepting isolated conformances.

This design is still being developed, and there are a lot of details that will have to be figured out. Nonetheless, we are tentatively very excited about the potential for this feature to fix problems with how Swift's generics system interacts with isolated types, especially global-actor-isolated types.

## Isolated subclasses and overrides

To achieve data race safety, Swift 6 has to diagnose a variety of problems that are specific to classes:

- The sendability of a class must match the sendability of its superclass[^1].
- If a class is sendable and not isolated to a global actor, its stored properties must be sendable.
- If a class is isolated to a global actor, its superclass must either be non-isolated or isolated to the same global actor.
- An override must have the same isolation as the declaration it overrides.

[^1]: There is a natural exception to this rule: a sendable class can have a non-sendable superclass if the superclass and all of its ancestors only have sendable stored properties.  Currently, Swift only implements this exception for the exact class `NSObject`.

All of these diagnostics are false positives in purely sequential programs. Fortunately, many of them don't apply to global-actor-isolated classes in the first place. The restriction that isolated classes can't inherit from classes isolated to a different global actor is very reasonable, but it's extremely unlikely to affect programmers in practice because they rarely use global actors other than the main actor at all. The only significant false positive here, then, is the restriction on overriding.

[SE-0434][] changed the rules for global-actor-isolated classes to allow them to inherit from non-sendable classes; the subclass just remains non-sendable. Since the class is non-sendable and isolated to a global actor, it's tempting to say that override restrictions shouldn't be necessary for it: the object reference should only be usable on the global actor in the first place. This isn't quite true today, but we think we can revise SE-0434 to make it true by imposing restrictions on initializers in the subclass. This would be a small source break, but it would greatly improve the usability of these classes.

Unfortunately, global-actor-isolated classes that inherit from nonisolated sendable classes can't benefit from the same idea. We can only see one way to make it safe to allow isolated overrides of non-isolated methods for these classes without a whole-program prohibition of concurrency: we would have to prevent any reference to the subclass from being converted to its sendable superclass type. This is feasible to implement, but we suspect it would be too restrictive to be widely useful; we can revisit this with more information.

## Easing the introduction of basic async code

[SE-0338](https://github.com/hborla/swift-evolution/blob/async-function-isolation/proposals/0338-clarify-execution-non-actor-async.md) specifies that nonisolated async functions never run on an actor's executor. This design decision was made to prevent unnecessary serialization and contention for the actor by switching off of the actor to run the nonisolated async function, and any new tasks it creates that inherit isolation. The actor is then free to make forward progress on other work. This behavior is especially important for preventing unexpected overhang on the main actor.

Over time, we have learned that this design decision undermines progressive disclosure, because it prioritizes main actor responsiveness at the expense of making basic asynchronous code difficult to write. Always switching off of an actor to run a nonisolated async function imposes data-race safety errors on programmers when they call the API with non-sendable arguments from the main actor.

Many library APIs have transitioned to using isolated parameters to ensure that an async API runs on the caller by default, because it’s a much easier default to work with in client code. 

The current execution semantics of async functions also impede programmer’s understanding of the concurrency model because there is a significant difference in what `nonisolated` means on synchronous and asynchronous functions. Nonisolated synchronous functions always run in the isolation domain of the caller, while nonisolated async functions always switch off of the caller's actor (if there is one). It's confusing that `nonisolated` does not have a consistent meaning when applied to functions, and the current behavior conflates the concept of actor isolation with the ability for a function to suspend.

Changing the default execution semantics of nonisolated async functions to run wherever they are called better facilitates progressive disclosure of concurrency. This default allows functions to leverage suspension without forcing callers to cross an isolation boundary and imposing data-race safety checks on arguments and results. A lot of basic asynchronous code can be written correctly and efficiently with only the ability to suspend. When an async function needs to always run off of an actor, the API author can still specify that with a new `@execution(concurrent)` annotation on the function. This provides a better default for most cases while still maintaining the ease of specifying that an async function switches off of an actor to run.

Many programmers have internalized the SE-0338 semantics, and making this change several years after SE-0338 was accepted creates an unfortunate intermediate state where it's difficult to understand the semantics of a nonisolated async function without understanding the build settings of the module you're writing code in. We can alleviate some of these consequences with a careful migration design. There are more details about migration in the [automatic migration](#automatic-migration) section of this document, and in the [source compatibility](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md#source-compatibility) section of the proposal for this change.

This idea has already been pitched on the forums, and you can read the full proposal for it [here](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md).

## Easing incremental migration to data-race safety

Many programmers are not new to concurrency as a concept and have extensive experience with multi-threaded programming. However, the Swift 6 data-race safety model is a significant shift for programmers with experience using concurrency libraries that predate Swift's native concurrency features. Moreover, there are many existing, large codebases that were built on such libraries, and migrating these codebases to both leverage modern concurrency features and enable static data-race safety takes significant engineering effort. An explicit goal of improving the approachability of data-race safety is lessening the amount of effort it takes to enable data-race safety in existing codebases.

### Bridging between synchronous and asynchronous code

Introducing async/await into an existing codebase is difficult to do incrementally, because the language does not provide tools to bridge between synchronous and asynchronous code. Sometimes programmers can kick off a new unstructured task to perform the async work, and other times that is not suitable, e.g. because the synchronous code needs a result from the async operation. It’s also not always possible to propagate `async` throughout callers, because the function signature might be declared in a library dependency that you don’t own.

Notably, using actors in programs that make heavy use of the main actor forces programmers to use async/await, because all interactions with an actor must be done asynchronously from outside the actor. This significantly restricts the utility of actors, especially in existing codebases.

Other concurrency libraries like Dispatch provide a limited tool set to wait on asynchronous work, such as `DispatchQueue.asyncAndWait`. These tools come with serious tradeoffs, including tying up limited system resources and introducing the possibility for deadlocks, but they provide critical functionality that is sometimes necessary in a project. It’s important for programmers to have the ability to express this in the language, and because the language model allows actor re-entrancy and doesn’t have a strict FIFO guarantee for tasks enqueued on an actor, there’s opportunity to mitigate the risk of deadlocks that these tools come with.

### Mitigating runtime assertions due to isolation mismatches

[SE-0423: Dynamic actor isolation enforcement from non-strict-concurrency contexts](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md) introduced dynamic actor isolation assertions that are injected by the compiler at the boundaries between data-race safe and unsafe code. This dynamic checking catches actor isolation violations in library dependencies that have not yet migrated to the Swift 6 language mode, and may have data-race safety issues in their implementation. These checks are effective at identifying missing `@Sendable` annotations, but they also make Swift 6 adoption painful for clients when they migrate before their dependencies.

Some of these runtime crashes are false positives; the runtime checks are inserted based on the static isolation of the function, but the function might not access any mutable state that’s isolated to or derived from the actor. In these cases, the dynamic checks can simply be elided based on analysis of the function implementation.

In other cases, the dynamic assertion indicates the presence of a runtime data race, because isolated state is being accessed from outside the actor. The correct way to resolve this data race is either to run the function on the actor, or change the function to eliminate access to actor-isolated state. There are two possible avenues for the language to aid programmers in resolving the data race:

* Instead of directly calling the function in the wrong isolation domain, enqueue a job that calls the function on the actor. This only works if the function does not return a result.
* Use the import-as-async heuristic from [SE-0297: Concurrency Interoperability with Objective-C](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0297-concurrency-objc.md) to automatically import completion handlers of asynchronous functions as `@Sendable`, which will allow the compiler to diagnose access to actor-isolated state in completion handlers.

## Automatic migration

Unlike the Swift 6 migration, all language changes with source compatibility impact described in this vision can be automatically migrated to while preserving the semantics of existing code. The source incompatible portions of this vision will be gated behind [upcoming feature flags](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md), which will be enabled by default in a future 6.x language mode, except for the per-module setting to infer main actor by default.

Compiler tooling can automatically migrate existing projects when they choose to enable each of these upcoming features, either individually or as part of a future language mode migration. Programmers will be able to perform a “migration build” with one or more upcoming language features enabled, or with a specific language mode that enables a set of upcoming features, and be offered source code changes that would allow the compiler to build the project without errors and without changing semantics.

## What’s not in this vision

This vision does not cover existing pain points with task ordering and actor re-entrancy. These are important problems, but they are more prevalent in more advanced uses of concurrency and warrant a separate, dedicated exploration.

Improving concurrency diagnostics and documentation is also not covered in this document. All language proposals should consider diagnostics to the extent that language design decisions prevent precise and actionable error messages. Beyond that, diagnostics and documentation changes are not governed by the Swift evolution process, because these changes don't have long-term source compatibility and ABI constraints, so gating improvements behind a heavy weight review process isn't necessary. However, diagnostics and documentation are an extremely important tool for making the concurrency model more approachable, and they will be included in the implementation effort behind this vision.
