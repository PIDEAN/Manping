import ManpingCore

// The tested Core model owns account boundaries and operation lifetimes.
typealias VideoDetailInteractionModel = VideoInteractionModel

extension VideoInteractionModel {
  func like(aid: Int64, model: AppModel) async {
    await like(aid: aid) { model.showingLogin = true }
  }
  func follow(mid: Int64, aid: Int64, model: AppModel) async {
    await follow(mid: mid, aid: aid) { model.showingLogin = true }
  }
  func coin(aid: Int64, count: Int, alsoLike: Bool, model: AppModel) async {
    await coin(aid: aid, count: count, alsoLike: alsoLike) { model.showingLogin = true }
  }
  func triple(aid: Int64, model: AppModel) async {
    await triple(aid: aid) { model.showingLogin = true }
  }
  func loadFolders(aid: Int64, model: AppModel) async -> Bool {
    await loadFolders(aid: aid) { model.showingLogin = true }
  }
  func saveFolders(aid: Int64, model: AppModel) async -> Bool {
    await saveFolders(aid: aid) { model.showingLogin = true }
  }
}
