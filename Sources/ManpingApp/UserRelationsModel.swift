import ManpingCore
import Foundation
import SwiftUI

/// Each loaded relation retains its account boundary until an explicit user mutation.
@MainActor final class UserRelationsModel: ObservableObject {
  @Published private(set) var relations: [Int64: BiliUserRelation] = [:]
  @Published private(set) var busy: Set<Int64> = []
  @Published private(set) var errors: [Int64: String] = [:]
  @Published private(set) var selfID: Int64?
  @Published private(set) var identityVersion = 0
  private let service: BiliService
  private var identity: AuthIdentityEvent?
  private var snapshots: [Int64: AuthSnapshot] = [:]
  private var tracked: Set<Int64> = []
  private var generation = UUID()
  private var reads: [Int64: Task<Void, Never>] = [:]
  private var writes: [Int64: Task<Void, Never>] = [:]
  private var observer: Task<Void, Never>?

  init(service: BiliService) {
    self.service = service
    observer = Task { [weak self, service] in
      for await event in await service.identityEvents() {
        guard let self, !Task.isCancelled else { return }
        let previous = self.identity
        self.identity = event; self.selfID = event.mid
        let changed = previous.map {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        } ?? self.snapshots.values.contains {
          $0.epoch != event.epoch || $0.identityRevision != event.identityRevision
        }
        if changed {
          self.cancel(); self.identityVersion += 1
          for mid in self.tracked { self.startLoad(mid: mid) }
        }
      }
    }
  }
  deinit {
    observer?.cancel()
    for task in reads.values { task.cancel() }
    for task in writes.values { task.cancel() }
  }
  func cancel() {
    generation = UUID()
    for task in reads.values { task.cancel() }
    for task in writes.values { task.cancel() }
    reads = [:]; writes = [:]; snapshots = [:]; relations = [:]; errors = [:]; busy = []
  }
  func canToggle(_ mid: Int64) -> Bool {
    mid > 0 && mid != selfID && !busy.contains(mid)
      && relations[mid]?.isFollowing != nil && snapshots[mid] != nil
  }
  func load(mid: Int64) async {
    guard mid > 0 else { return }
    tracked.insert(mid)
    if relations[mid] == nil && reads[mid] == nil { startLoad(mid: mid) }
    if let task = reads[mid] { await task.value }
  }
  func refresh(mid: Int64) {
    guard !busy.contains(mid) else { return }
    reads[mid]?.cancel(); reads[mid] = nil; relations[mid] = nil; snapshots[mid] = nil
    startLoad(mid: mid)
  }
  private func startLoad(mid: Int64) {
    guard mid > 0, reads[mid] == nil else { return }
    let revision = generation
    errors[mid] = nil
    reads[mid] = Task { [weak self, service] in
      do {
        let initial = await service.authSnapshot()
        let snapshot = try await service.authorizeAppInteraction(expectedIdentity: initial)
        guard mid != snapshot.token?.mid else {
          guard let self, self.generation == revision else { return }
          self.selfID = snapshot.token?.mid; self.relations[mid] = .unknown
          self.reads[mid] = nil; return
        }
        let value = try await service.libraryRelationship(mid: mid, expectedIdentity: snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard let self, self.generation == revision, self.matches(snapshot, current) else { return }
        self.selfID = snapshot.token?.mid
        self.relations[mid] = value; self.snapshots[mid] = snapshot; self.reads[mid] = nil
      } catch {
        guard let self, self.generation == revision, !Task.isCancelled else { return }
        self.reads[mid] = nil; self.relations[mid] = .unknown
        if !(error is CancellationError) { self.errors[mid] = error.localizedDescription }
      }
    }
  }
  func toggle(mid: Int64, requiresLogin: @escaping () -> Void) async {
    guard canToggle(mid), let previous = relations[mid]?.isFollowing,
      let expected = snapshots[mid] else { return }
    let revision = generation; let target = !previous
    busy.insert(mid); errors[mid] = nil
    let task = Task { [weak self, service] in
      do {
        let snapshot = try await service.authorizeAppInteraction(expectedIdentity: expected)
        try Task.checkCancellation()
        guard let self, self.generation == revision, mid != snapshot.token?.mid,
          self.matches(expected, snapshot) else { throw CancellationError() }
        try await service.setFollowing(mid: mid, following: target, expectedIdentity: snapshot)
        let current = await service.authSnapshot()
        try Task.checkCancellation()
        guard self.generation == revision, self.matches(snapshot, current) else { return }
        self.relations[mid] = target ? .following : .unfollowed
        self.snapshots[mid] = snapshot
        self.busy.remove(mid); self.writes[mid] = nil
      } catch {
        guard let self, self.generation == revision else { return }
        self.busy.remove(mid); self.writes[mid] = nil
        if let auth = error as? AuthFailure, case .needsLogin = auth { requiresLogin() }
        else if !(error is CancellationError) { self.errors[mid] = error.localizedDescription }
      }
    }
    writes[mid] = task
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  private func matches(_ lhs: AuthSnapshot, _ rhs: AuthSnapshot) -> Bool {
    lhs.epoch == rhs.epoch && lhs.identityRevision == rhs.identityRevision
      && lhs.token?.mid == rhs.token?.mid
  }
}
