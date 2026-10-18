import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// What is playing, offered to the rest of Apple's devices and to Spotlight:
/// - Handoff: a browsing-web activity with the bilibili.com page, so an iPhone, iPad or another
///   Mac continues in Safari (or the Bilibili app through its universal links).
/// - Spotlight: recently watched items, searchable by title and author; picking one reopens it
///   here through its `manping://` link. Cleared on sign-out or when the setting is turned off.
@MainActor final class WatchActivity {
  nonisolated static let domain = "io.github.pidean.manping.watched"
  private var activity: NSUserActivity?
  var indexesSpotlight = true

  struct Item {
    let link: String
    let web: URL
    let title: String
    let author: String
    let cover: URL?
  }

  /// Both Handoff and the Spotlight index follow the one setting, so turning it off keeps the
  /// current title off other devices as well.
  func begin(_ item: Item) {
    activity?.invalidate()
    activity = nil
    guard indexesSpotlight else { return }
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.title = item.title
    activity.webpageURL = item.web
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.becomeCurrent()
    self.activity = activity
    index(item)
  }

  func end() {
    activity?.invalidate()
    activity = nil
  }

  private func index(_ item: Item) {
    let attributes = CSSearchableItemAttributeSet(contentType: .movie)
    attributes.title = item.title
    attributes.contentDescription = item.author.isEmpty ? "满屏 · 看过" : "\(item.author) · 看过"
    attributes.thumbnailURL = nil
    attributes.contentURL = item.web
    let entry = CSSearchableItem(uniqueIdentifier: item.link, domainIdentifier: Self.domain, attributeSet: attributes)
    entry.expirationDate = Date().addingTimeInterval(90 * 24 * 3600)
    Self.submit(entry)
  }

  /// Removes everything this app put into Spotlight.
  func clearSpotlight() { Self.removeAll() }

  // CoreSpotlight calls its handlers on its own queues. Closures formed inside this @MainActor
  // class would inherit main-actor isolation and trap under Swift 6, so build them nonisolated.
  private nonisolated static func submit(_ entry: CSSearchableItem) {
    CSSearchableIndex.default().indexSearchableItems([entry]) { @Sendable _ in }
  }
  private nonisolated static func removeAll() {
    CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { @Sendable _ in }
  }

  #if DEBUG
  /// `--ui-spotlight-check`: logs how many items this app has in Spotlight (titles only).
  nonisolated static func debugReport() {
    let context = CSSearchQueryContext()
    context.fetchAttributes = ["title"]
    let query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
    final class Titles: @unchecked Sendable {
      let lock = NSLock(); var values: [String] = []
      func add(_ more: [String]) { lock.lock(); values += more; lock.unlock() }
    }
    let titles = Titles()
    query.foundItemsHandler = { @Sendable items in titles.add(items.compactMap { $0.attributeSet.title }) }
    query.completionHandler = { @Sendable error in
      titles.lock.lock(); let found = titles.values; titles.lock.unlock()
      FileHandle.standardError.write(Data("spotlight-check items=\(found.count) error=\(error.map { "\($0)" } ?? "none") titles=\(found)\n".utf8))
    }
    query.start()
  }
  #endif
}
