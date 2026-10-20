import AppKit
import Combine
import ManpingCore
import CMpv
import OpenGL.GL3
import QuartzCore
import SwiftUI


struct PlayerSurface: NSViewRepresentable {
  let model: PlayerModel
  /// On a playback stage: the picture's width / height (see `VideoSurface.pictureAspect`).
  /// Changing it moves the video layer; the surface is never rebuilt.
  var pictureAspect: CGFloat? = nil
  func makeNSView(context: Context) -> VideoSurface {
    let view = VideoSurface(model: model)
    view.pictureAspect = pictureAspect
    return view
  }
  func updateNSView(_ view: VideoSurface, context: Context) {
    if view.pictureAspect != pictureAspect { view.pictureAspect = pictureAspect }
  }
  static func dismantleNSView(_ view: VideoSurface, coordinator: ()) {
    view.stopRendering()
  }
}
