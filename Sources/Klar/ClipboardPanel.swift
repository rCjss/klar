import AppKit
import SwiftUI

/// Schwebendes, nicht aktivierendes Panel – die aktive App behält den Fokus,
/// damit nach der Auswahl direkt dort eingefügt werden kann.
final class ClipboardPanel: NSPanel {
    private var monitor: Any?
    private let model = ClipboardPanelModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        host.wantsLayer = true
        contentView = host
        model.close = { [weak self] in self?.hide() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(tab: PanelTab = .history) {
        NSLog("Klar: Panel öffnen")
        model.reset()
        if tab != .history { model.switchTab(tab) }
        positionNearMouse()
        makeKeyAndOrderFront(nil)
        installMonitor()
    }

    func hide() {
        removeMonitor()
        orderOut(nil)
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let s = screen else { return }
        let f = s.visibleFrame
        let size = frame.size
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + 40)
        setFrameOrigin(origin)
    }

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            return self.model.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    override func resignKey() {
        super.resignKey()
        hide()
    }
}

enum PanelTab: String, CaseIterable { case history = "Verlauf", gifs = "GIFs" }

@MainActor final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" { didSet { clampSelection() } }
    @Published var selected = 0
    @Published var tab: PanelTab = .history
    @Published var gifQuery = "" { didSet { scheduleGifSearch() } }
    @Published var gifs: [GiphyGif] = []
    @Published var gifSelected = 0
    @Published var gifStatus: String?
    @Published var gifBusy = false
    var close: () -> Void = {}
    private var gifTask: Task<Void, Never>?
    private var gifLoadedQuery: String?
    let gifColumns = 3

    var items: [ClipItem] {
        ClipboardStore.shared.ordered.filter { $0.matches(query) }
    }

    func reset() {
        query = ""
        selected = 0
        gifSelected = 0
        tab = .history
    }

    func switchTab(_ t: PanelTab) {
        tab = t
        if t == .gifs, gifLoadedQuery != gifQuery { scheduleGifSearch(immediately: true) }
    }

    // MARK: GIFs

    private func scheduleGifSearch(immediately: Bool = false) {
        guard tab == .gifs else { return }
        gifTask?.cancel()
        let q = gifQuery
        gifTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled, let self else { return }
            await self.loadGifs(q)
        }
    }

    private func loadGifs(_ q: String) async {
        gifBusy = true
        gifStatus = nil
        defer { gifBusy = false }
        do {
            let result = try await GiphyClient.fetch(query: q)
            guard !Task.isCancelled else { return }
            gifs = result
            gifSelected = 0
            gifLoadedQuery = q
            if result.isEmpty { gifStatus = "Keine Treffer." }
        } catch {
            guard !Task.isCancelled else { return }
            gifs = []
            gifStatus = error.localizedDescription
        }
    }

    func pasteGif(_ gif: GiphyGif? = nil) {
        let list = gifs
        guard let gif = gif ?? (gifSelected < list.count ? list[gifSelected] : nil) else { return }
        gifBusy = true
        Task { [weak self] in
            defer { self?.gifBusy = false }
            do {
                let file = try await GiphyClient.download(gif)
                self?.close()
                Paster.writeGif(at: file)
                Paster.sendPasteKeystroke()
            } catch {
                self?.gifStatus = "GIF konnte nicht geladen werden."
            }
        }
    }

    private func clampSelection() {
        selected = min(max(0, selected), max(0, items.count - 1))
    }

    /// Gibt true zurück, wenn das Ereignis verbraucht wurde.
    func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        if event.keyCode == 48 { // tab
            switchTab(tab == .history ? .gifs : .history)
            return true
        }
        if tab == .gifs { return handleGifs(event, cmd: cmd) }
        switch event.keyCode {
        case 53: // esc
            close(); return true
        case 125: // down
            selected = min(selected + 1, max(0, items.count - 1)); return true
        case 126: // up
            selected = max(selected - 1, 0); return true
        case 36, 76: // return
            if cmd { copyOnly() } else { paste() }
            return true
        case 51: // backspace
            if cmd { delete(); return true }
            return false
        default:
            break
        }
        if cmd, let chars = event.charactersIgnoringModifiers {
            if chars == "p" { togglePin(); return true }
            if let n = Int(chars), n >= 1, n <= 9 {
                selected = n - 1
                paste()
                return true
            }
        }
        return false
    }

    private func handleGifs(_ event: NSEvent, cmd: Bool) -> Bool {
        let count = gifs.count
        switch event.keyCode {
        case 53: close(); return true
        case 123: gifSelected = max(gifSelected - 1, 0); return true                        // ←
        case 124: gifSelected = min(gifSelected + 1, max(0, count - 1)); return true        // →
        case 126: gifSelected = max(gifSelected - gifColumns, 0); return true               // ↑
        case 125: gifSelected = min(gifSelected + gifColumns, max(0, count - 1)); return true // ↓
        case 36, 76: pasteGif(); return true
        default: break
        }
        if cmd, let chars = event.charactersIgnoringModifiers, let n = Int(chars), n >= 1, n <= 9 {
            gifSelected = n - 1
            pasteGif()
            return true
        }
        return false
    }

    var current: ClipItem? {
        let list = items
        guard selected < list.count else { return nil }
        return list[selected]
    }

    func paste(_ item: ClipItem? = nil) {
        guard let item = item ?? current else { return }
        close()
        Paster.write(item)
        if !Paster.sendPasteKeystroke() {
            // Ohne Bedienungshilfen-Freigabe bleibt der Inhalt wenigstens in der Zwischenablage.
        }
    }

    func copyOnly() {
        guard let item = current else { return }
        Paster.write(item)
        close()
    }

    func togglePin(_ item: ClipItem? = nil) {
        guard let item = item ?? current else { return }
        ClipboardStore.shared.togglePin(item.id)
        objectWillChange.send()
    }

    func delete() {
        guard let item = current else { return }
        ClipboardStore.shared.remove(item.id)
        clampSelection()
        objectWillChange.send()
    }
}

