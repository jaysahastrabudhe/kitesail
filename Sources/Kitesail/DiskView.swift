import SwiftUI
import AppKit
import QuickLook

struct DiskView: View {
    @Bindable var model: DiskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.hasFullDiskAccess { fullDiskAccessBanner }
            breadcrumbs
            TreemapView(model: model)
                .frame(maxHeight: .infinity)
            if !model.basket.isEmpty { basketBar }
            legend
        }
        .padding(Metrics.page)
        .navigationTitle("Disk Map")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Home Folder") { model.setRoot(DiskModel.home) }
                    Button(bootVolumeName) { model.setRoot(URL(fileURLWithPath: "/")) }
                    Divider()
                    Button("Choose Folder…") { model.chooseFolder() }
                } label: {
                    Label("Location", systemImage: "folder")
                }
                .help("Choose what to map")
                Button { model.scan(force: true) } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan")
            }
        }
        .quickLookPreview($model.preview)
        .task {
            if model.items.isEmpty && !model.scanning { model.scan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.hasFullDiskAccess = DiskScanner.hasFullDiskAccess()
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
            presenting: model.pendingTrash
        ) { request in
            Button("Move “\(request.item.name)” to Trash", role: .destructive) { model.confirmTrash(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("\(formatBytes(request.item.size)) is freed when you empty the Trash. You can restore it from the Trash until then.")
        }
        .alert("Couldn’t delete", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private var subtitle: String {
        let place = model.current.path == "/" ? bootVolumeName : FileManager.default.displayName(atPath: model.current.path)
        if model.scanning { return "Measuring \(place)… \(formatBytes(model.scannedTotal)) so far" }
        var text = "\(place) · \(formatBytes(model.scannedTotal)) in \(model.items.count) items"
        if model.freedThisSession > 0 { text += " · freed \(formatBytes(model.freedThisSession))" }
        return text
    }

    @Local private var confirmBasket = false

    private var basketBar: some View {
        HStack(spacing: 12) {
            IconWell(symbol: "tray.full")
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete basket · \(plural(model.basket.count, "item")) · \(formatBytes(model.basketTotal))")
                    .font(.system(size: 13, weight: .medium))
                Text(model.basket.map(\.item.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Button("Clear") { withAnimation(.snappy) { model.basket = [] } }
            Button("Move All to Trash") { confirmBasket = true }.buttonStyle(.borderedProminent)
        }
        .panel(padding: 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog("Move \(plural(model.basket.count, "item")) to the Trash?", isPresented: $confirmBasket) {
            Button("Move \(formatBytes(model.basketTotal)) to Trash", role: .destructive) { model.trashBasket() }
        } message: {
            Text("You can restore them from the Trash until you empty it.")
        }
    }

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 12) {
            IconWell(symbol: "lock.shield", tint: Tone.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access to see everything").font(.system(size: 13, weight: .medium))
                Text("Without it, macOS hides Mail, Messages and Safari data from the map. Drag Kitesail into the list (or click +), switch it on, then reopen Kitesail.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Add Kitesail…") { DiskScanner.revealAppForFullDiskAccess() }
                .buttonStyle(.bordered)
        }
        .panel(padding: 12)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    let isLast = index == model.path.count - 1
                    Button(url.path == "/" ? bootVolumeName : FileManager.default.displayName(atPath: url.path)) {
                        withAnimation(.smooth) { model.pop(to: index) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(FileKind.allCases, id: \.self) { kind in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 8, height: 8)
                    Text(kind.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Hover a block: + adds it to the basket · right-click for Quick Look").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

struct TreemapView: View {
    @Bindable var model: DiskModel
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let blocks = model.blocks
            // Lay out in a rect grown by half a gap on every side so the outer blocks sit flush with the page edges.
            let rects = Treemap.layout(blocks.map { Double($0.size) },
                                       in: CGRect(origin: .zero, size: geo.size).insetBy(dx: -gap / 2, dy: -gap / 2))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(blocks, rects)), id: \.0.id) { item, rect in
                    BlockView(item: item, size: CGSize(width: max(0, rect.width - gap), height: max(0, rect.height - gap)),
                              share: Double(item.size) / Double(max(model.scannedTotal, 1)),
                              onOpen: { withAnimation(.smooth) { model.open(item) } },
                              inBasket: model.inBasket(item),
                              onTrash: { model.requestTrash(item, rect: rect.insetBy(dx: gap / 2, dy: gap / 2)) },
                              onBasket: { model.toggleBasket(item, rect: rect.insetBy(dx: gap / 2, dy: gap / 2)) },
                              onPreview: { model.preview = item.url })
                        .offset(x: rect.minX + gap / 2, y: rect.minY + gap / 2)
                        .transition(.scale(scale: 0.4, anchor: .center).combined(with: .opacity))
                }
                ForEach(model.shatters) { ShatterView(event: $0) }
                if blocks.isEmpty {
                    placeholder.frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.scanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Measuring…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing to show here").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

struct BlockView: View {
    let item: DiskItem
    let size: CGSize
    let share: Double
    let onOpen: () -> Void
    let inBasket: Bool
    let onTrash: () -> Void
    let onBasket: () -> Void
    let onPreview: () -> Void
    @Local private var hovering = false

    private var radius: CGFloat { min(8, min(size.width, size.height) / 4) }
    private var showsLabel: Bool { size.width > 74 && size.height > 42 }

    var body: some View {
        let color = item.kind.color
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [color.opacity(hovering ? 1 : 0.88), color.opacity(hovering ? 0.72 : 0.5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.55 : 0.14), lineWidth: hovering ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                if showsLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if item.isDirectory && !item.isOther {
                                Image(systemName: item.kind == .app ? "app.fill" : "folder.fill").font(.system(size: 10))
                            }
                            Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        Text(formatBytes(item.size)).font(.figure(size.height > 110 ? 17 : 11, weight: .medium))
                        if size.height > 110 {
                            Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.figure(11, weight: .regular)).opacity(0.7)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if (hovering || inBasket) && !item.isOther && size.width > 60 && size.height > 44 {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            Button(action: onBasket) {
                                Image(systemName: inBasket ? "checkmark" : "plus").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(inBasket ? .regular.tint(.white.opacity(0.35)).interactive() : .regular.interactive(), in: .circle)
                            .help(inBasket ? "Remove from basket" : "Add to delete basket")
                            if hovering && !inBasket {
                                Button(action: onTrash) {
                                    Image(systemName: "trash").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .help("Move to Trash now")
                            }
                        }
                    }
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                if inBasket {
                    shape.fill(.black.opacity(0.35))
                    shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
            .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
            .onTapGesture(count: 1) { if item.isDirectory { onOpen() } }
            .help("\(item.name) — \(formatBytes(item.size))")
            .contextMenu {
                if !item.isOther {
                    if item.isDirectory { Button("Open", action: onOpen) }
                    Button(inBasket ? "Remove from Basket" : "Add to Basket", action: onBasket)
                    Button("Quick Look", action: onPreview)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    Divider()
                    Button("Move to Trash", role: .destructive, action: onTrash)
                }
            }
    }
}

/// Brick-break: a split-second crack, then the bricks burst out and fall under gravity.
struct ShatterView: View {
    let event: ShatterEvent
    private let crack: Double = 0.12
    private let gravity: Double = 1500

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(event.start)
            Canvas { g, _ in
                let m = max(0, t - crack)
                for shard in event.shards {
                    var s = g
                    s.opacity = max(0, 1 - m / 1.05)
                    let x = shard.rect.midX + shard.velocity.dx * m
                    let y = shard.rect.midY + shard.velocity.dy * m + 0.5 * gravity * m * m
                    s.translateBy(x: x, y: y)
                    s.rotate(by: .radians(shard.spin * m))
                    let local = CGRect(x: -shard.rect.width / 2, y: -shard.rect.height / 2,
                                       width: shard.rect.width, height: shard.rect.height).insetBy(dx: 0.75, dy: 0.75)
                    let path = Path(roundedRect: local, cornerRadius: 2.5)
                    s.fill(path, with: .color(event.color))
                    if t < crack + 0.15 {
                        s.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
