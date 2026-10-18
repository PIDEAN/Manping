import Foundation

struct ShaderPreset: Identifiable {
  let family: String
  let name: String
  let files: [String]
  var id: String { family + "/" + name }
  var unavailable: Bool {
    family == "ArtCNN" && name.contains("C4F32") && !ShaderCatalog.supportsWideBindings
  }

}
enum ShaderCatalog {
  static let supportsWideBindings: Bool = {
    let manifest: URL
    if let override = ProcessInfo.processInfo.environment["MANPING_MPV_LIBRARY"] {
      manifest = URL(fileURLWithPath: override).deletingLastPathComponent().appendingPathComponent(
        "MpvBuild.json")
    } else {
      manifest = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MpvBuild.json")
    }
    guard let data = try? Data(contentsOf: manifest),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return metadata["deduplicatedTextureCoordinates"] as? Bool == true
  }()
  static let families = ["Anime4K", "ArtCNN", "Ravu", "nnedi3"]
  static let presets: [ShaderPreset] = {
    var result: [ShaderPreset] = []
    for level in ["Low", "High"] {
      let scale = level == "Low" ? "M" : "VL"
      let finish = level == "Low" ? "S" : "M"
      let clamp = "Anime4K/Anime4K_Clamp_Highlights.glsl"
      let down = [
        "Anime4K/Anime4K_AutoDownscalePre_x2.glsl", "Anime4K/Anime4K_AutoDownscalePre_x4.glsl",
      ]
      func file(_ name: String, _ size: String) -> String {
        "Anime4K/Anime4K_" + name + "_" + size + ".glsl"
      }
      let restore = file("Restore_CNN", scale)
      let soft = file("Restore_CNN_Soft", scale)
      let up = file("Upscale_CNN_x2", scale)
      let denoise = file("Upscale_Denoise_CNN_x2", scale)
      let end = file("Upscale_CNN_x2", finish)
      let variants: [(String, [String])] = [
        ("A", [clamp, restore, up] + down + [end]), ("B", [clamp, soft, up] + down + [end]),
        ("C", [clamp, denoise] + down + [end]),
        ("AA", [clamp, restore, up, file("Restore_CNN", finish)] + down + [end]),
        ("BB", [clamp, soft, up] + down + [file("Restore_CNN_Soft", finish), end]),
        ("CA", [clamp, denoise] + down + [file("Restore_CNN", finish), end]),
      ]
      for (name, files) in variants {
        result.append(ShaderPreset(family: "Anime4K", name: level + name, files: files))
      }
    }
    for name in ["C4F16", "C4F16_DN", "C4F16_DS", "C4F32", "C4F32_DN", "C4F32_DS"] {
      result.append(
        ShaderPreset(family: "ArtCNN", name: name, files: ["ArtCNNCompat/ArtCNN_\(name).glsl"]))
    }
    result.append(
      ShaderPreset(
        family: "ArtCNN", name: "C4F32Ani4KI2", files: ["ArtCNNCompat/Ani4Kv2_ArtCNN_C4F32_i2.glsl"]
      ))
    result.append(
      ShaderPreset(
        family: "ArtCNN", name: "C4F32AniSDI4", files: ["ArtCNNCompat/AniSD_ArtCNN_C4F32_i4.glsl"]))
    for name in ["lite-ar-r2", "lite-ar-r3", "lite-ar-r4", "lite-r2", "lite-r3", "lite-r4"] {
      result.append(ShaderPreset(family: "Ravu", name: name, files: ["Ravu/ravu-\(name).hook"]))
    }
    for (name, nns) in [("Basic", 32), ("Plus", 64), ("Pro", 128), ("ProMax", 256)] {
      result.append(
        ShaderPreset(
          family: "nnedi3", name: name,
          files: ["nnedi3/nnedi3-nns\(nns)-win8x4.glsl", "igv/adaptive-sharpen_luma.glsl"]))
    }
    return result
  }()
  static func paths(_ selections: [String: String]) -> [String] {
    let root = Bundle.module.url(forResource: "Shaders", withExtension: nil)!
    var paths: [String] = []
    for family in families {
      guard let selected = selections[family],
        let preset = presets.first(where: { $0.family == family && $0.name == selected })
      else { continue }
      for file in preset.files {
        let path = root.appendingPathComponent(file).path
        if !paths.contains(path) { paths.append(path) }
      }
    }
    return paths
  }
}
