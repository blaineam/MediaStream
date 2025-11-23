import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Filter options for media gallery
public enum MediaFilter: String, CaseIterable {
    case all = "All"
    case images = "Images"
    case videos = "Videos"
    case animated = "Animated"

    func matches(_ type: MediaType) -> Bool {
        switch self {
        case .all:
            return true
        case .images:
            return type == .image
        case .videos:
            return type == .video
        case .animated:
            return type == .animatedImage
        }
    }
}

/// Custom sort/filter configuration
public struct MediaGalleryFilterConfig {
    public var customFilter: ((any MediaItem) -> Bool)?
    public var customSort: ((any MediaItem, any MediaItem) -> Bool)?

    public init(
        customFilter: ((any MediaItem) -> Bool)? = nil,
        customSort: ((any MediaItem, any MediaItem) -> Bool)? = nil
    ) {
        self.customFilter = customFilter
        self.customSort = customSort
    }
}

/// Multi-select action configuration
public struct MediaGalleryMultiSelectAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let icon: String
    public let action: ([any MediaItem]) -> Void

    public init(title: String, icon: String, action: @escaping ([any MediaItem]) -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }
}

/// Grid view for browsing and selecting media
public struct MediaGalleryGridView: View {
    let mediaItems: [any MediaItem]
    let configuration: MediaGalleryConfiguration
    let filterConfig: MediaGalleryFilterConfig
    let multiSelectActions: [MediaGalleryMultiSelectAction]
    let includeBuiltInShareAction: Bool
    let initialScrollIndex: Int?
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    @State private var selectedFilter: MediaFilter = .all
    @State private var filteredItems: [any MediaItem] = []
    @State private var thumbnails: [UUID: PlatformImage] = [:]
    @State private var videoDurations: [UUID: TimeInterval] = [:]
    @State private var videoHasAudio: [UUID: Bool] = [:]
    @State private var isMultiSelectMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var contextMenuShareItem: Any?
    @State private var hasMultipleMediaTypes = false

