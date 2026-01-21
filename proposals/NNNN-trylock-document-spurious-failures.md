# Document (the lack of) spurious failures in `Mutex.withLockIfAvailable(_:)`

* Proposal: [SE-NNNN](NNNN-trylock-document-spurious-failures.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift#85497](https://github.com/swiftlang/swift/pull/85497)
* Review: ([pre-pitch](https://forums.swift.org/t/should-we-document-the-behavior-of-mutex-withlockifavailable/83166))
  ([pitch](https://forums.swift.org/t/pitch-document-the-lack-of-spurious-failures-in-mutex-withlockifavailable/84279))

## Summary of changes

Modifies the documentation (but not the implementation) of
[`Mutex.withLockIfAvailable(_:)`](https://developer.apple.com/documentation/synchronization/mutex/withlockifavailable(_:))
to add a guarantee that it is not subject to spurious failures.

## Motivation

The documentation for `Mutex.withLockIfAvailable(_:)` does not specify if it can
spuriously fail to acquire the mutex. Normally, the lack of any discussion about
spurious failures wouldn't be an issue since we don't document whether or not
most other API can spuriously fail either.

### What is a "spurious failure"?

Given the following algorithm:

```
if mutex.tryLock() {
  doWork()
  mutex.unlock()
}
```

`mutex.tryLock()` _should_ return `true` if the lock was acquired, and `false`
if another thread has currently acquired it. A _spurious failure_ occurs if the
function returns `false` despite no other thread having acquired it.

### Why should we document our behavior?

`Mutex.withLockIfAvailable(_:)` is Swift's spelling of the `tryLock()`
operation, and there is a schism between the C/C++ standards and POSIX as to
whether `tryLock()` might fail spuriously.

### C/C++ vs. POSIX

C11's [`mtx_trylock()`](https://en.cppreference.com/w/c/thread/mtx_trylock.html)
and C++11's [`std::mutex::try_lock()`](https://en.cppreference.com/w/cpp/thread/mutex/try_lock.html)
are both allowed to spuriously fail[^doThey]. Per the C++11 standard [§30.4.1.1/16](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2013/n3690.pdf):

> An implementation may fail to obtain the lock even if it is not held by any
> other thread. [ _Note:_ This spurious failure is normally uncommon, but allows
> interesting implementations based on a simple compare and exchange [...] ]

(The standard is referring to _weak_ compare-and-exchange operations which can
fail spuriously at the hardware level; _strong_ compare-and-exchange operations
cannot fail in this manner.)

But the POSIX standard for [`pthread_mutex_trylock()`](https://pubs.opengroup.org/onlinepubs/7908799/xsh/pthread_mutex_lock.html)
makes no such accommodation, instead stating simply:

> The function `pthread_mutex_trylock()` is identical to `pthread_mutex_lock()`
> except that if the mutex object referenced by `mutex` is currently locked (by
> any thread, including the current thread), the call returns immediately.

[^doThey]: I'm not aware of any real-world C/C++ standard library implementation
  that actually has this failure mode. But if you choose to code defensively to
  these language standards, you have chosen to accept spurious failures into
  your life, and I don't know any software engineer who enjoys dealing with
  those.

### Other languages

Other languages have equivalent API:

| Language | Equivalent API |
|-|-|
| Go | [`Mutex.TryLock()`](https://pkg.go.dev/sync#Mutex.TryLock) |
| Java | [`Lock.tryLock()`](https://docs.oracle.com/javase/8/docs/api/java/util/concurrent/locks/Lock.html#tryLock--) |
| Kotlin | [`Mutex.tryLock()`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines.sync/-mutex/try-lock.html) |
| Rust | [`mutex::try_lock()`](https://doc.rust-lang.org/std/sync/struct.Mutex.html#method.try_lock) |
| Zig | [`std.Thread.Mutex.tryLock()`](https://ziglang.org/documentation/master/std/#std.Thread.Mutex.tryLock) |

None of these methods document that they spuriously fail (other than the
Rust-specific concept of a "poisoned" mutex which is not germane to this
proposal.) A reader without further context has no reason to expect that they
can spuriously fail because any API that can spuriously fail would surely
document it.[^bugHunt]

[^bugHunt]: At least one of these languages' platform-specific implementations
  uses a weak compare-and-exchange operation and (as far as I understand their
  code) is therefore subject to undocumented spurious failures. I leave it as an
  exercise for the reader to determine which one(s).

### Where does Swift stand?

Swift's current documentation is silent on the matter. As a developer who uses
the Swift language and its standard library, if I were approaching this
documentation in a vacuum, I wouldn't even consider the possibility of a
spurious failure. As a rule we don't concern ourselves with "oh it might
randomly fail" as something we need to guard against.

But a developer coming from another language will be bringing with knowledge of
that language and its standard library. A developer coming to Swift from C or
C++ might rightly ask if `Mutex.withLockIfAvailable(_:)` is safe to use.

I've reviewed the [platform-specific implementations](https://github.com/swiftlang/swift/tree/main/stdlib/public/Synchronization/Mutex)
of `_MutexHandle._tryLock()` in the Swift repository and have confirmed that
none of these implementations is subject to spurious failure (or, at least, none
documents any such failure mode):

| Platform | Implementation Based On | Uses `cmpxchg` in Swift? | Documents Possible Spurious Failures? | Confirmed from Source Inspection? |
|-|-|-|-|-|
| Darwin | `os_unfair_lock_trylock()` | No | [No](https://developer.apple.com/documentation/os/1646469-os_unfair_lock_trylock) | Yes |
| FreeBSD | `UMTX_OP_MUTEX_TRYLOCK` | No | [No](https://man.freebsd.org/cgi/man.cgi?query=_umtx_op) | Yes |
| Linux/Android | `Atomic.compareExchange()`/`FUTEX_TRYLOCK_PI` | Strong | [No](https://man7.org/linux/man-pages/man2/FUTEX_TRYLOCK_PI.2const.html) | Yes |
| OpenBSD | `pthread_mutex_trylock()` | No | [No](https://pubs.opengroup.org/onlinepubs/7908799/xsh/pthread_mutex_lock.html) | Yes[^openBSDCAS] |
| Wasm | `Atomic.compareExchange()` | Strong | [No](https://developer.apple.com/documentation/synchronization/atomic/compareexchange(expected:desired:successordering:failureordering:)-7msfy) | Yes |
| Windows | `TryAcquireSRWLockExclusive()` | No | [No](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-tryacquiresrwlockexclusive) | No[^windowsImpl] |

[^openBSDCAS]: OpenBSD uses the GCC builtin `__sync_val_compare_and_swap()` in
  its implementation of `pthread_mutex_trylock()` [here](https://github.com/openbsd/src/blob/master/lib/libc/thread/rthread_mutex.c).
  This builtin compiles to a _strong_ compare-and-swap operation.
[^windowsImpl]: Windows is, of course, closed-source, and Microsoft's
  implementation of `TryAcquireSRWLockExclusive()` is proprietary. My
  conclusions are based on Microsoft's documentation and a careful reading of
  the Wine reimplementation [here](https://github.com/wine-mirror/wine/blob/main/dlls/ntdll/sync.c).

In other words, although we don't (yet) document it, Swift's
`Mutex.withLockIfAvailable(_:)` implementations do not spuriously fail. These
implementations are, of course, _implementation details_ and are subject to
change over time, but any change to `Mutex` that causes us to start spuriously
failing is a _breaking change_ because it could wreak havoc on code that uses
`Mutex.withLockIfAvailable(_:)` today.

### Is there a real-world scenario where a spurious failure is a problem?

For a real-world case study, see Swift Testing's use of
`Mutex.withLockIfAvailable(_:)` as described in [this](https://forums.swift.org/t/should-we-document-the-behavior-of-mutex-withlockifavailable/83166/4#p-381985-an-overly-verbose-case-study-1)
forum post.

In a nutshell: spurious failures in `Mutex.withLockIfAvailable(_:)` are
indistinguishable from real failures (which occur due to the lock being
contended).

If the lock is held by another thread, a caller can reasonably assume that the
other thread will eventually release the lock and may opt to fall back to
[`Mutex.withLock(_:)`](https://developer.apple.com/documentation/synchronization/mutex/withlock(_:))
or may retry calling `Mutex.withLockIfAvailable(_:)` in a loop (which
effectively turns `Mutex` into a spinlock&mdash;I'm not _recommending_ you take
this approach, just listing it as a possible solution).

If the lock is held by the **current** thread, any solution (other than giving
up on acquiring the lock) _must_ result in a deadlock because the caller cannot
tell that the failure was real and forward progress is not possible.

### Can you appeal to authority for me?

Raymond Chen over at Microsoft gave a decent description on [his blog](https://devblogs.microsoft.com/oldnewthing/20180330-00/?p=98395)
of the difference between weak and strong compare-and-exchange operations and
pointed out that you can only really accept a weak compare-and-exchange if
failure is cheap:

> It comes down to whether spurious failures are acceptable and how expensive
> they are.
>
> [...]
>
> On the other hand, if recovering from the failure requires a lot of work, such
> as throwing away an object and constructing a new one, then you probably want
> to pay for the extra retries inside the strong compare-exchange operation in
> order to avoid an expensive recovery iteration.
>
> And of course if there is no iteration at all, then a spurious failure could
> be fatal.

Mr. Chen isn't specifically talking about mutexes here, but rather about
compare-and-exchange operations _in general_. If you are dealing directly with
an atomic operation, you are presumably fine-tuning your code and can pick
between weak or strong compare-and-exchange operations as appropriate. Swift's
`Mutex` is a general-purpose type, so it cannot know if failure to acquire it is
cheap or expensive. Any implementation of `Mutex` that is ultimately based on a
compare-and-exchange operation must pick one or the other up front (or provide
two parallel interfaces&mdash;see **Alternatives considered** below.)

## Proposed solution

I propose that the documentation for `Mutex.withLockIfAvailable(_:)` should
specifically and clearly indicate whether it can spuriously fail. That way,
developers who use `Mutex` will know what to expect from it and will (hopefully)
avoid being confused if they've also read the documentation for the C/C++'s
equivalents.

## Detailed design

I propose we strengthen the language in the **Return Value** documentation
section:

```diff
- The return value, if any, of the `body` closure parameter or `nil` if the lock
- couldn’t be acquired.
+ If the lock is acquired, the return value of the `body` closure. If the lock
+ is already held by any thread (including the current thread), `nil`.
```

And that we add the following **Note** callout to the **Discussion** section:

```diff
+ - Note: This function cannot spuriously fail to acquire the lock. The behavior
+   of similar functions in other languages (such as C's `mtx_trylock()`) is
+   platform-dependent and may differ from Swift's behavior.
```

## Source compatibility

This change only affects the documentation for an existing symbol. It has no
impact on existing Swift source.

## ABI compatibility

This proposal is purely a documentation change which can be implemented without
any ABI support.

## Implications on adoption

The documentation change itself is not something to be "adopted" by developers.
However (subjectively speaking) the existence of this guarantee allows those
developers to use `Mutex.withLockIfAvailable(_:)` without needing to be
concerned with spurious failures.

## Future directions

When we add support in Swift for new platforms, we will need to take care that
their implementations of `Mutex` are also not subject to spurious failures.

## Alternatives considered

- **Making no change.** This leaves our documentation ambiguous to e.g. systems
  programmers coming from C/C++ vs. those coming from Rust/Go/etc.

- **Documenting that `Mutex.withLockIfAvailable(_:)` _is_ subject to spurious
  failures.** This lets us be more flexible in how we implement the function on
  current and future platforms, but it is not currently true in any of our
  implementations. Besides, spurious failures violate the principle of least
  surprise and are not something you'd expect from a programming language that
  markets itself as safe and secure! To quote the documentation for GCC's
  `__atomic_compare_exchange_n()` (which clang's documentation refers us to):
  > When in doubt, use the strong variation.

- **Introducing explicit weak and strong variants of
  `Mutex.withLockIfAvailable(_:)` and letting developers choose which one to
  use.** This offloads the problem to individual developers, but in the general
  case does not provide developers with a _better_ API surface. Should the API
  default to a strong or weak operation? If there is no default, then how does a
  developer know when to use a strong `tryLock()` and when they can get away
  with a weak one?

## Acknowledgments

Thanks to the community members who provided feedback when I initially raised
this issue in the Swift forums.