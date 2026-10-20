import Foundation

/// Synthetic article samples only; never used as a live-network fallback.
public enum M6ArticleFixture {
  public static func response(path: String, parameters: [String: String] = [:]) -> Data? {
    let payload: Any
    switch path {
    case "/x/article/categories":
      payload = [["id": 1, "name": "动画", "children": [["id": 11, "name": "动画资讯"], ["id": 12, "name": "作品评论"]]],
        ["id": 2, "name": "生活", "children": [["id": 21, "name": "日常记录"], ["id": 22, "name": "摄影游记"]]],
        ["id": 3, "name": "科技", "children": [["id": 31, "name": "数码"], ["id": 32, "name": "科普"]]]]
    case "/x/article/rank/categories": payload = [["id": 1, "name": "动画"], ["id": 2, "name": "生活"]]
    case "/x/article/rank/list": payload = (0..<5).map { article(id: 100 + $0, category: Int(parameters["cid"] ?? "1") ?? 1) }
    case "/x/article/recommends/plus", "/x/article/recommends":
      let page = Int(parameters["pn"] ?? "1") ?? 1
      let category = Int(parameters["cid"] ?? "0") ?? 0
      let values = page > 2 ? [] : (0..<(page == 1 ? 20 : 4)).map { article(id: (page - 1) * 20 + $0 + 100, category: category) }
      payload = path.hasSuffix("/plus") ? ["articles": values, "ranks": [article(id: 900, category: 1)]] as [String: Any] : values
    case "/x/article/viewinfo":
      payload = ["like": 0, "favorite": false, "attention": false, "coin": 0,
        "stats": ["view": 126_800, "like": 3200, "favorite": 860, "reply": 48, "coin": 120],
        "title": "读懂一段旅程", "mid": 700, "author_name": "山间记录者"]
    case "/read/native/", "/read/native":
      let id = Int(parameters["id"] ?? "100") ?? 100
      var read = article(id: id, category: 2)
      read["title"] = "读懂一段旅程：在日常中发现新的风景"
      read["tags"] = [["tid": 1, "name": "摄影"], ["tid": 2, "name": "旅行"]]
      read["content"] = #"<h2>从一条小路开始</h2><p>城市的节奏总让人忘记观察。<strong>慢下来</strong>，看看光线如何穿过树叶，也听听街角的声音。</p><p>这个周末，我带上一台旧相机，沿着家门口的小路走了一个下午。</p><figure><img data-src="https://fixture.invalid/cover/3" alt="午后的小路"></figure><h2>把片刻留在纸上</h2><p>无需走得很远，日常也能成为旅程。先记下一段声音，再画出它让你想起的颜色。</p><blockquote><p>记录不是为了留住一切，而是为了记得自己曾经认真看过。</p></blockquote><p><a href="https://www.bilibili.com/video/BV1fixture01">观看相关视频</a> · <a href="https://space.bilibili.com/701">作者空间</a> · <a href="https://www.bilibili.com/read/cv101">下一篇专栏</a></p><hr><p>谢谢阅读，欢迎在评论区分享你身边的风景。</p>"#
      let state: [String: Any] = ["readInfo": read, "dynamicId": "synthetic"]
      guard let json = try? JSONSerialization.data(withJSONObject: state), let text = String(data: json, encoding: .utf8) else { return nil }
      return Data("<!doctype html><html><body><script>window.__INITIAL_STATE__ = \(text);</script></body></html>".utf8)
    case "/x/article/like", "/x/article/favorites/add", "/x/article/favorites/del": payload = [:] as [String: String]
    default: return nil
    }
    return try? JSONSerialization.data(withJSONObject: ["code": 0, "data": payload])
  }
  private static func article(id: Int, category: Int) -> [String: Any] {
    let titles = ["读懂一段旅程：在日常中发现新的风景", "一帧动画背后的色彩与构图", "散步时，我遇见了这座城市", "那些值得记下来的普通时刻"]
    return ["id": id, "title": titles[id % titles.count],
      "summary": "从一个细节出发，慢慢理解画面和故事。这是一篇用于本地界面验证的合成专栏，没有真实账号或作者数据。",
      "origin_image_urls": ["https://fixture.invalid/cover/\(id % 8)"],
      "author": ["mid": 700, "name": "山间记录者", "face": "https://fixture.invalid/cover/1"],
      "publish_time": 1_700_000_000 + id * 60, "words": 1580,
      "category": ["id": category, "name": category == 1 ? "动画" : "生活"],
      "stats": ["view": 126_800 + id * 100, "like": 3200, "favorite": 860, "reply": 48, "coin": 120]]
  }
}
