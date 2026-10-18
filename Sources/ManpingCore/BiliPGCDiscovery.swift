import Foundation

extension BiliService {
  public func pgcTimeline(bangumi: Bool, expectedIdentity: AuthSnapshot) async throws -> [PGCTimelineDay] {
    let payload = try await appObject(.pgcTimeline, fields: ["type": bangumi ? "2" : "3", "filter_type": "0"], expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    guard let days = payload["data"] as? [[String: Any]], !days.isEmpty, days.count <= 366 else {
      throw BiliError.invalidResponse("Invalid PGC timeline")
    }
    return try days.map { day in
      guard let stamp = JSONValue.int64(day["date_ts"]), stamp > 0 else { throw BiliError.invalidResponse("Invalid PGC timeline date") }
      let episodes = day["episodes"] as? [[String: Any]] ?? []
      guard episodes.count <= 1000 else { throw BiliError.invalidResponse("PGC timeline is too large") }
      let seasons = try episodes.map { item -> PGCSeason in
        guard let id = JSONValue.int64(item["season_id"]), id > 0, let title = item["title"] as? String else {
          throw BiliError.invalidResponse("Invalid timeline season")
        }
        let published = JSONValue.int(item["published"]) == 1
        let index = (item["pub_index_show"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          ?? item["pub_index"] as? String
        let label = [item["pub_time"] as? String, index, published ? "已更新" : "待发布"]
          .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return PGCSeason(id: id, title: title, cover: JSONValue.url(item["cover"]), subtitle: label,
          episodeID: JSONValue.int64(item["episode_id"]).flatMap { $0 > 0 ? $0 : nil }, publishedAt: JSONValue.int64(item["pub_ts"]))
      }
      return PGCTimelineDay(timestamp: stamp, title: day["date"] as? String ?? "",
        isToday: Calendar.current.isDateInToday(Date(timeIntervalSince1970: Double(stamp))), seasons: seasons)
    }
  }
  public func pgcFilters(category: PGCCategory, expectedIdentity: AuthSnapshot) async throws -> [PGCFilter] {
    let payload = try await appObject(.pgcConditions, fields: category.fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    var filters: [PGCFilter] = []
    if let order = payload["order"] as? [[String: Any]], !order.isEmpty {
      let choices = try order.map { item -> PGCCondition in
        guard let id = item["field"] as? String, let title = item["name"] as? String else { throw BiliError.invalidResponse("Invalid PGC order") }
        return PGCCondition(id: id, title: title)
      }
      filters.append(PGCFilter(id: "order", title: "排序方式", choices: choices))
    }
    for item in payload["filter"] as? [[String: Any]] ?? [] {
      guard let field = item["field"] as? String, Self.pgcFilterField(field),
        let title = item["name"] as? String, let values = item["values"] as? [[String: Any]], !values.isEmpty else {
        throw BiliError.invalidResponse("Invalid PGC filter")
      }
      var known = Set<String>()
      let choices = try values.map { item -> PGCCondition in
        guard let keyword = item["keyword"] as? String, let title = item["name"] as? String else { throw BiliError.invalidResponse("Invalid PGC condition") }
        return PGCCondition(id: keyword, title: title)
      }.filter { known.insert($0.id).inserted }
      filters.append(PGCFilter(id: field, title: title, choices: choices))
    }
    guard !filters.isEmpty, filters.count <= 100, Set(filters.map(\.id)).count == filters.count else {
      throw BiliError.invalidResponse("Invalid PGC filter list")
    }
    return filters
  }
  public func pgcIndex(category: PGCCategory, filters: [PGCFilter], selection: [String: String],
                       page: Int = 1, expectedIdentity: AuthSnapshot) async throws -> PGCIndexPage {
    // The live endpoint returns an empty data object for page 0.
    guard (1...1_000_000).contains(page), selection.count <= filters.count else { throw BiliError.invalidResponse("Invalid PGC index page") }
    var fields = category.fields
    fields["pagesize"] = "30"; fields["page"] = String(page)
    for (key, value) in selection {
      guard Self.pgcFilterField(key), fields[key] == nil,
        let filter = filters.first(where: { $0.id == key }), filter.choices.contains(where: { $0.id == value }) else {
        throw BiliError.invalidResponse("Invalid PGC filter selection")
      }
      fields[key] = value
    }
    let payload = try await appObject(.pgcIndex, fields: fields, expectedIdentity: expectedIdentity)
    try checkRESTIdentity(expectedIdentity)
    guard let raw = payload["list"] as? [[String: Any]], raw.count <= 500 else { throw BiliError.invalidResponse("Invalid PGC index list") }
    var known = Set<Int64>()
    let seasons = try raw.map { item -> PGCSeason in
      guard let id = JSONValue.int64(item["season_id"]), id > 0, let title = item["title"] as? String else {
        throw BiliError.invalidResponse("Invalid index season")
      }
      let first = item["first_ep"] as? [String: Any] ?? [:]
      return PGCSeason(id: id, title: title, cover: JSONValue.url(item["cover"]),
        subtitle: item["subTitle"] as? String ?? item["index_show"] as? String ?? "",
        badge: item["badge"] as? String, episodeID: JSONValue.int64(first["ep_id"]).flatMap { $0 > 0 ? $0 : nil },
        score: (item["score"] as? String).flatMap(Double.init) ?? (item["score"] as? NSNumber)?.doubleValue)
    }.filter { known.insert($0.id).inserted }
    return PGCIndexPage(items: seasons, hasMore: JSONValue.int(payload["has_next"]) != 0, total: JSONValue.int(payload["total"]))
  }
  private static func pgcFilterField(_ field: String) -> Bool {
    guard field.range(of: "^[a-zA-Z0-9_]{1,64}$", options: .regularExpression) != nil else { return false }
    return !["access_key", "appkey", "sign", "ts", "build", "platform", "mobi_app", "csrf", "mid"].contains(field)
  }
}
