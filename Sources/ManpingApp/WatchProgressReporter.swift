import Foundation
import ManpingCore

@MainActor protocol WatchProgressSource: AnyObject {
  var time: Double { get }
  var paused: Bool { get }
  var eofReached: Bool { get }
  var hasPlaybackSample: Bool { get }
}

@MainActor final class WatchProgressReporter {
  struct Item: Equatable {
    let aid: Int64
    let cid: Int64
    var episode: Int64?
    var season: Int64?
  }

  private struct Sample {
    let item: Item
    let identity: AuthSnapshot
    let seconds: Int
    let final: Bool

    func sameMedia(as other: Sample) -> Bool {
      item == other.item && identity.sameIdentity(as: other.identity)
    }
  }

  typealias Submit = (Item, Int, AuthSnapshot) async throws -> Void
  private let submit: Submit
  private let enabled: () -> Bool
  private let checkpoint: (Item, AuthSnapshot, Int) -> Void
  private let feedback: (String?) -> Void
  private weak var player: (any WatchProgressSource)?
  private var item: Item?
  private var identity: AuthSnapshot?
  private var timer: Timer?
  private var queue: [Sample] = []
  private var worker: Task<Void, Never>?
  private var confirmed: Sample?
  var onConfirmed: ((Item, Int, AuthSnapshot) -> Void)?

  init(enabled: @escaping () -> Bool, checkpoint: @escaping (Item, AuthSnapshot, Int) -> Void,
       feedback: @escaping (String?) -> Void, submit: @escaping Submit) {
    self.enabled = enabled; self.checkpoint = checkpoint; self.feedback = feedback; self.submit = submit
  }

  func begin(_ next: Item, player: any WatchProgressSource, identity nextIdentity: AuthSnapshot) {
    identityChanged(to: nextIdentity)
    if item == next, self.player === player { return }
    flush()
    item = next; self.player = player; identity = nextIdentity
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sample(final: false) }
    }
  }

  func flush() {
    sample(final: true)
    stopTimer()
  }

  private func stopTimer() {
    timer?.invalidate(); timer = nil; item = nil; player = nil
  }

  func identityChanged(to snapshot: AuthSnapshot) {
    if let identity, !identity.sameIdentity(as: snapshot) {
      stopTimer()
      queue.removeAll(); confirmed = nil
      feedback(nil)
    }
    identity = snapshot
  }

  func sample(final: Bool) {
    guard let item, let player, let identity, player.hasPlaybackSample,
          final || !player.paused else { return }
    let position = player.time
    guard position.isFinite, position < Double(Int.max), position >= 1 || player.eofReached else { return }
    let seconds = max(0, Int(max(0, position)))
    checkpoint(item, identity, player.eofReached ? 0 : seconds)
    guard enabled(), seconds > 0, identity.canAttemptHistoryReport else { return }
    let sample = Sample(item: item, identity: identity, seconds: seconds, final: final)
    // Coalesce only queued values; the running request always finishes first. Seeking back
    // is a newer position even when its numeric value is smaller.
    queue.removeAll { $0.sameMedia(as: sample) }
    queue.append(sample)
    if worker == nil {
      worker = Task { await self.drain() }
    }
  }

  private func drain() async {
    while !queue.isEmpty {
      let sample = queue.removeFirst()
      guard enabled(), identity?.sameIdentity(as: sample.identity) == true else { continue }
      if let confirmed, confirmed.sameMedia(as: sample), confirmed.seconds == sample.seconds { continue }
      do {
        try await submit(sample.item, sample.seconds, sample.identity)
        guard identity?.sameIdentity(as: sample.identity) == true else { continue }
        confirmed = sample
        onConfirmed?(sample.item, sample.seconds, sample.identity)
        feedback(nil)
      } catch is CancellationError {
        continue
      } catch {
        guard identity?.sameIdentity(as: sample.identity) == true, enabled() else { continue }
        if let confirmed, confirmed.sameMedia(as: sample) { self.confirmed = nil }
        feedback(Self.message(error))
        if sample.final, Self.retryable(error), !queue.contains(where: { $0.sameMedia(as: sample) }) {
          // Requeue once; a newer pending position supersedes the final retry.
          queue.append(Sample(item: sample.item, identity: sample.identity, seconds: sample.seconds, final: false))
        }
      }
    }
    worker = nil
  }

  var hasPendingReports: Bool { worker != nil }
  func waitForReports() async { await worker?.value }

  private static func retryable(_ error: Error) -> Bool {
    if error is URLError { return true }
    if case AuthFailure.transport = error { return true }
    if case BiliError.http(let status) = error { return (500...599).contains(status) }
    return false
  }

  private static func message(_ error: Error) -> String {
    switch error {
    case AuthFailure.needsLogin: "同步观看进度需要有效的 App 登录凭据，请重新扫码登录。"
    case BiliError.http(let status): "观看进度同步失败（HTTP \(status)）。"
    case BiliError.api(let code, _), AuthFailure.rejected(let code): "哔哩哔哩未接受观看进度（\(code)）。"
    default: "观看进度同步失败，请检查网络后重试。"
    }
  }
}
