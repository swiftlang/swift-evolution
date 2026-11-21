# Per-class allocators

* Proposal: [SE-NNNN](NNNN-class-allocators.md)
* Authors: [Andrew Fryer](https://github.com/Andrew-Fryer)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#NNNNN](https://github.com/swiftlang/swift/pull/NNNNN), behind the experimental
  feature `ClassAllocators`
* Review: ([pitch](TBD))

## Summary of changes

Adds `@allocator(A)`, which makes instances of a class or actor and its subclasses get their memory from `A`, a type
that conforms to a new `@unsafe` standard library protocol, `ClassAllocator`. A compiler flag applies an allocator to
every class in a module.

## Motivation

Every Swift class instance is allocated by `swift_allocObject`, which calls the runtime's `swift_slowAlloc`. On
Darwin that calls `malloc_type_malloc` with a type descriptor derived from the class. The system allocator uses the
descriptor to spread types across buckets. Elsewhere it calls `malloc`. Either way, the system decides where an
object lives. Swift has no way to say that one class should get its memory from somewhere else.

Browser engines show how much this matters. All of the major engines use their own custom allocator:
- **WebKit** uses bmalloc and libpas, with TZone heaps for C++ classes.
- **Chromium** uses PartitionAlloc, and the Oilpan garbage-collected heap for Blink's DOM objects.
- **Gecko** uses mozjemalloc, with arenas such as the one for layout frames.

They do it for two reasons:
- **Security:** keeping types, or groups of objects, in separate heaps means a use-after-free can't reuse the memory
  as an object of another type.
- **Performance:** size classes and per-thread caches tuned to the engine's allocation patterns, arenas that free a
  whole group of objects at once, and placement that keeps related objects close together.

An engine written in Swift can't do either for its class instances today.

Programs that care about the memory behind particular classes have no good option. For example:

- **Object pools**: Engines and parsers churn through millions of same-size nodes; a per-thread free list beats a
  general-purpose allocator.
- **Arenas and size classes**: A server wants each request's objects to come from a cache it controls.
- **Type isolation**: Separate heaps keep a use-after-free from overlapping an object of another type. Browser
  engines need to control which types share a heap, rather than leave it to the system allocator.

The workarounds all have real costs:

- **Replacing `malloc` for the whole process** replaces it for every library and framework in the process,
  including ones the program doesn't own, which were built and tuned against the system allocator. A program may
  want a different allocator only for its own types.
- **Pools of objects, or of structs in a manually managed buffer,** hide each object's lifetime from the allocator.
  Hardware memory tagging, such as Arm MTE, tags each allocation and gives it a new tag when it is freed, so that
  out-of-bounds accesses and uses after free fault. Objects carved out of one large buffer share its tag. Objects
  that the program recycles without freeing them keep theirs. Either way, those bugs go undetected. With
  `@allocator`, every instance's allocation and free reach the allocator, which can tag them itself or forward them
  to an allocator that does. These pools have other costs too:
  - Pools of `Unmanaged` objects or of raw storage give up Swift's memory safety and reference counting for the
    objects in the pool.
  - Structs give up class semantics: identity, inheritance, and `weak`/`unowned` references.

C++ lets a class choose its allocator by declaring class-specific `operator new` and `operator delete`, which the
compiler calls wherever it creates or destroys an instance. Swift has no equivalent. Adding one takes more than
having the compiler call the allocator, because the Swift runtime frees some objects itself, knowing only their
metadata:
- when the last `unowned` reference goes away after the deinit, and the compiler doesn't know the object's exact
  class (for example, the reference's type is a non-final class or a protocol);
- when an initializer fails;
- when the concurrency runtime frees an actor after its last job.

The design below has the compiler call the allocator directly wherever it can, and lets the runtime find it through
the object's metadata for the rest.

## Proposed solution

There are three parts:
- **`ClassAllocator`,** an `@unsafe` protocol with static `allocate` and `deallocate` requirements, and one standard
  library conformer, `SystemClassAllocator`;
- **`@allocator(A)`,** an attribute that names a class's allocator, which subclasses inherit;
- **a module-wide flag,** `-default-class-allocator`.

```swift
import Darwin
import Synchronization

/// Reuses freed 64-byte blocks instead of returning them to malloc. A global
/// lock keeps the example short; a real pool would use per-thread free lists.
enum NodePool: @unsafe ClassAllocator {
  static let blockSize = 64
  // The address of the first free block, or 0. Each free block holds the next.
  static let freeList = Mutex<UInt>(0)

  // malloc's 16-byte alignment covers every Swift type, so only the size matters.
  static func allocate(byteCount: Int, alignment: Int, for type: AnyClass) -> UnsafeMutableRawPointer {
    guard byteCount <= blockSize else { return unsafe malloc(byteCount)! }
    let reused = freeList.withLock { head in
      let block = head
      if let next = unsafe UnsafeRawPointer(bitPattern: block) {
        head = unsafe next.load(as: UInt.self)
      }
      return block
    }
    return unsafe UnsafeMutableRawPointer(bitPattern: reused) ?? malloc(blockSize)!
  }

  // byteCount is always the value that was passed to allocate.
  static func deallocate(_ pointer: UnsafeMutableRawPointer, byteCount: Int, alignment: Int,
                         for type: AnyClass) {
    guard byteCount <= blockSize else { return unsafe free(pointer) }
    freeList.withLock { head in
      unsafe pointer.storeBytes(of: head, as: UInt.self)
      head = UInt(bitPattern: pointer)
    }
  }
}

@allocator(NodePool) class Node { ... }
final class TaggedNode: Node { ... }                                  // inherits NodePool
@allocator(TracingAllocator) final class TracedNode: Node { ... }     // uses its own allocator
@allocator(SystemClassAllocator) final class PlainNode: Node { ... }  // opts out
```

`Node` and its subclasses are ordinary classes: code that creates and uses them doesn't change, and isn't unsafe.

The main properties of the design:

- **An instance is always freed by the allocator that allocated it,** wherever and whenever that happens.
- **Every instance is allocated by a direct call to the allocator,** emitted by the compiler in the class's init, at
  every optimization level.
- **An instance's memory is freed once both its last strong reference and its last `unowned` reference are gone.**
  Who calls the allocator depends on when we're deallocating:
  - **Releasing the last strong reference (no `unowned` references left):** the class's deinit calls the allocator
    directly. This is the common case, and it holds even when the release happens through a protocol, `AnyObject`,
    or unspecialized generic code, because the runtime calls the object's own deinit through its metadata.
  - **Releasing the last `unowned` reference (after the deinit has run):** the compiler calls the allocator directly
    if the reference's type is a final class or if it can prove which allocator every possible class of the object
    uses using whole module optimization. Otherwise the runtime looks the allocator up.
  - **Initializer fails:** the runtime looks the allocator up.
  - **Deallocating a default actor:** its deinit hands it to the concurrency runtime, which frees it at once or after
    its running job, and looks the allocator up. This happens for every default actor. An actor with a custom
    executor is freed by its deinit, like any other class.

  Where the compiler knows the object's class, as in specialized (monomorphized) code, it calls the allocator
  directly. In some cases (listed above), only the runtime knows the class; looking the allocator up is still fast,
  because the class's value witness table, which every class metadata record already points to, holds the
  allocator's `deallocate` at a fixed offset. Finding it takes three
  dependent loads (object to metadata, metadata to value witness table, table to function) and an indirect call.
- **Implementing an allocator is unsafe; using one is safe.**
- **Classes without an allocator are unaffected.**

## Detailed design

Misuses of the feature are compile-time errors wherever the compiler can detect them, and the rest trap at run time.
(Note that the unsafe allocator code can't be checked at compile time or run time; see the
[Semantics](#semantics) section for allocator requirements.)

### The `ClassAllocator` protocol

```swift
/// A type that provides the memory for instances of classes declared with
/// `@allocator`.
///
/// Conforming to `ClassAllocator` is unsafe: the compiler trusts an allocator to
/// return valid, suitably sized and aligned memory, to not reuse memory until
/// it has been returned, etc.
@unsafe
public protocol ClassAllocator: SendableMetatype {
  /// Returns memory for an instance of `type`.
  ///
  /// - Parameters:
  ///   - byteCount: The instance size of `type`. Always greater than zero.
  ///   - alignment: The instance alignment of `type`, a power of two.
  ///   - type: The dynamic class of the instance.
  /// - Returns: The address of at least `byteCount` uninitialized bytes,
  ///   aligned to `alignment`. Returning null is undefined behavior.
  static func allocate(byteCount: Int, alignment: Int, for type: AnyClass) -> UnsafeMutableRawPointer

  /// Takes back memory that `allocate(byteCount:alignment:for:)` returned.
  ///
  /// - Parameters:
  ///   - pointer: The address that `allocate` returned.
  ///   - byteCount: The `byteCount` that was passed to `allocate`.
  ///   - alignment: The `alignment` that was passed to `allocate`.
  ///   - type: The `type` that was passed to `allocate`: the dynamic class of
  ///     the instance.
  static func deallocate(_ pointer: UnsafeMutableRawPointer, byteCount: Int, alignment: Int,
                         for type: AnyClass)
}
```

- **The requirements are static.** The allocator is chosen per class, not per instance, as with class-specific
  `operator new` in C++. That avoids the problems of Objective-C's `NSZone`: nothing is stored in each object, and
  nothing is threaded through initializers by default; an allocator that needs state keeps it in static storage.
- **Allocators take a size and an alignment,** because they have no other way to know. For a class `C`,
  `MemoryLayout<C>.size` is the size of a reference to an instance (one pointer), not of the instance itself, and the
  standard library has no API that gives an instance's size from its class. The size also isn't fixed by the class
  that names the allocator: subclasses add stored properties, the specializations of a generic class can differ, and
  a class with a resilient superclass learns its layout only at run time. At an allocation site, the compiler
  usually knows exactly which concrete class it is creating (and therefore the size and alignment), loading them from
  the class metadata if they're known only at run time. When the instance is freed, the compiler or the runtime
  passes the same values again.
- **They aren't generic over the class they allocate.** One non-generic pair of functions serves every class that
  names the allocator, so classes can share the runtime tables described below. Generic requirements are discussed in
  [Alternatives considered](#alternatives-considered).
- **`for type:` is the dynamic class.** One allocator can serve a whole hierarchy and still tell the classes, and the
  specializations of a generic class, apart: for example, to give each its own heap.
- **`deallocate` gets the pointer that `allocate` returned, and the same `byteCount`, `alignment`, and `type` that
  `allocate` was passed,** because classes with an allocator have no tail-allocated elements, so an instance is
  always exactly its class's instance size.
- **`SendableMetatype`,** so that a conformance can't be isolated to an actor. This bans isolated conformances such
  as `@MainActor enum UIPool: @MainActor ClassAllocator`, which would be wrong (and unsafe!) because the compiler
  and runtime may call the allocator's methods from any isolation domain.
- **Allocators must be thread-safe.** `allocate` and `deallocate` can be called on any thread, including
  concurrently, so an allocator's state, such as a free list, has to be protected in some way (thread-local, atomic,
  using a lock, etc). `SendableMetatype` can't check this; it's one of the requirements that the `@unsafe`
  conformance acknowledges.
- **Returning null from `allocate` is undefined behavior.** If allocation fails, the allocator should trap because
  allocation failure isn't recoverable in Swift. The caller of `allocate` doesn't necessarily trap on null because
  that would add significant runtime overhead and would only catch one of many ways the allocator can be wrong.

**`@unsafe` and strict memory safety**: Under strict memory safety
([SE-0458](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md)), a
conformance to `ClassAllocator` must be written `@unsafe ClassAllocator`, and generic code that constrains a
parameter to `ClassAllocator` is unsafe too. Without strict memory safety, the conformance is accepted either way, as
for every other `@unsafe` protocol. Naming an allocator in `@allocator(A)` or in a compiler flag isn't a use of the
protocol, and the calls that the compiler generates aren't diagnosed. So the unsafety is acknowledged once, at the
conformance, and classes with allocators and the code that uses them stay safe.

### `SystemClassAllocator`

```swift
public enum SystemClassAllocator: @unsafe ClassAllocator {
  public static func allocate(byteCount: Int, alignment: Int, for type: AnyClass) -> UnsafeMutableRawPointer
  public static func deallocate(_ pointer: UnsafeMutableRawPointer, byteCount: Int, alignment: Int,
                                for type: AnyClass)
}
```

`SystemClassAllocator` is an ordinary conforming type, implemented with `swift_slowAlloc` and `swift_slowDealloc`.
Naming it has a special meaning: `@allocator(SystemClassAllocator)` means "no class allocator". The class is
compiled exactly like a class without the attribute: it uses `swift_allocObject` and `swift_deallocClassInstance`,
and it never gets `ClassFlags::HasClassAllocator`. The attribute is allowed on every class, including those that
can't have an allocator, and at every deployment target, because it's how a class opts out of an inherited allocator
or of `-default-class-allocator`.

### The `@allocator` attribute

```
attribute → '@allocator' '(' type ')'
```

`@allocator(T)` may be written on the declaration of a class `C`. `T` is resolved in the context of `C`, so it can
name a nested type (`@allocator(Node.Pool)`) or a type from another module.

**Compile-time errors**: The attribute, or an allocator a class would inherit or get from
`-default-class-allocator`, is an error in these cases, unless the allocator is `SystemClassAllocator`:

| Case | Reason |
|---|---|
| `T` doesn't conform to `ClassAllocator` | |
| `T` depends on `C`'s generic parameters | there is one allocator per class declaration |
| `C` is an Objective-C class, or inherits from `NSObject` | the Objective-C runtime allocates and frees its instances |
| `C` is a distributed actor | the runtime allocates its remote proxies with the system allocator; see [Actors](#actors) |
| `C` is a subclass of `ManagedBuffer` | tail-allocated elements aren't supported |
| `C` is `public` or `@usableFromInline`, or is declared `open`, in a module built with library evolution | clients can inline its allocating initializers or inherit its allocator, so a client compiled against an earlier version of the library could use a different allocator than the library; see [Classes in resilient libraries](#classes-in-resilient-libraries) |
| `C` is compiled for Embedded Swift | not yet supported; see [Future directions](#future-directions) |
| `C` can be used on OS versions whose Swift runtime predates this feature | see [Implications on adoption](#implications-on-adoption) |
| `C` is public in a module built without library evolution, and `T` isn't `public` or `@usableFromInline` | clients call `T` directly; see [Interfaces and serialization](#interfaces-and-serialization) |
| `C` is `package`, and `T` isn't `package`, `public`, or `@usableFromInline` | other modules in the package see `T` in the package interface and, with Package CMO, call it directly; see [Interfaces and serialization](#interfaces-and-serialization) |

**`ManagedBufferPointer(bufferClass:minimumCapacity:)`** with a class that has an allocator other than
`SystemClassAllocator` is a compile-time error when the class is written literally, such as `C.self`, and a run-time
trap otherwise: the runtime allocates that storage itself with `malloc`, and `C`'s deinit would free it through the
allocator.

**Other run-time traps**: On Darwin, every Swift class is also an Objective-C class (its root class is
`_SwiftObject`), so Objective-C code can allocate or free an instance without going through the code the compiler
generated. For a class with an allocator, two Objective-C methods therefore trap:
- **`+allocWithZone:`** (and `+alloc`), because it would allocate the instance with `malloc`, and the class's deinit
  would later free that memory through the allocator;
- **`-dealloc`** (through `swift_rootObjCDealloc`), because it would `free` memory that came from the allocator.

The runtime's implementations of these methods, and of `ManagedBufferPointer(bufferClass:minimumCapacity:)`, decide
whether to trap by testing the class flag `HasClassAllocator`.

### Inheritance

A class's allocator is the one named by the nearest class in its superclass chain that has `@allocator`, starting
with the class itself:

```swift
@allocator(Pool) class Base {}
class Derived: Base {}                                         // Pool
@allocator(OtherPool) final class Overriding: Derived {}       // OtherPool
@allocator(SystemClassAllocator) final class Plain: Derived {} // the system allocator
class Unrelated {}                                             // the system allocator
```

The module default from `-default-class-allocator` follows the same rule: it applies only to classes that would
otherwise have no allocator. So a subclass keeps an allocator it inherits, including an inherited
`@allocator(SystemClassAllocator)` opt-out. (If the default instead acted like an attribute on every unannotated
class, a superclass's `@allocator` would silently stop applying to its own subclasses.)

Note that the `type` parameter in the allocator's methods lets it treat different subclasses differently.

A subclass can also inherit an allocator from a superclass in another module if that module is built without library
evolution. The module's binary `.swiftmodule` records the superclass's allocator, so the compiler can call it directly
from the subclass's init and deinit. Apart from `@testable` imports, a superclass from a library-evolution module
never has an allocator to inherit: `public` classes and classes declared `open` can't have one, and other `package`
classes can't be subclassed outside their module (see
[Classes in resilient libraries](#classes-in-resilient-libraries)). A client's subclass of such a class can still
declare its own allocator.

### Generic classes

A generic class may have an allocator, but the allocator may not depend on the class's generic parameters:

```swift
@allocator(Pool) final class Box<T> { ... }               // OK: one Pool for every Box<T>
@allocator(TypedPool<T>) final class Box<T> { ... }       // error: depends on T
@allocator(TypedPool<Int>) final class Box<T> { ... }     // OK: a concrete type

@allocator(Box.Pool) final class Box<T> {                 // error: 'Box<T>.Pool' depends on T
  enum Pool: @unsafe ClassAllocator { ... }
}
```

A type nested in a generic class is implicitly generic over the class's parameters, even if it doesn't use them. An
allocator can still tell `Box<Int>` and `Box<String>` apart through `for:`. Allowing allocators that depend on the
class's generic parameters is a [future direction](#future-directions).

### Actors

Actors can have allocators under the same rules as classes:

```swift
@allocator(ActorPool) actor Counter { var count = 0 }
```

- **Allocation is unchanged:** an actor's allocating initializer allocates like a class's, so it calls the allocator
  directly.
- **Freeing a default actor goes through the concurrency runtime.** A default actor's deinit hands the object to the
  concurrency runtime, which frees it immediately if the actor is idle. If the actor is still running a job, the
  runtime frees it later, when the job finishes. Both cases free through the actor's allocator, using a runtime
  lookup like the other deferred frees.
- **Actors with a custom executor,** and isolated deinits, need nothing special: they free through the same paths as
  classes.
- **Distributed actors can't have an allocator.** The runtime allocates their remote proxies itself, with the system
  allocator and a smaller size. If an `unowned` reference outlived a proxy, the runtime's deferred free couldn't tell
  it from a local instance, and would hand it to the allocator.

### Classes in resilient libraries

In a module built with library evolution, a class whose effective visibility is `public`, `open`, or
`@usableFromInline` can't have an allocator, whether by declaration, inheritance, or `-default-class-allocator`,
except to opt out with `@allocator(SystemClassAllocator)`. (A `public` class nested in an internal type isn't visible
to clients, so it may have one.) A class declared `open` can't have one either, even when it's nested in a `package`
or internal type, so that a class in another module can never inherit an allocator from a library-evolution module
(apart from `@testable` imports). Internal and `package` classes may have allocators.

```swift
// Module Lib, built with -enable-library-evolution
@allocator(Pool) final class Leaf {}                     // OK: an internal class
public class Shape {}
@allocator(Pool) final class Circle: Shape {}            // OK: an internal subclass of a public class
@allocator(Pool) public final class Node {}              // error: 'public' class in a library-evolution module
@allocator(Pool) package final class Document {}         // OK: a package class
enum E { @allocator(Pool) public final class Dot {} }    // OK: effectively internal
package enum P { @allocator(Pool) open class Base {} }   // error: 'open' class in a library-evolution module
@allocator(SystemClassAllocator) public class Plain {}   // OK: an opt-out
public class Sub: ImportedBase {}                        // error if ImportedBase, from a module built without
                                                         // library evolution, has an allocator
```

Even in a library built with library evolution, Swift puts the code that allocates an instance of a `public` or
`@usableFromInline` class (the allocating entry point of each designated initializer) in the library's module, so
clients can inline it. If such a class later gained an allocator, clients compiled against the older library would
still allocate its instances with `malloc`, while the library's deinit would free them through the allocator. Banning
allocators on these classes prevents that.

This restriction is also necessary for performance. Otherwise, all classes that inherit from a class in a separate
resilient library would need to check at runtime if their base class has been updated to use an allocator that
they must now use.

`package` classes have neither problem. Other modules can't subclass a `package` class, and unless the library is
built with Package CMO (`-allow-non-resilient-access` and `-package-cmo`), the other modules in its package allocate
its instances by calling its initializers in the library, so the library's current allocator is always used. When the
last `unowned` reference to an instance is released in one of those modules, the runtime looks the allocator up. With
Package CMO, those modules can inline the library's allocations and call its allocator directly, because Package CMO
already relies on the modules in a package being built together.

### Semantics

**Allocation**: Every heap allocation of an instance calls `allocate` exactly once. The returned memory doesn't need
to be initialized in any way; the runtime will write the object header.

**Deallocation**: The memory is returned to `deallocate` exactly once, when the object's last strong reference *and*
its last `unowned` reference are gone:

- With no `unowned` references, it happens right after the deinit, in the class's deallocating deinit: on the thread
  that did the last release, or, for an `isolated deinit`
  ([SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md)),
  on the executor that runs the deinit.
- If `unowned` references remain after the deinit, it happens later, when the last of them is released, on whatever
  thread that is. Until then the memory stays allocated, so an allocator that retags memory on free can't catch
  accesses through stale `unowned(unsafe)` or `Unmanaged` references in that window.
- If an initializer fails or throws after allocating, the partially initialized object is freed through
  `deallocate`. (A convenience initializer that fails before delegating never allocates.) The object's dynamic class
  may be a subclass of the class whose initializer failed, so the runtime finds the allocator from the object's
  metadata.

`deallocate` may run on a thread that never called `allocate`, and it may run while `allocate` is running on another
thread. Allocators must be thread-safe.

**Optimizations**: The optimizer may remove the allocation of an object that doesn't escape, or promote it to the
stack, so `allocate` isn't necessarily called when an object is initialized. If IRGen can't place a promoted
instance on the stack (because of the function's stack budget or a class layout that isn't fixed), it allocates the
instance with `allocate` instead, and the instance is freed through `deallocate` as usual.

**Weak references**: When code first forms a `weak` reference to an object, or its reference counts overflow the
object header, the runtime allocates a *side table* for it: a small block that holds the object's reference counts
and a pointer back to the object. Side tables always come from `malloc`, even for a class with an allocator, because
the runtime allocates them separately from the object (see [Future directions](#future-directions)).

**Requirements on allocators**: An allocator must:
- return memory that is valid, at least `byteCount` bytes long and aligned to `alignment`;
- return an address whose bits in the platform's spare-bit mask for heap object references are zero (on arm64
  Darwin, the top four bits and the low three), because Swift packs enum payloads into those bits;
- not return null;
- not hand out memory again until it has been passed to `deallocate`;
- not re-enter itself. `allocate` and `deallocate` must not allocate an instance of a class that uses the same
  allocator, and they must not release the last reference to one either. With a lock-based allocator, a release
  inside `deallocate` that frees another object through the same allocator deadlocks, even though nothing was
  allocated.

Breaking any of these is undefined behavior. That's why the protocol is `@unsafe`.

**Allocators that isolate types for security** should route each free by the pointer, as libpas and TZone do, rather
than by `type`. `type` is derived from the object's metadata pointer, which a use-after-free or a buffer overflow may
have overwritten. The pointer passed to `deallocate` is the one `allocate` returned, bit for bit.

### Compiler flag

A module-wide flag lets a module adopt an allocator without annotating each class, similar to the existing
`-default-isolation` flag
([SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)).

```
swiftc -module-name Layout -default-class-allocator Heaps.IsolatedHeap ...
```

**Resolving the type**: The flag takes a fully qualified, dotted name (`Module.Type` or `Module.Outer.Inner`,
without generic arguments). It is resolved as if `Module` were imported into every file of the module being
compiled, so no explicit `import` is needed; `Module` may be the module being compiled. It's an error if the type
isn't found or doesn't conform to `ClassAllocator`.

**`-default-class-allocator Module.Type`** gives that allocator to every class declared in the module that would
otherwise have none, as if `@allocator` were written on it. `@allocator(X)` on a class overrides it, and
`@allocator(SystemClassAllocator)` opts a class out. A class that inherits an allocator or an opt-out keeps it: the
nearest declaration wins, as described in [Inheritance](#inheritance).

- **Every class that can't have an allocator is an error** under this flag: distributed actors, Objective-C and
  `NSObject`-derived classes, `ManagedBuffer` subclasses, and, in library-evolution modules, `public` and
  `@usableFromInline` classes and classes declared `open`. Each must be opted out explicitly with
  `@allocator(SystemClassAllocator)`. (We could instead automatically opt out these classes, but this would make it
  more difficult to know which allocator a class uses when reading Swift code.)
- **A deployment target older than the runtime support is an error** because every class in the module would need
  the new runtime.

### Code generation

When the compiler knows an object's class allocator `A`, it emits calls directly to `A`'s methods. When the runtime
frees an object itself, it looks the allocator up in the class's value witness table
([Proposed solution](#proposed-solution) lists these cases). Here are the specific calls that are emitted in each
case:

| Event | Emitted code |
|---|---|
| Allocating an instance | `A.allocate`, then `swift_initHeapObject` |
| Freeing an instance right after its deinit | `swift_deallocClassInstanceBegin`, then `A.deallocate` if that call returns the allocation |
| Last `unowned` release, allocator known | `swift_unownedReleaseBegin`, then `A.deallocate` if that call returns the allocation |
| Last `unowned` release, allocator unknown | `swift_unownedRelease`, the same call as for a class without an allocator |
| Failed initializer | `swift_deallocPartialClassInstance`, the same call as for a class without an allocator |
| Freeing a default actor | `swift_defaultActor_deallocate`, the same call as for an actor without an allocator |

In the last three cases, the runtime looks the allocator up (see [Runtime representation](#runtime-representation)).

The table's first three runtime entry points are new:
- `swift_initHeapObject` writes the header of an instance whose memory came from the allocator, as the existing
  `swift_initStackObject` does for an instance on the stack.
- `swift_deallocClassInstanceBegin` does everything `swift_deallocClassInstance` does except free the memory. It
  returns the allocation, or null if `unowned` references remain, in which case the last `unowned` release frees it.
- `swift_unownedReleaseBegin` decrements the unowned count and returns the allocation if the object should be freed
  now, or null otherwise.

The calls are emitted in SIL, so at `-O` they're specialized for `A`, and the allocator's fast paths can be inlined
(from `@inlinable` Swift or a `static inline` C function). Size and alignment are constants when the compiler knows
the object's concrete class and its layout, including in specialized generic code. Otherwise they're loaded from the
object's metadata. That happens in unspecialized generic code, for a class with a resilient superclass or a stored
property of a resilient type, and at the last `unowned` release of an instance of a non-final class whose subclasses
all use its allocator: there, the compiler knows the allocator but not which subclass the object is, so it doesn't
know the size.

The compiler always knows the allocator where it allocates an instance or frees one right after its deinit runs.
Either the class's module names it (with `@allocator` or `-default-class-allocator`), or it comes from a library built
without library evolution, which records it in its `.swiftmodule` and whose clients are recompiled whenever it
changes, or it comes from a library-evolution module in the same package that's built with Package CMO.

**Stack promotion**: An instance that the optimizer promotes to the stack never reaches the allocator, and its
release usually compiles to the same code as for a class without an allocator. If IRGen can't place the instance on
the stack, it allocates and frees it with the code in the table's first two rows, never with `swift_allocObject`.

### Runtime representation

In a few cases (the last three rows of the table in [Code generation](#code-generation)), the runtime frees an object
itself. It then needs to check whether the object's class has an allocator and, if it does, find that allocator's
`deallocate`.

**The `Flags` field of class metadata gets a new bit,** `ClassFlags::HasClassAllocator` (`0x20`), which indicates
whether the class has a custom allocator (excluding `SystemClassAllocator`). The existing class flags use 5 of its 32
bits, `0x1` through `0x10`; with this change, 6 of 32 bits are in use. When the flag is not set, the runtime can call
the system allocator's free function without loading the value witness table.

**The value witness table of a class with `HasClassAllocator` holds an extra pointer to the allocator's
`deallocate`.** Every class metadata record has a value witness table pointer in its header, which today points to
`Builtin.NativeObject`'s table (or `Builtin.UnknownObject`'s for classes that use Objective-C reference counting). The
metadata of a class with an allocator points to a table that extends `Builtin.NativeObject`'s instead. The new table
is an exact copy of `Builtin.NativeObject`'s table with one field added at the end: a pointer to
`deallocate(allocation, size, alignment, metadata)`. On 64-bit platforms:

| Bytes | Field |
|---|---|
| 0–87 | a copy of `Builtin.NativeObject`'s table: its eight value witness functions, size, stride, flags, and extra inhabitant count |
| 88–95 | new: a pointer to `deallocate(allocation, size, alignment, metadata)` |

- **The new field's signature is the same as an enum's or struct's `static func deallocate`,** so when the allocator
  is a non-generic enum or struct, the field points to its `deallocate` directly. For other allocators, it points to a
  function that the compiler emits for each allocator, which calls `A.deallocate`. Either way, the function uses the
  Swift calling convention, and on arm64e the pointer is signed like the table's other function pointers.
- **There's no `allocate` entry,** because the runtime never allocates instances.
- **Classes with the same allocator share a table.** Each image has one copy of each table: the compiler emits it as
  a hidden weak symbol, which the linker deduplicates.
- **Generic code is unaffected,** because the first 88 bytes are identical to `Builtin.NativeObject`'s table.
- **The table's flags are unchanged,** so the tables that the runtime builds from them, such as `Optional<C>`'s, are
  unaffected.

### Interfaces and serialization

A module records each class's allocator in its binary `.swiftmodule`, with its type resolved, whether it's written
with `@allocator` or comes from `-default-class-allocator`. Its `.swiftinterface` prints each explicit `@allocator`,
guarded by `#if $ClassAllocators`, but doesn't print the flag, or an allocator that comes from it, except in a package
interface (see below).

**With library evolution,** a class that the public `.swiftinterface` prints can't have an allocator, so that
interface prints only opt-outs. Client subclasses inherit those opt-outs (see [Inheritance](#inheritance)), so a
client's `-default-class-allocator` doesn't apply to them. The package interface (`.package.swiftinterface`) also
prints each `package` class's `@allocator`, including one that comes from `-default-class-allocator`, so a `package`
class's allocator type must be `package`, `public`, or `@usableFromInline`. An internal class's allocator doesn't
appear in either interface, so its type can be internal.

**Without library evolution,** client subclasses inherit a public class's allocator, and their compiler calls it
directly. So when the class is public or `@usableFromInline`, the allocator type and every type it names must be
public or `@usableFromInline`.

### Performance

Class allocators shouldn't add significant overhead to allocation. The compiler always knows the allocator where it
allocates an instance, and it passes `A.allocate` the same values that Swift's current implementation passes to
`swift_allocObject`.

The rest of this section covers the cost of freeing an object, from the release that ends its lifetime to the call to
the allocator's `deallocate` method. It compares that cost with the closest C++ equivalent: a library that defines its
own `operator new` and `operator delete` for all of its code (but not for the rest of the process) and manages objects
with `std::shared_ptr`, created with `std::make_shared`. `make_shared` puts the object and its reference counts in one
allocation, and a `std::weak_ptr` keeps that allocation alive after the object is destroyed, the way an `unowned`
reference does in Swift. The comparison uses libc++.

- **Last strong release, with no weak or unowned references**: `std::shared_ptr` makes two virtual calls on the
  control block: one runs the destructor, and the other frees the allocation with `operator delete`. Swift makes one
  indirect call: it loads the class's deinit from the object's metadata and calls it. The deinit destroys the stored
  properties, calls `swift_deallocClassInstanceBegin`, and then calls `A.deallocate`. In both languages, the allocator
  is called directly from code that knows the object's class, so the compiler can inline the call(s) if it can see the
  allocator's implementation. At `-Onone`, Swift's call goes through `A`'s conformance, but with optimization (`-O` or
  `-Osize`) it's a direct call.
- **Last weak or unowned release, after the object is destroyed**: `std::weak_ptr` frees the allocation with one
  virtual call. When the compiler knows the object's allocator, Swift calls `A.deallocate` directly. Otherwise the
  runtime looks it up, which takes one more dependent load than a C++ virtual call: object to metadata, metadata to
  value witness table, and table to the `deallocate` entry, followed by an indirect call. The metadata and the table
  are shared by every instance of the class, so these loads are likely to hit the CPU data cache.

**Freeing an instance of a class without an allocator** costs the same as before, except that when the runtime frees
an object itself, it tests one flag in the class metadata, which it already reads on those paths to get the size and
alignment.

## Source compatibility

This proposal is additive, with one exception. The parser resolves built-in attribute names before custom ones, so
an existing property wrapper, result builder, or attached macro named `allocator` can no longer be applied as
`@allocator`. It can still be applied through a module selector
([SE-0491](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0491-module-selectors.md)), as
`@MyModule::allocator`.

Adding `-default-class-allocator` to an existing module is source-breaking for that module only: each class that
can't have an allocator must be opted out.

## ABI compatibility

**New ABI**: The following become part of the Swift ABI:

- the `ClassAllocator` protocol and `SystemClassAllocator`;
- `ClassFlags::HasClassAllocator` (`0x20`), meaning the class has an allocator, and the rule that a class with it
  points to a value witness table with the `deallocate` entry;
- the layout, meaning, and signature of that entry, and its pointer-authentication discriminator on arm64e;
- the runtime entry points that compiled code calls: `swift_initHeapObject`, `swift_deallocClassInstanceBegin`, and
  `swift_unownedReleaseBegin`;
- the rule that runtime-built metadata of a class with `HasClassAllocator` keeps the compiler-emitted value witness
  table;
- the guarantee that the `alignment` passed to `allocate` and `deallocate` is a power of two. Allocators may depend
  on it, so Swift can't later introduce alignments that aren't powers of two without breaking them. The runtime
  already stores alignments as masks, so this adds no new constraint on the binary representation; it extends the
  promise to source code.

**Existing binaries**: No Swift compiler since Swift 5.0, which stabilized the ABI, sets `0x20`, so every class
compiled before this feature has `HasClassAllocator` clear. The runtime frees instances of those classes with the
system allocator, as before.

**Library evolution**: In a library built with library evolution, these changes are ABI-compatible:

- **Adding, removing, or changing a class's allocator**: Whether with `@allocator` or `-default-class-allocator`, this
  is compatible because only internal and `package` classes may have one, so all compiled code that allocates or frees
  their instances is in the library, or, with Package CMO, in a module of the same package that's built with it, and
  uses whatever allocator the library currently names. The runtime's free paths read the allocator from the class's
  current metadata, which is in the library too.
- **Making a class visible to clients**: A `public` or `@usableFromInline` class, or a class declared `open`, can't
  have an allocator, so making a class one of those requires removing its allocator first, which is compatible.

For a library built without library evolution, changing a class's allocator requires recompiling its clients, as
does any other change to such a library.

**Older runtimes** don't know the class flag or the table extension. A class with an allocator can't be available on
them, and the compiler rejects the flag when the deployment target includes them (see
[Implications on adoption](#implications-on-adoption)).

## Implications on adoption

The feature needs the Swift runtime that ships it. On platforms with an ABI-stable OS runtime, a class with an
allocator must be available only where that runtime is, and the flag needs a deployment target no older than that
runtime.
Code that doesn't use the feature back-deploys as before.

## Future directions

- **Allocators for weak-reference side tables**: When code first forms a `weak` reference to an object, the runtime
  allocates a *side table* for it, a small block that holds the object's reference counts and a pointer back to the
  object. Side tables always come from `malloc`, so even when a class's allocator isolates its instances, their side
  tables share a heap with other types, which leaves a cross-type use-after-free target and reliance on the system
  allocator for performance. A module-wide compiler flag could name a type that conforms to a second `@unsafe`
  protocol, with `allocateSideTable` and `deallocateSideTable` requirements; a prototype of this needed two more value
  witness table entries and another flag in the class metadata flags, but otherwise has the same mechanics as this
  proposal. Alternatively, `ClassAllocator` could gain side-table requirements with default implementations, but then
  classes without an allocator would always use `malloc` for their side tables.
- **Per-class storage for allocators**: An allocator that keeps state for each class, such as the heap pointer that
  WebKit's TZone allocator caches for each C++ class, has to find that state at run time from `for type:`, for example
  in a table keyed by the class's metadata. Swift classes have no storage of their own that an allocator could use
  instead: a static stored property is shared by a class and all of its subclasses, and generic classes can't have one
  at all. The compiler could reserve a zero-initialized word for each class with an allocator, and for each
  instantiation of a generic class, and pass its address to `allocate`. The allocator could then cache its per-class
  state there and reach it with a single load, without a lookup and without any code in each class.
- **Allocators that depend on a generic class's parameters**: A class such as
  `@allocator(TypedPool<T>) final class Box<T>` could name an allocator that depends on its generic parameters.
  Specialized code would still call `TypedPool<T>` directly. Only paths that are already slow would cost more:
  unspecialized generic code would call the allocator through its conformance, and the runtime's lookups would have to
  recover `T` from the class metadata to find `TypedPool<T>`. Each instantiation would also need its own value witness
  table, built at run time along with the rest of its metadata.
- **Tail-allocated classes**: Supporting `ManagedBuffer` subclasses would need new requirements: one to report an
  allocation's usable size, which `ManagedBuffer.capacity` gets today by asking the system allocator (`malloc_size` on
  Darwin), and one to free an allocation whose element count `deallocate` can't know. It would also have to handle
  clients that have inlined `ManagedBuffer.create`.
- **Direct frees after failed initializers and for default actors**: When an initializer fails, the runtime frees the
  partially initialized object and looks its allocator up, even for a final class, whose allocator the compiler knows.
  A runtime entry point that destroys such an object without freeing its memory, as `swift_deallocClassInstanceBegin`
  does after a deinit, would let the compiler call `A.deallocate` directly instead. Similarly, when a default actor is
  idle at the end of its deinit, the concurrency runtime could return its memory to the deinit to free directly. An
  actor that is still running a job would still be freed later by the concurrency runtime, which would look the
  allocator up.
- **Distributed actors**: If the runtime could tell a remote proxy from a local instance on the deferred-free paths,
  for example by asking the concurrency runtime, local distributed actors could have allocators while their proxies
  keep using the system allocator.
- **Embedded Swift**: Embedded Swift compiles whole programs, so compiled code can call the allocator directly for
  allocation and most frees. The `unowned` and failed-initializer paths find the allocator through a value witness
  table, which Embedded Swift's class metadata doesn't have, so they would need another way to find it.
- **Checking that allocators don't re-enter**: Requirements could be annotated so that the compiler rejects
  allocator code that allocates or releases class instances.

## Alternatives considered

- **A protocol that the class conforms to**: Instead of an attribute, a class could name its allocator in a
  conformance, such as `final class Node: ClassAllocated { typealias Allocator = Pool }`. This uses an existing
  language mechanism instead of a new attribute, and generic code could constrain a type to `ClassAllocated` and use
  its `Allocator`. However, a subclass inherits its superclass's conformance and can't redeclare it, so every class in
  a hierarchy would have to use the same allocator. Additionally, any module can add a conformance retroactively,
  where the class's module never sees it, so the compiler can't know a class's allocator at compile time, and finding
  it at run time would add overhead. Even then, a library loaded during execution could add a conformance after some
  instances were allocated with the system allocator, and they would be freed with `Pool`. Restricting the conformance
  to the class's declaration would fix the retroactive-conformance problem but not the inheritance one.
- **Requirements generic over the class**: `ClassAllocator`'s requirements could be generic over the class they
  allocate, such as `static func allocate<C: AnyObject>(_ type: C.Type, byteCount: Int, alignment: Int)`, so the
  compiler would specialize the allocator for each class. However, the main reason to want that is per-class state,
  such as a cached heap pointer, and generics don't provide it: generic functions and types can't have static stored
  properties, and a static stored property declared in a class is shared by all of its subclasses. Each class would
  still have to declare its own storage and expose it through a protocol requirement, which in practice means a macro
  on every class, and a macro can already generate a separate allocator type for each class without generic
  requirements. Generic requirements would also give each class its own `deallocate` entry, so classes with the same
  allocator could no longer share a value witness table.
- **Allocators on classes that clients of a resilient library can see**: A library built with library evolution could
  let its public and `open` classes have allocators, so that a framework's classes, and the subclasses that its
  clients declare, could all use the framework's allocator. However, it would add run-time overhead: the library can
  change a class's allocator in a later version, so clients can't know it at compile time. Every allocation and free
  would have to find the allocator at run time, which is slower than a direct call to the allocator. Keeping a public
  class's allocating initializers out of clients wouldn't be enough either: clients compiled against an earlier
  version of the library may already have inlined `malloc`-based allocations of it, so adding an allocator to an
  existing public class would break them. In this proposal, a client's subclass of such a class can still name its own
  allocator and so can another non-visible subclass in the resilient library. A `package` class can also have one,
  because other modules can't subclass it, and they either call its initializers in the library or, with Package CMO,
  are built with the library.
- **Per-class slots in class metadata**: Instead of extending the value witness table, the allocator's functions could
  be stored in new slots in the class metadata, so the runtime would find `deallocate` with one fewer dependent load.
  However, function pointers for an allocator don't fit with anything else in class metadata, so the slots would
  complicate its layout unnecessarily. The value witness table pointer already exists in every class's metadata and
  costs nothing to repoint to a new value witness table for the allocator that can be shared between classes.
- **No inheritance**: Requiring each class to name its allocator, instead of inheriting its superclass's, would be
  simpler: there would be no rules for inheriting an allocator or opting out of one. However, Swift code would need
  far more attributes. Even with `-default-class-allocator`, a hierarchy that should use a different allocator, or
  `SystemClassAllocator`, would need the attribute on every class in it instead of only on its root. In this proposal,
  a class that clients outside a resilient library's package can see can't have an allocator so that inheritance is
  always resolved at compile time.
- **Allocator values instead of types**: An allocator could be a value instead of a type, as with `NSZone` in
  Objective-C or C++'s polymorphic memory resources (`std::pmr`), where a container holds a pointer to a
  `memory_resource` and calls it through virtual functions. Different instances of the same class could then use
  different allocators, such as an arena per document or per request. However, each heap-allocated class instance
  would need to hold a pointer to the allocator, which costs memory and data cache locality.

## Acknowledgments

Thanks to the maintainers of libpas for their help with the design.