@MainActor struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                TextField(model.tab == .gifs ? "GIFs suchen" : "Suchen",
                          text: model.tab == .gifs ? $model.gifQuery : $model.query)
                    .textFieldStyle(.plain)
                    .font(Theme.font(20, .light))
                    .foregroundColor(Theme.ink)
                    .focused($searchFocused)
                    .id(model.tab)
                ForEach(PanelTab.allCases, id: \.self) { t in
                    Text(t.rawValue)
                        .font(Theme.small)
                        .tracking(1)
                        .foregroundColor(model.tab == t ? Theme.ink : Theme.faint)
                        .contentShape(Rectangle())
                        .onTapGesture { model.switchTab(t) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 18)

            HairlineDivider().padding(.horizontal, 28)

            let items = model.items
            if model.tab == .gifs {
                gifGrid
            } else if items.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "Noch nichts kopiert." : "Keine Treffer.")
                    .font(Theme.body).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                PanelRow(item: item, index: index, selected: index == model.selected) {
                                    model.togglePin(item)
                                }
                                    .id(item.id)
                                    .onTapGesture { model.paste(item) }
                                    .onHover { if $0 { model.selected = index } }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .onChange(of: model.selected) { _, new in
                        if new < items.count { proxy.scrollTo(items[new].id, anchor: nil) }
                    }
                }
            }

            HairlineDivider().padding(.horizontal, 28)
            HStack(spacing: 22) {
                if model.tab == .gifs {
                    hint("↩", "Einfügen")
                    hint("↹", "Verlauf")
                    Spacer()
                    if model.gifBusy { Text("…").font(Theme.small).foregroundColor(Theme.faint) }
                    Text("\(model.gifs.count)").font(Theme.small).foregroundColor(Theme.faint)
                } else {
                    hint("↩", "Einfügen")
                    hint("⌘↩", "Kopieren")
                    hint("⌘P", "Anpinnen")
                    hint("⌘⌫", "Löschen")
                    hint("↹", "GIFs")
                    Spacer()
                    Text("\(items.count)").font(Theme.small).foregroundColor(Theme.faint)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 440)
        .background(Theme.paper)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { searchFocused = true }
    }

    private var gifGrid: some View {
        Group {
            if let status = model.gifStatus, model.gifs.isEmpty {
                Spacer()
                Text(status).font(Theme.body).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer()
            } else if model.gifs.isEmpty {
                Spacer()
                Text(model.gifBusy ? "…" : "Suchbegriff eingeben.").font(Theme.body).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: model.gifColumns)
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(Array(model.gifs.enumerated()), id: \.element.id) { index, gif in
                                GifThumb(url: gif.previewURL)
                                    .frame(height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Theme.ink, lineWidth: index == model.gifSelected ? 2 : 0))
                                    .id(gif.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.pasteGif(gif) }
                                    .onHover { if $0 { model.gifSelected = index } }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    }
                    .onChange(of: model.gifSelected) { _, new in
                        if new < model.gifs.count { proxy.scrollTo(model.gifs[new].id, anchor: nil) }
                    }
                }
            }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(Theme.small).foregroundColor(Theme.ink)
            Text(label).font(Theme.small).foregroundColor(Theme.muted)
        }
    }
}

@MainActor struct PanelRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    var onPin: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(index < 9 ? "\(index + 1)" : "")
                .font(Theme.small)
                .foregroundColor(selected ? Theme.paper.opacity(0.6) : Theme.faint)
                .frame(width: 14, alignment: .trailing)
            Button(action: onPin) {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(item.pinned
                                     ? (selected ? Theme.paper : Theme.ink)
                                     : (selected ? Theme.paper.opacity(0.35) : Theme.faint))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "Loslösen" : "Anpinnen")
            if item.kind == .image, let file = item.imageFile,
               let img = NSImage(contentsOf: Storage.images.appendingPathComponent(file)) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Spacer()
            } else {
                Text(item.preview)
                    .font(Theme.body)
                    .lineLimit(2)
                    .foregroundColor(selected ? Theme.paper : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(Format.relative(item.createdAt))
                .font(Theme.small)
                .foregroundColor(selected ? Theme.paper.opacity(0.6) : Theme.faint)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
        .background(selected ? Theme.ink : Color.clear)
        .contentShape(Rectangle())
    }
}
