class MutableRef { var x: Int = 0 }
typealias V = Int
typealias NonSendableType = MutableRef

@Sendable func inspect(_ r: MutableRef) async { /* ex: creates a concurrent task to update r */ }

actor MyActor {
  var ref: MutableRef = MutableRef()  // MutableRef is not Sendable

  func check() {
    // inspect(ref) // warning: non-sendable type 'MutableRef' exiting actor-isolated context in call to non-isolated global function 'inspect' cannot cross actor boundary
  }
}

extension MyActor {
  func update(_ ref: MutableRef) { /* ... */}
  
  func test(_ g: @Sendable (MutableRef) async -> ()) async {
    let f: (MutableRef) async -> () = self.update
    
    let ref = MutableRef()
    await f(ref) // Must be OK.
    await g(ref) // Should be an error.
  }
}

func ex(_ ma: MyActor) async {
  await ma.test(inspect)
}

// actor I {
//   nonisolated func nonIsoTakingNonSendable(_: NonSendableType) -> V {0}
//   func isoTakingNonSendable(_: NonSendableType) -> V {0}
//   func asyncIsoTakingNonSendable(_: NonSendableType) async -> V {0}
//   func isoTakingSendable(_: V) -> V {0}
// }

// extension I {
//   func test(_ g: @Sendable (NonSendableType) async -> V) async {
//     let f = self.asyncIsoTakingNonSendable as (NonSendableType) async -> V
//     _ = await f(NonSendableType())
//     _ = await g(NonSendableType())
//   }
// }