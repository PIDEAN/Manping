import ManpingCore
import SwiftUI

struct M8AITemplateSettingsView: View {
  @ObservedObject var store: AIPromptStore
  @Environment(\.colorScheme) private var scheme
  @State private var editing: AIPromptTask?
  @State private var draft = ""
  @State private var error: String?
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        SettingIcon(symbol: "waveform")
        VStack(alignment: .leading, spacing: 2) {
          Text("使用流式响应").font(Theme.Font.headline)
          Text("在生成过程中逐步显示响应内容。").font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
        }
        Spacer()
        Toggle("使用流式响应", isOn: $store.streaming).labelsHidden().toggleStyle(.switch).tint(Theme.accent).controlSize(.small)
      }.padding(.horizontal, 16).frame(minHeight: 60).cardSurface(scheme)
      VStack(spacing: 0) {
        Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
          HStack(spacing: 12) {
            SettingIcon(symbol: "text.bubble")
            VStack(alignment: .leading, spacing: 2) {
              Text("自定义提示词").font(Theme.Font.headline)
              Text("编辑视频和文章的总结、评价与问答模板。")
                .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
            }
            Spacer()
            DisclosureChevron(expanded: expanded)
          }.padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
        }.buttonStyle(.plain)
        if expanded { ForEach(AIPromptTask.allCases) { task in
          Hairline().padding(.leading, 16)
          HStack(spacing: 12) {
            Image(systemName: task.isQuestion ? "questionmark.bubble" : "sparkles").frame(width: 30).foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 2) {
              Text(task.title).font(Theme.Font.body)
              Text(task.placeholders.map { "{\($0)}" }.joined(separator: "、"))
                .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
            }
            Spacer()
            Button("编辑") { draft = store.template(for: task); error = nil; editing = task }
              .buttonStyle(AppButtonStyle(size: .small))
          }.padding(.horizontal, 16).frame(minHeight: 52)
        }
        }
      }.cardSurface(scheme)
    }.foregroundStyle(Theme.text(scheme))
      .sheet(item: $editing) { task in
        VStack(alignment: .leading, spacing: 16) {
          Text(task.title + "提示词模板").font(Theme.Font.section)
          Text("可用变量：" + task.placeholders.map { "{\($0)}" }.joined(separator: "、"))
            .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText(scheme))
          TextEditor(text: $draft).font(Theme.Font.body).scrollContentBackground(.hidden)
            .padding(8).background(Theme.fill(scheme), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.separator(scheme), lineWidth: 0.5))
          if let error { InlineErrorText(message: error) }
          HStack {
            Button("恢复原版模板") { draft = task.defaultTemplate }
              .foregroundStyle(Theme.accentText(scheme)).buttonStyle(AppButtonStyle(role: .plain))
            Spacer()
            Button("取消") { editing = nil }.buttonStyle(AppButtonStyle()).keyboardShortcut(.cancelAction)
            Button("保存") {
              do { try store.save(draft, for: task); editing = nil }
              catch { self.error = error.localizedDescription }
            }.buttonStyle(AppButtonStyle(role: .primary)).keyboardShortcut(.defaultAction)
          }
        }.padding(24).frame(width: 650, height: 600)
          .foregroundStyle(Theme.text(scheme))
      }
  }
}
