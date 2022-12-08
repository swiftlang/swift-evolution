# Swift Mach Port Interface

* Proposal: SE-0381
* Author(s): Daniel Loffgren <loffgren@apple.com>
* Status: **Review**
* Implementation: [apple/swift-system#116](https://github.com/apple/swift-system/pull/116)

## Introduction

Mach ports are an arcane technology that is difficult to wield safely.
However, as an integral component of our operating system, they occasionally require handling.

This proposal makes extenisve use of mach port terminology. Below are some resources that explain the basics.

- [Ports, Port Rights, Port Sets, and Port Namespaces ](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/Mach/Mach.html#//apple_ref/doc/uid/TP30000905-CH209-TPXREF104)

## Motivation

Mach ports are difficult to get right, due mostly to how mach port rights are managed. Programmers are expected to track types, lifecycles, and other state in their heads.

Swift's advanced type system, recently augmented with [move-only types](https://github.com/apple/swift-evolution/blob/main/proposals/0366-move-function.md), provides a new opportunity to create a Mach port interface able to prevent entire classes of bugs at compile time.

## Proposed solution

- Establish distinct types to represent recieve, send, and send-once rights.
- Provide automatic lifecycle management of Mach port rights, which are unlike normal OOP objects.

## Detailed design

`Mach.Port<T>` is the managed equivalent of a `mach_port_name_t`.
Mach port names can be moved in and out of instances as needed using `init` and `relinquish`.

```swift
func doStuffWithSendRightThenReturnIt(name:mach_port_name_t) -> mach_port_name_t {
	let send = Mach.Port<Mach.SendRight>(name)
	/* ... */
	return once.relinquish()
}
```

### Types

There are three types of Mach port right: receive, send, and send-once. In the C interface, the type of right being manipulated is not known by the compiler. In this Swift interface, the types explicitly declare which rights can be created from what other rights, and in what way, eliminating `KERN_INVALID_RIGHT` runtime failures.

### Allocation

Send and receive (but not send-once) port names are coalesced. In this interface, the caller is no longer involved in specifying the destination name when creating new rights. So, the `KERN_RIGHT_EXISTS` runtime error is not possible.

### Automatic Deallocation

All valid (in the Mach sense) port rights must be deallocated exactly once, including dead names. So, rights are deallocated when the object is deinited, unless a right is relinquished, in which case ownership is transferred out of the object and automatic deallocation at destruction is disabled. For receive ports this is a mod refs -1, but the intent is the same.

There is very little functional difference between `MACH_PORT_DEAD` and a valid dead name; `MACH_PORT_DEAD` simply means the port died before entering the task that received it. However, `MACH_PORT_DEAD` does not represent a right that requires deallocation. So, for convenience, constructing rights with `MACH_PORT_DEAD` is allowed, but automatic deallocation won't happen.

### Limits

The ipc space (the kernel-side storage of a proc's Mach port state) should be large enough to fit any reasonable workload. So, any time there is not enough ipc space to create a new right (`KERN_NO_SPACE`), the process will abort with a message indicating a possible bug. In the swift interface this is only possible when creating recieve or send-once rights.

Similar to ipc space, the uref field should be wide enough to fit any reasonable workload. So, in cases where a uref would overflow (`KERN_UREFS_OVERFLOW`), the process is aborted with a message indicating a possible bug.

### Swift Interface

```swift
#if $MoveOnly && (os(macOS) || os(iOS) || os(watchOS) || os(tvOS))

import Darwin.Mach

protocol MachPortRight {}

enum Mach {
    @_moveOnly
    struct Port<RightType:MachPortRight> {
        /// Transfer ownership of an existing unmanaged Mach port right into a
        /// Mach.Port by name.
        ///
        /// This initializer aborts if name is MACH_PORT_NULL.
        ///
        /// If the type of the right does not match the type T of Mach.Port<T>
        /// being constructed, behavior is undefined.
        ///
        /// The underlying port right will be automatically deallocated at the
        /// end of the Mach.Port instance's lifetime.
        ///
        /// This initializer makes a syscall to guard the right.
        init(name: mach_port_name_t)

        /// Borrow access to the port name in a block that can perform
        /// non-consuming operations.
        ///
        /// Take care when using this function; many operations consume rights,
        /// and send-once rights are easily consumed.
        ///
        /// If the right is consumed, behavior is undefined.
        ///
        /// The body block may optionally return something, which will then be
        /// returned to the caller of withBorrowedName.
        func withBorrowedName<ReturnType>(body: (mach_port_name_t) -> ReturnType) -> ReturnType
    }

    /// Possible errors that can be thrown by Mach.Port operations.
    enum PortRightError : Error {
        /// Returned when an operation cannot be completed, because the Mach
        /// port right has become a dead name. This is caused by deallocation of the
        /// receive right on the other end.
        case deadName
    }

    /// The MachPortRight type used to manage a receive right.
    struct ReceiveRight : MachPortRight {}

    /// The MachPortRight type used to manage a send right.
    struct SendRight : MachPortRight {}

    /// The MachPortRight type used to manage a send-once right.
    ///
    /// Send-once rights are the most restrictive type of Mach port rights.
    /// They cannot create other rights, and are consumed upon use.
    ///
    /// Upon destruction a send-once notification will be sent to the
    /// receiving end.
    struct SendOnceRight : MachPortRight {}

    /// Create a connected pair of rights, one receive, and one send.
    ///
    /// This function will abort if the rights could not be created.
    /// Callers may assert that valid rights are always returned.
    static func allocatePortRightPair() -> (Mach.Port<Mach.ReceiveRight>, Mach.Port<Mach.SendRight>)
}

extension Mach.Port where RightType == Mach.ReceiveRight {
    /// Transfer ownership of an existing, unmanaged, but already guarded,
    /// Mach port right into a Mach.Port by name.
    ///
    /// This initializer aborts if name is MACH_PORT_NULL.
    ///
    /// If the type of the right does not match the type T of Mach.Port<T>
    /// being constructed, the behavior is undefined.
    ///
    /// The underlying port right will be automatically deallocated when
    /// the Mach.Port object is destroyed.
    init(name: mach_port_name_t, context: mach_port_context_t)

    /// Allocate a new Mach port with a receive right, creating a
    /// Mach.Port<Mach.ReceiveRight> to manage it.
    ///
    /// This initializer will abort if the right could not be created.
    /// Callers may assert that a valid right is always returned.
    init()

    /// Transfer ownership of the underlying port right to the caller.
    ///
    /// Returns a tuple containing the Mach port name representing the right,
    /// and the context value used to guard the right.
    ///
    /// This operation liberates the right from management by the Mach.Port,
    /// and the underlying right will no longer be automatically deallocated.
    ///
    /// After this function completes, the Mach.Port is destroyed and no longer
    /// usable.
    __consuming func relinquish() -> (mach_port_name_t, mach_port_context_t)

    /// Remove guard and transfer ownership of the underlying port right to
    /// the caller.
    ///
    /// Returns the Mach port name representing the right.
    ///
    /// This operation liberates the right from management by the Mach.Port,
    /// and the underlying right will no longer be automatically deallocated.
    ///
    /// After this function completes, the Mach.Port is destroyed and no longer
    /// usable.
    ///
    /// This function makes a syscall to remove the guard from
    /// Mach.ReceiveRights. Use relinquish() to avoid the syscall and extract
    /// the context value along with the port name.
    __consuming func unguardAndRelinquish() -> mach_port_name_t

    /// Borrow access to the port name in a block that can perform
    /// non-consuming operations.
    ///
    /// Take care when using this function; many operations consume rights.
    ///
    /// If the right is consumed, behavior is undefined.
    ///
    /// The body block may optionally return something, which will then be
    /// returned to the caller of withBorrowedName.
    func withBorrowedName<ReturnType>(body: (mach_port_name_t, mach_port_context_t) -> ReturnType) -> ReturnType

    /// Create a send-once right for a given receive right.
    ///
    /// This does not affect the makeSendCount of the receive right.
    ///
    /// This function will abort if the right could not be created.
    /// Callers may assert that a valid right is always returned.
    func makeSendOnceRight() -> Mach.Port<Mach.SendOnceRight>

    /// Create a send right for a given receive right.
    ///
    /// This increments the makeSendCount of the receive right.
    ///
    /// This function will abort if the right could not be created.
    /// Callers may assert that a valid right is always returned.
    func makeSendRight() -> Mach.Port<Mach.SendRight>

    /// Access the make-send count.
    ///
    /// Each get/set of this property makes a syscall.
    var makeSendCount : mach_port_mscount_t { get set }
}

extension Mach.Port where RightType == Mach.SendRight {
    /// Transfer ownership of the underlying port right to the caller.
    ///
    /// Returns the Mach port name representing the right.
    ///
    /// This operation liberates the right from management by the Mach.Port,
    /// and the underlying right will no longer be automatically deallocated.
    ///
    /// After this function completes, the Mach.Port is destroyed and no longer
    /// usable.
    __consuming func relinquish() -> mach_port_name_t

    /// Create another send right from a given send right.
    ///
    /// This does not affect the makeSendCount of the receive right.
    ///
    /// If the send right being copied has become a dead name, meaning the
    /// receiving side has been deallocated, then copySendRight() will throw
    /// a Mach.PortRightError.deadName error.
    func copySendRight() throws -> Mach.Port<Mach.SendRight>
}


extension Mach.Port where RightType == Mach.SendOnceRight {
    /// Transfer ownership of the underlying port right to the caller.
    ///
    /// Returns the Mach port name representing the right.
    ///
    /// This operation liberates the right from management by the Mach.Port,
    /// and the underlying right will no longer be automatically deallocated.
    ///
    /// After this function completes, the Mach.Port is destroyed and no longer
    /// usable.
    __consuming func relinquish() -> mach_port_name_t
}

#endif
```

## Alternatives considered

Having the port rights be `RawRepresentable<mach_port_name_t>`, which encourages passing instances to functions that will implicitly cast to `mach_port_name_t`. Since these APIs often consume the right, this requires manual management of the right's lifecycle.