    public init(
        mediaItems: [any MediaItem],
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        filterConfig: MediaGalleryFilterConfig = MediaGalleryFilterConfig(),
        multiSelectActions: [MediaGalleryMultiSelectAction] = [],
        includeBuiltInShareAction: Bool = true,
        initialScrollIndex: Int? = nil,
        onSelect: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mediaItems = mediaItems
        self.configuration = configuration
        self.filterConfig = filterConfig
        self.multiSelectActions = multiSelectActions
        self.includeBuiltInShareAction = includeBuiltInShareAction
        self.initialScrollIndex = initialScrollIndex
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    private var gridColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 16)] // 3 wide portrait, 4 wide landscape
        #else
        [GridItem(.adaptive(minimum: 200, maximum: 600), spacing: 16)] // Larger items on macOS
        #endif
    }

    public var body: some View {
        ZStack {
            // Main scrollable content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                            MediaThumbnailView(
                                mediaItem: item,
                                thumbnail: thumbnails[item.id],
                                videoDuration: videoDurations[item.id],
                                videoHasAudio: videoHasAudio[item.id],
                                isSelected: selectedItems.contains(item.id),
                                showSelection: isMultiSelectMode
                            )
                            .id(item.id)
                            .onTapGesture {
                                handleItemTap(item: item, index: index)
                            }
                            .contextMenu {
                                Button(action: {
                                    let originalIndex = mediaItems.firstIndex(where: { $0.id == item.id }) ?? index
                                    onSelect(originalIndex)
                                }) {
                                    Label("View", systemImage: "eye")
                                }

                                Button(action: {
                                    Task {
                                        await shareItem(item)
                                    }
                                }) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                // Add custom actions from configuration
                                if !configuration.customActions.isEmpty {
                                    Divider()
                                    ForEach(configuration.customActions) { action in
                                        Button(action: {
                                            let originalIndex = mediaItems.firstIndex(where: { $0.id == item.id }) ?? index
                                            action.action(originalIndex)
                                        }) {
                                            Label(action.icon, systemImage: action.icon)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    #if os(iOS)
                    .padding(.top, (!isMultiSelectMode && hasMultipleMediaTypes) ? 50 : 0) // Make room for filter bar only when shown
                    #else
                    .padding(.top, 46) // Extra padding on top to separate from select overlay on macOS
                    #endif
                    .padding(.bottom, (isMultiSelectMode && !selectedItems.isEmpty) ? 70 : 0) // Make room for toolbar
                }
                .onAppear {
                    scrollToInitialIndex(proxy: proxy)
                }
            }

            // Overlay glass UI elements
            VStack(spacing: 0) {
                #if os(iOS)
                // iOS: Show filter bar if multiple media types (no standalone close button - using toolbar Done button)
                if !isMultiSelectMode && hasMultipleMediaTypes {
                    filterBar
                }
                #else
                // macOS: Show filter bar if multiple media types, and multi-select controls
                HStack {
                    if !isMultiSelectMode && hasMultipleMediaTypes {
                        filterBar
                    } else if isMultiSelectMode {
                        multiSelectControlBar
                    }

                    // Select button on macOS to enter multi-select mode
                    if !isMultiSelectMode {
                        Spacer()
                        Button(action: {
                            isMultiSelectMode = true
                        }) {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .padding(.trailing, 16)
                        .padding(.vertical, hasMultipleMediaTypes ? 0 : 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                #endif

                Spacer()
                if isMultiSelectMode && !selectedItems.isEmpty {
                    multiSelectToolbar
                }
            }
        }
        #if os(iOS)
        .navigationTitle(isMultiSelectMode ? "\(selectedItems.count) Selected" : "Media Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isMultiSelectMode {
                    Button("Cancel") {
                        exitMultiSelectMode()
                    }
                } else {
                    Button(action: {
                        isMultiSelectMode = true
                    }) {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isMultiSelectMode {
                    HStack(spacing: 12) {
                        Button("Select All") {
                            selectAll()
                        }
                        .disabled(selectedItems.count == filteredItems.count)

                        Button("Clear") {
                            clearSelection()
                        }
                        .disabled(selectedItems.isEmpty)
                    }
                } else {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        #elseif os(macOS)
        .background(
            Group {
                if showShareSheet {
                    ShareSheetMac(items: shareItems, isPresented: $showShareSheet)
                }
            }
        )
        #endif
        .onAppear {
            checkMediaTypes()
            applyFilters()
            loadThumbnails()
        }
        .onChange(of: selectedFilter) { _, _ in
            applyFilters()
        }
    }

    private var multiSelectToolbar: some View {
        HStack(spacing: 16) {
            // Built-in share action (always first and orange)
            if includeBuiltInShareAction {
                Button(action: {
                    executeBuiltInShareAction()
                }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }

            // Custom action buttons - Share is orange, others gray
            ForEach(multiSelectActions) { action in
                if action.title == "Share" {
                    Button(action: {
                        executeMultiSelectAction(action)
                    }) {
                        Label(action.title, systemImage: action.icon)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: {
                        executeMultiSelectAction(action)
                    }) {
                        Label(action.title, systemImage: action.icon)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Scrollable filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaFilter.allCases, id: \.self) { filter in
                        FilterChip(
                            title: filter.rawValue,
                            isSelected: selectedFilter == filter
                        ) {
                            selectedFilter = filter
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.vertical, 8)
                .padding(.trailing, 16)
            }
        }
        .background(.ultraThinMaterial)
    }

    #if os(macOS)
    // macOS multi-select control bar (replaces NavigationStack toolbar)
    private var multiSelectControlBar: some View {
        HStack(spacing: 16) {
            Button("Cancel") {
                exitMultiSelectMode()
            }
            .buttonStyle(.bordered)

            Spacer()

            Text("\(selectedItems.count) Selected")
                .font(.headline)

            Spacer()

            HStack(spacing: 12) {
                Button("Select All") {
                    selectAll()
                }
                .buttonStyle(.bordered)
                .disabled(selectedItems.count == filteredItems.count)

                Button("Clear Selection") {
                    clearSelection()
                }
                .buttonStyle(.bordered)
                .disabled(selectedItems.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
    #endif

    private func handleItemTap(item: any MediaItem, index: Int) {
        if isMultiSelectMode {
            toggleSelection(for: item.id)
        } else {
            let originalIndex = mediaItems.firstIndex(where: { $0.id == item.id }) ?? index
            onSelect(originalIndex)
        }
    }

    private func toggleSelection(for itemId: UUID) {
        if selectedItems.contains(itemId) {
            selectedItems.remove(itemId)
        } else {
            selectedItems.insert(itemId)
        }
    }

    private func selectAll() {
        selectedItems = Set(filteredItems.map { $0.id })
    }

    private func clearSelection() {
        selectedItems.removeAll()
    }

    private func exitMultiSelectMode() {
        isMultiSelectMode = false
        selectedItems.removeAll()
    }

    private func shareSelected() {
        print("🔍 ShareSelected: Starting with \(selectedItems.count) selected items")
        Task {
            var items: [Any] = []
            for (index, itemId) in selectedItems.enumerated() {
                print("🔍 ShareSelected: Processing item \(index + 1)/\(selectedItems.count)")
                if let mediaItem = mediaItems.first(where: { $0.id == itemId }) {
                    print("🔍 ShareSelected: Found media item type: \(mediaItem.type)")

                    // Try getShareableItem() first to preserve original format
                    if let shareableItem = await mediaItem.getShareableItem() {
                        // Check if it's a file URL (original format)
                        if let url = shareableItem as? URL {
                            print("✅ ShareSelected: Got file URL: \(url.path) (.\(url.pathExtension))")
                            items.append(url)
                            continue
                        }

                        // If it's an image object, create temp file as fallback
                        #if os(iOS)
                        if let image = shareableItem as? UIImage {
                            print("📤 ShareSelected: Got UIImage, creating temp file")
                            if let tempURL = await createTemporaryImageFile(from: image, isAnimated: mediaItem.type == .animatedImage) {
                                items.append(tempURL)
                            }
                            continue
                        }
                        #else
                        if let image = shareableItem as? NSImage {
                            print("📤 ShareSelected: Got NSImage, creating temp file")
                            if let tempURL = await createTemporaryImageFile(from: image, isAnimated: mediaItem.type == .animatedImage) {
                                items.append(tempURL)
                            }
                            continue
                        }
                        #endif

                        // Unknown type, append as-is
                        print("📤 ShareSelected: Unknown type: \(type(of: shareableItem))")
                        items.append(shareableItem)
                    } else {
                        print("⚠️ ShareSelected: getShareableItem() returned nil")
                    }
                } else {
                    print("⚠️ ShareSelected: Could not find media item with id \(itemId)")
                }
            }
            await MainActor.run {
                print("📤 ShareSelected: Final items count: \(items.count)")
                shareItems = items
                showShareSheet = true
                print("📤 ShareSelected: Set showShareSheet = true")
            }
        }
    }

    private func executeMultiSelectAction(_ action: MediaGalleryMultiSelectAction) {
        let selectedMediaItems = mediaItems.filter { selectedItems.contains($0.id) }
        action.action(selectedMediaItems)
    }

    private func executeBuiltInShareAction() {
        shareSelected()
    }

    private func applyFilters() {
        var items = mediaItems.filter { item in
            selectedFilter.matches(item.type)
        }

        if let customFilter = filterConfig.customFilter {
            items = items.filter(customFilter)
        }

        if let customSort = filterConfig.customSort {
            items.sort(by: customSort)
        }

        filteredItems = items
    }

    private func shareItem(_ item: any MediaItem) async {
        print("🔍 ShareItem: Preparing item type: \(item.type)")

        // Try getShareableItem() first to preserve original format
        if let shareableItem = await item.getShareableItem() {
            // Check if it's a file URL (original format)
            if let url = shareableItem as? URL {
                print("✅ ShareItem: Got file URL: \(url.path) (.\(url.pathExtension))")
                await MainActor.run {
                    shareItems = [url]
                    showShareSheet = true
                }
                return
            }

            // If it's an image object, create temp file as fallback
            #if os(iOS)
            if let image = shareableItem as? UIImage {
                print("📤 ShareItem: Got UIImage, creating temp file")
                if let tempURL = await createTemporaryImageFile(from: image, isAnimated: item.type == .animatedImage) {
                    await MainActor.run {
                        shareItems = [tempURL]
                        showShareSheet = true
                    }
                }
                return
            }
            #else
            if let image = shareableItem as? NSImage {
                print("📤 ShareItem: Got NSImage, creating temp file")
                if let tempURL = await createTemporaryImageFile(from: image, isAnimated: item.type == .animatedImage) {
                    await MainActor.run {
                        shareItems = [tempURL]
                        showShareSheet = true
                    }
                }
                return
            }
            #endif

            // Unknown type, share as-is
            print("📤 ShareItem: Unknown type: \(type(of: shareableItem))")
            await MainActor.run {
                shareItems = [shareableItem]
                showShareSheet = true
            }
        } else {
            print("⚠️ ShareItem: getShareableItem() returned nil")
        }
    }

    private func createTemporaryImageFile(from image: PlatformImage, isAnimated: Bool) async -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(UUID().uuidString).png"
        let tempURL = tempDir.appendingPathComponent(filename)

        #if os(iOS)
        guard let data = image.pngData() else {
            print("⚠️ Failed to create PNG data from UIImage")
            return nil
        }
        #else
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let data = bitmapRep.representation(using: .png, properties: [:]) else {
            print("⚠️ Failed to create PNG data from NSImage")
            return nil
        }
        #endif

        do {
            try data.write(to: tempURL)
            print("✅ Created temporary image file: \(tempURL.path) (\(data.count) bytes)")
            return tempURL
        } catch {
            print("⚠️ Failed to write temporary image file: \(error)")
            return nil
        }
    }

    private func checkMediaTypes() {
        var types = Set<MediaType>()
        for item in mediaItems {
            types.insert(item.type)
            if types.count > 1 {
                hasMultipleMediaTypes = true
                return
            }
        }
        hasMultipleMediaTypes = false
    }

    private func loadThumbnails() {
        Task {
            for item in mediaItems {
                if let image = await item.loadImage() {
                    await MainActor.run {
                        thumbnails[item.id] = image
                    }
                }

                if item.type == .video {
                    if let duration = await item.getVideoDuration() {
                        await MainActor.run {
                            videoDurations[item.id] = duration
                        }
                    }

                    let hasAudio = await item.hasAudioTrack()
                    await MainActor.run {
                        videoHasAudio[item.id] = hasAudio
                    }
                }
            }
        }
    }

    private func scrollToInitialIndex(proxy: ScrollViewProxy) {
        guard let initialIndex = initialScrollIndex,
              initialIndex >= 0 && initialIndex < mediaItems.count else {
            return
        }

        let targetItem = mediaItems[initialIndex]
        print("📸 MediaGalleryGridView: Scrolling to initial index \(initialIndex) with item id \(targetItem.id)")

        // Delay slightly to allow LazyVGrid to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo(targetItem.id, anchor: .center)
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        #if canImport(UIKit)
                        .fill(isSelected ? Color.blue : Color(UIColor.tertiarySystemFill))
                        #elseif canImport(AppKit)
                        .fill(isSelected ? Color.blue : Color(NSColor.tertiaryLabelColor).opacity(0.2))
                        #endif
                )
        }
        .buttonStyle(.plain)
    }
}

struct MediaThumbnailView: View {
    let mediaItem: any MediaItem
    let thumbnail: PlatformImage?
    let videoDuration: TimeInterval?
    var videoHasAudio: Bool? = nil
    var isSelected: Bool = false
    var showSelection: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = thumbnail {
                        // Always use static Image for thumbnails (no animation in grid)
                        #if canImport(UIKit)
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                        #elseif canImport(AppKit)
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                        #endif
                    } else {
                        Color.gray.opacity(0.3)
                        ProgressView()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.width)
                .clipped()
                .cornerRadius(8)
                .overlay(
                    Group {
                        if showSelection {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                        }
                    }
                )
                .overlay(
                    Group {
                        if showSelection && isSelected {
                            ZStack {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 28, height: 28)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(6)
                        }
                    }
                )

                VStack(alignment: .leading, spacing: 4) {
                    if mediaItem.type == .video {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle.fill")
                                .font(.caption)
                            if let duration = videoDuration {
                                Text(formatDuration(duration))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                        }
                        .foregroundColor(.white)
                        .padding(6)
                        .background(.black.opacity(0.7))
                        .cornerRadius(6)

                        if let hasAudio = videoHasAudio {
                            HStack(spacing: 4) {
                                Image(systemName: hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .font(.caption2)
                                Text(hasAudio ? "Audio" : "Silent")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.white)
                            .padding(4)
                            .background(.black.opacity(0.7))
                            .cornerRadius(6)
                        }
                    } else if mediaItem.type == .animatedImage {
                        Image(systemName: "square.stack.3d.forward.dottedline.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(6)
                            .background(.black.opacity(0.7))
                            .cornerRadius(6)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview Support

#if DEBUG
#Preview("Comprehensive Gallery with Real Media") {
    @Previewable @State var selectedIndex: Int? = nil

    let mediaItems = PreviewSampleMedia.createComprehensiveTestMedia()

    ZStack {
        if selectedIndex == nil {
            // Show grid
            MediaGalleryGridView(
                mediaItems: mediaItems,
                configuration: MediaGalleryConfiguration(
                    slideshowDuration: 3.0,
                    showControls: true,
                    backgroundColor: .black
                ),
                onSelect: { index in
                    selectedIndex = index
                },
                onDismiss: {
                    // Dismissed completely
                }
            )
        } else {
            // Show slideshow
            MediaGalleryView(
                mediaItems: mediaItems,
                initialIndex: selectedIndex ?? 0,
                configuration: MediaGalleryConfiguration(
                    slideshowDuration: 3.0,
                    showControls: true,
                    backgroundColor: .black
                ),
                onDismiss: {
                    selectedIndex = nil
                },
                onBackToGrid: {
                    selectedIndex = nil
                }
            )
        }
    }
}

#Preview("Grid Only - Real Media") {
    MediaGalleryGridView(
        mediaItems: PreviewSampleMedia.createComprehensiveTestMedia(),
        configuration: MediaGalleryConfiguration(
            slideshowDuration: 3.0,
            showControls: true,
            backgroundColor: .black
        ),
        onSelect: { index in
            print("📸 Selected item at index: \(index)")
        },
        onDismiss: {
            print("❌ Grid dismissed")
        }
    )
}

#Preview("Grid with Multi-Select") {
    MediaGalleryGridView(
        mediaItems: PreviewSampleMedia.createComprehensiveTestMedia(),
        multiSelectActions: [
            MediaGalleryMultiSelectAction(
                title: "Export",
                icon: "square.and.arrow.up",
                action: { items in
                    print("Exporting \(items.count) items")
                }
            ),
            MediaGalleryMultiSelectAction(
                title: "Delete",
                icon: "trash",
                action: { items in
                    print("Deleting \(items.count) items")
                }
            )
        ],
        onSelect: { index in
            print("Selected item at index: \(index)")
        },
        onDismiss: {
            print("Grid dismissed")
        }
    )
}

/// Preview helper for generating sample media
fileprivate struct PreviewSampleMedia {
    static func createComprehensiveTestMedia() -> [any MediaItem] {
        var items: [any MediaItem] = []
        let testAssetsPath = "/tmp/MediaGalleryTestAssets"

        // Add real test media files if they exist
        let testFiles: [(String, MediaType)] = [
            ("test.jpg", .image),
            ("test.png", .image),
            ("sample.jpg", .image),
            ("test.heic", .image),
            ("test_animated.gif", .animatedImage),
            ("test_animated.png", .animatedImage),
            ("test_single.gif", .image),
            ("test_video.mp4", .video),
        ]

        print("📁 Looking for test media in: \(testAssetsPath)")

        for (filename, type) in testFiles {
            let url = URL(fileURLWithPath: "\(testAssetsPath)/\(filename)")
            if FileManager.default.fileExists(atPath: url.path) {
                print("✓ Found: \(filename)")
                if type == .video {
                    items.append(VideoMediaItem(
                        id: UUID(),
                        videoURLLoader: { url },
                        thumbnailLoader: {
                            // Generate thumbnail from video
                            let asset = AVAsset(url: url)
                            let imageGenerator = AVAssetImageGenerator(asset: asset)
                            imageGenerator.appliesPreferredTrackTransform = true

                            do {
                                let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                                #if canImport(UIKit)
                                return UIImage(cgImage: cgImage)
                                #elseif canImport(AppKit)
                                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                                #endif
                            } catch {
                                print("⚠️ Failed to generate thumbnail for \(filename): \(error)")
                                return nil
                            }
                        }
                    ))
                } else if type == .animatedImage {
                    items.append(AnimatedImageMediaItem(
                        id: UUID(),
                        imageLoader: {
                            #if canImport(UIKit)
                            return UIImage(contentsOfFile: url.path)
                            #elseif canImport(AppKit)
                            return NSImage(contentsOfFile: url.path)
                            #endif
                        },
                        durationLoader: {
                            await AnimatedImageHelper.getAnimatedImageDuration(from: url)
                        }
                    ))
                } else {
                    items.append(ImageMediaItem(
                        id: UUID(),
                        imageLoader: {
                            #if canImport(UIKit)
                            return UIImage(contentsOfFile: url.path)
                            #elseif canImport(AppKit)
                            return NSImage(contentsOfFile: url.path)
                            #endif
                        }
                    ))
                }
            } else {
                print("✗ Not found: \(filename)")
            }
        }

        let realMediaCount = items.count
        print("📊 Loaded \(realMediaCount) real test media files")

        // Fill to 50+ items with generated colored images
        let colors: [(Color, String)] = [
            (.red, "Red"),
            (.blue, "Blue"),
            (.green, "Green"),
            (.orange, "Orange"),
            (.purple, "Purple"),
            (.pink, "Pink"),
            (.yellow, "Yellow"),
            (.teal, "Teal"),
            (.indigo, "Indigo"),
            (.mint, "Mint"),
            (.cyan, "Cyan"),
            (.brown, "Brown")
        ]

        let targetCount = 50
        var colorIndex = 0
        while items.count < targetCount {
            let (color, _) = colors[colorIndex % colors.count]
            let itemNumber = items.count + 1

            let item = ImageMediaItem(
                id: UUID(),
                imageLoader: {
                    await MainActor.run {
                        PreviewSampleMedia.generateColorImage(color: color, text: "#\(itemNumber)")
                    }
                }
            )
            items.append(item)
            colorIndex += 1
        }

        print("🎨 Generated \(items.count - realMediaCount) colored placeholder images")
        print("✅ Total preview items: \(items.count)")

        return items
    }

    static func generateColorImage(color: Color, text: String) -> PlatformImage {
        let size = CGSize(width: 600, height: 600)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Fill background with color
            UIColor(color).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw text
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 100, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()

        // Fill background with color
        NSColor(color).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
        #endif
    }
}
#endif
