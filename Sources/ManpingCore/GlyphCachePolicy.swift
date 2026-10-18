/// Immutable atlas generations. Historical pages are bounded; a submitted frame owns its pages
/// until completion, even after those generations leave the LRU cache.
public struct GlyphCachePolicy {
  public struct Address: Equatable, Sendable {
    public let page: Int
    public let slot: Int
  }
  public struct Frame {
    public let addresses: [Character: Address]
    public let created: [Int: [Character]]
    public let pages: Set<Int>
    public let copied: [Character: Address]
  }
  private var cache: [Int: [Character]] = [:]
  private var order: [Int] = []
  private var active: Set<Int> = []
  private var nextPage = 0
  public let slotsPerPage: Int
  public let historyPages: Int
  public var cachedPageCount: Int { cache.count - active.count }
  public var activePageCount: Int { active.count }
  public init(slotsPerPage: Int = 256, historyPages: Int = 8) {
    precondition(slotsPerPage > 0 && historyPages > 0)
    self.slotsPerPage = slotsPerPage
    self.historyPages = historyPages
  }
  public mutating func prepare(_ characters: [Character]) -> Frame {
    let required = Set(characters)
    var addresses: [Character: Address] = [:]
    var used: Set<Int> = []
    for page in order {
      for (slot, character) in (cache[page] ?? []).enumerated() where required.contains(character) {
        addresses[character] = Address(page: page, slot: slot)
        used.insert(page)
      }
    }
    var seen = Set(addresses.keys)
    var missing = characters.filter { seen.insert($0).inserted }
    var copied: [Character: Address] = [:]
    let packedPages = (required.count + slotsPerPage - 1) / slotsPerPage
    let newPages = (missing.count + slotsPerPage - 1) / slotsPerPage
    if used.count + newPages > packedPages + historyPages {
      // Bound sparse active pages too. Copy cached pixels into new immutable generations,
      // rather than re-rasterizing all glyphs or rewriting a texture read by the GPU.
      copied = addresses
      seen = []
      missing = characters.filter { seen.insert($0).inserted }
      addresses = [:]
      used = []
      cache = [:]
      order = []
    }
    var created: [Int: [Character]] = [:]
    for start in stride(from: 0, to: missing.count, by: slotsPerPage) {
      let page = nextPage
      nextPage += 1
      let keys = Array(missing[start..<min(start + slotsPerPage, missing.count)])
      created[page] = keys
      cache[page] = keys
      used.insert(page)
      for (slot, character) in keys.enumerated() {
        addresses[character] = Address(page: page, slot: slot)
      }
    }
    order = order.filter { !used.contains($0) } + used.sorted()
    let historical = order.filter { !used.contains($0) }
    let evicted = Set(historical.prefix(max(0, historical.count - historyPages)))
    for page in evicted { cache.removeValue(forKey: page) }
    order.removeAll { evicted.contains($0) }
    active = used
    return Frame(addresses: addresses, created: created, pages: used, copied: copied)
  }
  public var cachedPages: Set<Int> { Set(cache.keys) }
}
