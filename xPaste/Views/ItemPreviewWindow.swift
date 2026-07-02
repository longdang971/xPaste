import SwiftUI
import AppKit
import WebKit

struct PreviewPopoverContent: View {
    let item: ClipboardItem
    var onClose: () -> Void

    @State private var loadedImage: NSImage?

    private var title: String {
        switch item.type {
        case .url:   return "Link"
        case .image: return "Image"
        case .file:  return "File"
        case .text:  return "Text"
        }
    }

    private var itemURL: URL? {
        guard item.type == .url, let text = item.text else { return nil }
        return URL(string: text)
    }

    private var previewWidth: CGFloat { item.type == .url ? 560 : 420 }
    private var previewHeight: CGFloat { item.type == .url ? 440 : 340 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: previewWidth, height: previewHeight)
        .task(id: item.id) { await loadImageIfNeeded() }
        .background {
            Button("") { onClose() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            shareControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var shareControl: some View {
        if let url = itemURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13))
            }
            .buttonStyle(.plain)
        } else if item.type == .text, let text = item.text {
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .url:
            if let url = itemURL { WebPreview(url: url) } else { textContent }
        case .image:
            imageContent
        case .text:
            textContent
        case .file:
            fileContent
        }
    }

    private var textContent: some View {
        ScrollView {
            Text(item.displayText)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var imageContent: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable().interpolation(.high).scaledToFit().padding(12)
            } else {
                ProgressView()
            }
        }
    }

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.fileURLs ?? [], id: \.self) { url in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 26, height: 26)
                    Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch item.type {
            case .text:
                Text(textStats).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            case .url:
                if let url = itemURL {
                    Text(url.absoluteString)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open in \(browserName(for: url))") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            case .image:
                if let loadedImage {
                    Text("\(Int(loadedImage.size.width)) × \(Int(loadedImage.size.height))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            case .file:
                Text("\((item.fileURLs ?? []).count) file(s)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var textStats: String {
        let text = item.displayText
        let chars = text.count
        let words = text.split { $0 == " " || $0.isNewline }.filter { !$0.isEmpty }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return "\(chars) characters · \(words) words · \(lines) lines"
    }

    private func browserName(for url: URL) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Browser" }
        return FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func loadImageIfNeeded() async {
        guard item.type == .image, loadedImage == nil else { return }
        if let data = item.imageData, let img = NSImage(data: data) {
            loadedImage = img
        } else {
            loadedImage = await ClipboardStore.shared.loadImage(for: item.id)
        }
    }
}

private struct WebPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
