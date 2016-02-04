# Implementing `Comparable` On `NSOperatingSystemVersion`

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Robert S Mozayeni](https://github.com/rsmoz)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

`NSOperatingSystemVersion` is a struct in Foundation that contains information about the operating system of the current machine: `majorVersion`, `minorVersion`, and `patchVersion`. I believe that implementing `Comparable` on `NSOperatingSystemVersion` would make it more convenient to use.

Also, I propose adding this initializer:


	public init(_ majorVersion: Int, _ minorVersion: Int, _ patchVersion: Int) {
 	       self.init(majorVersion: majorVersion, minorVersion: minorVersion, patchVersion: patchVersion)
	}



This is not just an improvement in terms of brevity, but also in terms of clarity. It's the difference between

`NSOperatingSystemVersion(majorVersion: 10, minorVersion: 11, patchVersion: 4)`

and

`NSOperatingSystemVersion(10,11,4)`


## Motivation

I ran this past [Robert Widmann](https://github.com/CodaFi/), and I liked his way of explaining the motivation: "It’s a value type with a clear ordering, why not?"

## Proposed solution

	extension NSOperatingSystemVersion : Comparable {
        public init(_ majorVersion: Int, _ minorVersion: Int, _ patchVersion: Int) {
            self.init(majorVersion: majorVersion, minorVersion: minorVersion, patchVersion: patchVersion)
        }
    }
	
	public func ==(lhs: NSOperatingSystemVersion, rhs: NSOperatingSystemVersion) -> Bool {
		let lhsTuple = (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion)
		let rhsTuple = (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    
		return lhsTuple == rhsTuple
	}

	public func <(lhs: NSOperatingSystemVersion, rhs: NSOperatingSystemVersion) -> Bool {
	    let lhsTuple = (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion)
		let rhsTuple = (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    
		return lhsTuple < rhsTuple
	}

Also, with a `Comparable` `NSOperatingSystemVersion`, `isOperatingSystemAtLeastVersion` can be shortened to:

	public func isOperatingSystemAtLeastVersion(version: NSOperatingSystemVersion) -> Bool {
		return operatingSystemVersion >= version
	}

You can find my commits [here](https://github.com/apple/swift-corelibs-foundation/pull/240).

## Detailed design

Because NSOperatingSystemVersion is an imported C struct, changes must necessarily be added via an extension.

I also [implemented tests](https://github.com/rsmoz/swift-corelibs-foundation/commit/db44f29e42f29ad0fe35f69ac83d853453c77bc6) for `NSOperatingSystemVersion`. I included tests for both less-than and greater-than comparisons, to protect against false positives in the implementation of `<`.

## Impact on existing code

No existing code will be made invalid.

## Alternatives considered

The alternative would be manual comparison (example from Foundation):

	public func isOperatingSystemAtLeastVersion(version: NSOperatingSystemVersion) -> Bool {
		let ourVersion = operatingSystemVersion
		if ourVersion.majorVersion < version.majorVersion {
			return false
		}
		if ourVersion.majorVersion > version.majorVersion {
			return true
		}
		if ourVersion.minorVersion < version.minorVersion {
			return false
		}
		if ourVersion.minorVersion > version.minorVersion {
			return true
		}
		if ourVersion.patchVersion < version.patchVersion {
			return false
		}
		if ourVersion.patchVersion > version.patchVersion {
			return true
		}
		return true
	}


