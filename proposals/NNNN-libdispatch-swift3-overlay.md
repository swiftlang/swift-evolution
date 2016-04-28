# Update libdispatch overlay

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-libdispatch-swift3-overlay.md)
* Author(s): [Matt Wright](https://github.com/mwwa)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

The existing libdispatch module imports the C API almost verbatim. To move towards a more natural Swift interface and away from the C API, this proposal outlines changes to the libdispatch module and the motivation behind them.

This discussion focuses on the transformation of the existing libdispatch API.

## Motivation

libdispatch on Darwin already presents Objective-C compatible types to allow its objects to participate in automatic reference counting. We propose extending this support to present a design that feels “object-oriented” and inline with Swift 3's API guidelines, all without adding runtime overhead.

In Swift 2.2, libdispatch is exposed as a collection of functions imported from C. While trailing closure syntax does much to improve the basic usage of libdispatch, the experience in Swift still feels very C-like. As the introduction implies, we intend to transform the entire libdispatch API surface.

Previously, typical dispatch usage in Swift would look like:

```swift
let queue = dispatch_queue_create("com.test.myqueue", nil)
dispatch_async(queue) {
	print("Hello World")
}
```

This proposal will transform that code into:


```swift
let queue = DispatchQueue(label: "com.test.myqueue")
queue.asynchronously {
	print("Hello World")
}
```

## Detailed design

#### Type Naming

All of the types used by libdispatch will be renamed to meet the Swift 3 naming guidelines.

C type | Swift type
-------|-----------
dispatch\_object\_t | DispatchObject
dispatch\_queue\_t | DispatchQueue
dispatch\_group\_t | DispatchGroup
dispatch\_data\_t | DispatchData
dispatch\_io\_t | DispatchIO
dispatch\_semaphore\_t | DispatchSemaphore
dispatch\_source\_t | DispatchSource¹
dispatch\_time\_t | DispatchTime, DispatchWalltime

Several other libdispatch C types will be removed and replaced with their underlying type. These C typedefs serve to make the C API more clear as headerdoc, however in Swift these types are clearer when presented as their original type. Several other types will be replaced with ```OptionSet``` types, where appropriate.

C type | Swift type
--- | ---
dispatch\_fd\_t | Int32
dispatch\_block\_t | () -> ()
dispatch\_queue_attr\_t | DispatchQueueAttributes

**[1]** *Additional DispatchSource sub-types have also been introduced, a more thorough explanation is included below.*

#### Queues

Accessors to the main queue and global queues will be moved onto ```DispatchQueue``` as class properties.

```swift
class DispatchQueue : DispatchObject {
	class var main: DispatchQueue
	class func global(attributes: GlobalAttributes) -> DispatchQueue
}
```

Queue and group functions that are responsible for submitting work to dispatch queues will be transformed or replaced by Swift methods on ```DispatchQueue```. These existing functions act on, or with, queues and form a more cohesive API surface when presented on ```DispatchQueue``` itself. Previously these functions took the following form:

```swift
func dispatch_sync(queue: dispatch_queue_t, block: dispatch_block_t)
func dispatch_async(queue: dispatch_queue_t, block: dispatch_block_t)
func dispatch_group_async(group: dispatch_group_t, queue: dispatch_queue_t, block: dispatch_block_t)
```

This proposal collects these APIs into two methods on ```DispatchQueue``` and also introduces default parameters that cover QoS and work item flags. In turn this allows for control over block and QoS inheritance behaviour:

```swift
class DispatchQueue : DispatchObject {
	func synchronously(work: @convention(block) () -> Void)

	func asynchronously(
		group: DispatchGroup? = nil, 
		qos: DispatchQoS = .unspecified, 
		flags: DispatchWorkItemFlags = [], 
		work: @convention(block) () -> Void)
}

queue.asynchronously(group: group) {
	print("Hello World")
}

queue.synchronously {
	print("Hello World")
}
```

The existing ```dispatch_specific_*``` functions have a cumbersome interface when presented in Swift. These functions will also be refined in Swift, presenting a more typesafe API. The aim here is to provide the same underlying functionality but with additional type information, reducing the need for casting and opportunity for misuse.

Before:

```swift
func dispatch_get_specific(key: UnsafePointer<Void>) -> UnsafeMutablePointer<Void>
func dispatch_queue_get_specific(queue: dispatch_queue_t, _ key: UnsafePointer<Void>) -> UnsafeMutablePointer<Void>
func dispatch_queue_set_specific(queue: dispatch_queue_t, _ key: UnsafePointer<Void>, _ context: UnsafeMutablePointer<Void>, _ destructor: dispatch_function_t?)
```

After:

```swift
class DispatchSpecificKey<T> {
	init() {}
}

class DispatchQueue : DispatchObject {
	/// Return the Value? for a given DispatchSpecificKey object from
	/// the current dispatch queue hierarchy.
	class func getSpecific<Value>(key: DispatchSpecificKey<Value>) -> Value?

	/// Get and set the DispatchSpecificKey for this queue,
	/// providing type information via the DispatchSpecificKey
	/// specialisation.
	func getSpecific<Value>(key: DispatchSpecificKey<Value>) -> Value?
	func setSpecific<Value>(key: DispatchSpecificKey<Value>, value: Value?)
}

// Example usage, using a global key object
let akey = DispatchSpecificKey<Int>()
queue.setSpecific(key: akey, value: 42)
```

#### Work Items

The existing ```dispatch_block_*``` API group exposes functionality that produces ```dispatch_block_t``` blocks that are wrapped with additional metadata. That behaviour in C has multiple cases where this API group can be accidentally misused because the C types are ambiguously overloaded. This proposal will introduce a new explict class to cover this functionality, ```DispatchWorkItem``` that provides more explicit, safer typing.

```swift
class DispatchWorkItem {
	init(group: DispatchGroup? = nil, 
		qos: DispatchQoS = .unspecified, 
		flags: DispatchWorkItemFlags = [],
		block: () -> ())

	func perform()
	
	func wait(timeout: DispatchTime = .forever) -> Int
	
	func wait(timeout: DispatchWalltime) -> Int

	func notify(queue: DispatchQueue, block: @convention(block) () -> Void)

	func cancel()
	
	var isCancelled: Bool
}
```

All dispatch methods that accept blocks also accept ```DispatchWorkItem```:

```swift
let item = DispatchWorkItem(qos: .qosUserInitiated) {
	print("Hello World")
}

queue.asynchronously(execute: item)
```

#### Time

libdispatch exposes a lightweight representation of time², focussing on deadlines and intervals for timers. However, the C interfaces for ```dispatch_time_t``` are very unfortunately imported in Swift 2.2, with type impedance problems that require unnecessary casting in order to use in Swift. This proposal will replace ```dispatch_time_t``` with two new time types and one interval type. ```DispatchTime```, ```DispatchWallTime``` and ```DispatchTimeInterval```.

```swift
struct DispatchTime {
	static func now() -> DispatchTime
	static let forever: DispatchTime
}

struct DispatchWalltime {
	static func now() -> DispatchWalltime
	static let forever: DispatchWalltime

	init(time: timespec)
}

enum DispatchTimeInterval {
	case seconds(Int)
	case milliseconds(Int)
	case microseconds(Int)
	case nanoseconds(Int)
}

func +(time: DispatchTime, interval: DispatchTimeInterval) -> DispatchTime
func -(time: DispatchTime, interval: DispatchTimeInterval) -> DispatchTime
func +(time: DispatchTime, seconds: Double) -> DispatchTime
func -(time: DispatchTime, seconds: Double) -> DispatchTime
func +(time: DispatchWalltime, interval: DispatchTimeInterval) -> DispatchWalltime
func -(time: DispatchWalltime, interval: DispatchTimeInterval) -> DispatchWalltime
func +(time: DispatchWalltime, seconds: Double) -> DispatchWalltime
func -(time: DispatchWalltime, seconds: Double) -> DispatchWalltime
```

The aim here is to continue to provide a lightweight representation of time, while distinguishing between time and interval quantities. Time, to be used to set deadlines, and intervals used to represent the period of repeating events. This model also allows for the expression of time and intervals either as natural second-addition, or with explicit sub-second quantities.

```swift
let a = DispatchTime.now + 3.5 // 3.5 seconds in the future
let b = DispatchTime.now + .microseconds(350)

// Modify a DispatchSourceTimer with new start time and interval
timer.setTimer(start: .now, interval: .milliseconds(500))
```

**[2]** *Note that libdispatch is unable to use ```Date``` from Foundation due to layering restrictions*

#### Data

```dispatch_data_t``` will be transformed into a value type, ```DispatchData```. Data objects in libdispatch have always been immutable objects, so these objects are natural candidates for value semantics in Swift.

```swift
struct DispatchData : RandomAccessCollection, _ObjectiveCBridgeable {
	enum Deallocator {
		/// Use `free`
		case free

		/// Use `munmap`
		case unmap

		/// A custom deallocator
		case custom(DispatchQueue?, @convention(block) () -> Void)
	}

	/// Initialize a `Data` with copied memory content.
	init(bytes buffer: UnsafeBufferPointer<UInt8>)
	
	/// Initialize a `Data` without copying the bytes.
	init(bytesNoCopy bytes: UnsafeBufferPointer<UInt8>, deallocator: Deallocator = .free)
	
	mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int)
		
	mutating func append(_ other: DispatchData)
		
	mutating func append<SourceType>(_ buffer: UnsafeBufferPointer<SourceType>)
		
	func subdata(in range: CountableRange<Index>) -> DispatchData
		
	func region(location: Int) -> (DispatchData, Int)

}
```

This proposal will introduce new accessor methods to access the bytes in a Data object. Along with becoming iteratable, several methods will be introduced that replace the ```dispatch_data_create_map``` approach used in C:

```swift
struct DispatchData : RandomAccessCollection, _ObjectiveCBridgeable {
	func withUnsafeBytes<Result, ContentType>(
		body: @noescape (UnsafePointer<ContentType>) throws -> Result) rethrows -> Result
		
	func enumerateBytes(
		block: @noescape (buffer: UnsafeBufferPointer<UInt8>, byteIndex: Int, stop: inout Bool) -> Void)
		
	func copyBytes(to pointer: UnsafeMutablePointer<UInt8>, count: Int)
	
	func copyBytes(
		to pointer: UnsafeMutablePointer<UInt8>, 
		from range: Range<Index>)
	
	func copyBytes<DestinationType>(
		to buffer: UnsafeMutableBufferPointer<DestinationType>, 
		from range: Range<Index>? = nil) -> Int
		
	subscript(index: Index) -> UInt8
}

```

#### Sources

Finally, this proposal will introduce additional type safety to dispatch sources. While adding additional DispatchSource subclasses is out of scope for this proposal, it will introduce a new constructor for each dispatch source type.

Kind of Source | Protocol
--- | ---
DISPATCH\_SOURCE\_TYPE\_DATA\_ADD | DispatchSourceUserDataAdd
DISPATCH\_SOURCE\_TYPE\_DATA\_OR | DispatchSourceUserDataOr
DISPATCH\_SOURCE\_TYPE\_MACH\_SEND | DispatchSourceMachSend
DISPATCH\_SOURCE\_TYPE\_MACH\_RECV | DispatchSourceMachRecv
DISPATCH\_SOURCE\_TYPE\_MEMORYPRESSURE | DispatchSourceMemoryPressure
DISPATCH\_SOURCE\_TYPE\_PROC | DispatchSourceProcess
DISPATCH\_SOURCE\_TYPE\_READ | DispatchSourceRead
DISPATCH\_SOURCE\_TYPE\_SIGNAL | DispatchSourceSignal
DISPATCH\_SOURCE\_TYPE\_TIMER | DispatchSourceTimer
DISPATCH\_SOURCE\_TYPE\_VNODE | DispatchSourceFileSystemObject
DISPATCH\_SOURCE\_TYPE\_WRITE | DispatchSourceWrite

Introducing protocols for each source allows DispatchSource to return protocols that are more strongly typed then their C equivalent. Furthermore, this proposal also adds stronger typing to return types of dispatch source accessors, where appropriate:

```swift
class DispatchSource {
	class func fileSystemObject(fileDescriptor: Int32, eventMask: FileSystemEvent, queue: DispatchQueue? = nil) -> DispatchSourceFileSystemObject

	class func machSend(port: mach_port_t, eventMask: MachSendEvent, queue: DispatchQueue? = nil) -> DispatchSourceMachSend

	class func machReceive(port: mach_port_t, queue: DispatchQueue? = nil) -> DispatchSourceMachReceive

	class func memoryPressure(eventMask: MemoryPressureEvent, queue: DispatchQueue? = nil) -> DispatchSourceMemoryPressure

	class func process(identifier: pid_t, eventMask: ProcessEvent, queue: DispatchQueue? = nil) -> DispatchSourceProcess

	class func read(fileDescriptor: Int32, queue: DispatchQueue? = nil) -> DispatchSourceRead

	class func signal(signal: Int, queue: DispatchQueue? = nil) -> DispatchSourceSignal
	
	class func timer(flags: TimerFlags = [], queue: DispatchQueue? = nil) -> DispatchSourceTimer

	class func userDataAdd(queue: DispatchQueue? = nil) -> DispatchSourceUserDataAdd

	class func userDataOr(queue: DispatchQueue? = nil) -> DispatchSourceUserDataOr

	class func write(fileDescriptor: Int32, queue: DispatchQueue? = nil) -> DispatchSourceWrite
}
```

```swift
class DispatchSource {
	struct ProcessEvent : OptionSet, RawRepresentable {
		let rawValue: UInt
		
		init(rawValue: UInt)

		static let exit: ProcessEvent
		
		static let fork: ProcessEvent
		
		static let exec: ProcessEvent
		
		static let signal: ProcessEvent
		
		static let all: ProcessEvent = [.exit, .fork, .exec, .signal]
	}
}

extension DispatchSourceProcess {
	var handle: pid_t
	
	var data: DispatchSource.ProcessEvent
	
	var mask: DispatchSource.ProcessEvent
}

extension DispatchSourceUserDataAdd {
  func mergeData(value: UInt)
}
```

## Impact on existing code

All Swift code that uses libdispatch via the current C API will be affected by this change.

## Alternatives considered

The alternative here was to leave the libdispatch API as it is currently imported in C. This proposal aims to improve the experience of using libdispatch in Swift and we did not feel that leaving the API as-is was a viable alternative.
