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
    case audio = "Audio"
    case animated = "Animated"

    func matches(_ type: MediaType) -> Bool {
        switch self {
        case .all:
            return true
        case .images:
            return type == .image
        case .videos:
            return type == .video
        case .audio:
            return type == .audio
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

/// Combined grid + slideshow view that properly handles filter state
/// Use this instead of separate MediaGalleryGridView + MediaGalleryView for automatic filter preservation
public struct MediaGalleryFullView: View {
    let mediaItems: [any MediaItem]
    let configuration: MediaGalleryConfiguration
    let filterConfig: MediaGalleryFilterConfig
    let multiSelectActions: [MediaGalleryMultiSelectAction]
    let includeBuiltInShareAction: Bool
    let initialSlideshowIndex: Int?
    let onDismiss: () -> Void
    let onIndexChange: ((Int) -> Void)?

    @State private var showSlideshow = false
    @State private var slideshowItems: [any MediaItem] = []
    @State private var selectedIndex: Int = 0
    @State private var currentFilter: MediaFilter = .all
    @State private var lastViewedIndex: Int = 0
    @State private var hasInitializedSlideshow = false

    public init(
        mediaItems: [any MediaItem],
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        filterConfig: MediaGalleryFilterConfig = MediaGalleryFilterConfig(),
        multiSelectActions: [MediaGalleryMultiSelectAction] = [],
        includeBuiltInShareAction: Bool = true,
        initialSlideshowIndex: Int? = nil,
        onDismiss: @escaping () -> Void,
        onIndexChange: ((Int) -> Void)? = nil
    ) {
        self.mediaItems = mediaItems
        self.configuration = configuration
        self.filterConfig = filterConfig
        self.multiSelectActions = multiSelectActions
        self.includeBuiltInShareAction = includeBuiltInShareAction
        self.initialSlideshowIndex = initialSlideshowIndex
        self.onDismiss = onDismiss
        self.onIndexChange = onIndexChange
    }

    public var body: some View {
        ZStack {
            // Grid view - always present but hidden when slideshow is shown
            MediaGalleryGridView(
                mediaItems: mediaItems,
                configuration: configuration,
                filterConfig: filterConfig,
                multiSelectActions: multiSelectActions,
                includeBuiltInShareAction: includeBuiltInShareAction,
                initialScrollIndex: lastViewedIndex,
                initialFilter: currentFilter,
                onSelect: { _ in },
                onSelectWithFilteredItems: { filteredItems, index in
                    slideshowItems = filteredItems
                    selectedIndex = index
                    showSlideshow = true
                },
                onFilterChange: { filter in
                    currentFilter = filter
                },
                onDismiss: onDismiss
            )
            .opacity(showSlideshow ? 0 : 1)

            // Slideshow view - shown on top when active
            if showSlideshow {
                MediaGalleryView(
                    mediaItems: slideshowItems,  // Use filtered items!
                    initialIndex: selectedIndex,
                    configuration: configuration,
                    onDismiss: {
                        showSlideshow = false
                    },
                    onBackToGrid: {
                        showSlideshow = false
                    },
                    onIndexChange: { index in
                        lastViewedIndex = index
                        onIndexChange?(index)
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showSlideshow)
        .onAppear {
            // If initialSlideshowIndex is set, open directly to slideshow view
            if let index = initialSlideshowIndex, !hasInitializedSlideshow {
                hasInitializedSlideshow = true
                let clampedIndex = min(max(0, index), mediaItems.count - 1)
                slideshowItems = mediaItems
                selectedIndex = clampedIndex
                lastViewedIndex = clampedIndex
                showSlideshow = true
            }
        }
        #if os(iOS)
        .navigationBarHidden(showSlideshow)
        .toolbar(showSlideshow ? .hidden : .visible, for: .navigationBar)
        #endif
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
    let initialFilter: MediaFilter
    let onSelect: (Int) -> Void
    /// Callback with filtered items and index - use this when you need to respect filters in MediaGalleryView
    let onSelectWithFilteredItems: (([any MediaItem], Int) -> Void)?
    /// Callback when filter changes - use to preserve filter state across view recreations
    let onFilterChange: ((MediaFilter) -> Void)?
    let onDismiss: () -> Void

    @State private var selectedFilter: MediaFilter
    @State private var filteredItems: [any MediaItem] = []
    @State private var videoDurations: [UUID: TimeInterval] = [:]
    @State private var videoHasAudio: [UUID: Bool] = [:]
    @State private var isMultiSelectMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var contextMenuShareItem: Any?
    @State private var hasMultipleMediaTypes = false
    @State private var visibleItemIds: Set<UUID> = []
    @State private var loadingItemIds: Set<UUID> = []
    @State private var isRefreshing = false
    @State private var refreshID = UUID()  // Changes to force thumbnail reload

    /// Number of items to preload around visible area
    private let preloadBuffer = 6

    /// Backward-compatible init (without filter callback)
    public init(
        mediaItems: [any MediaItem],
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        filterConfig: MediaGalleryFilterConfig = MediaGalleryFilterConfig(),
        multiSelectActions: [MediaGalleryMultiSelectAction] = [],
        includeBuiltInShareAction: Bool = true,
        initialScrollIndex: Int? = nil,
        initialFilter: MediaFilter = .all,
        onSelect: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mediaItems = mediaItems
        self.configuration = configuration
        self.filterConfig = filterConfig
        self.multiSelectActions = multiSelectActions
        self.includeBuiltInShareAction = includeBuiltInShareAction
        self.initialScrollIndex = initialScrollIndex
        self.initialFilter = initialFilter
        self.onSelect = onSelect
        self.onSelectWithFilteredItems = nil
        self.onFilterChange = nil
        self.onDismiss = onDismiss
        _selectedFilter = State(initialValue: initialFilter)
    }

    /// New init with filter callback for respecting grid filters in MediaGalleryView
    public init(
        mediaItems: [any MediaItem],
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        filterConfig: MediaGalleryFilterConfig = MediaGalleryFilterConfig(),
        multiSelectActions: [MediaGalleryMultiSelectAction] = [],
        includeBuiltInShareAction: Bool = true,
        initialScrollIndex: Int? = nil,
        initialFilter: MediaFilter = .all,
        onSelect: @escaping (Int) -> Void,
        onSelectWithFilteredItems: @escaping ([any MediaItem], Int) -> Void,
        onFilterChange: ((MediaFilter) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.mediaItems = mediaItems
        self.configuration = configuration
        self.filterConfig = filterConfig
        self.multiSelectActions = multiSelectActions
        self.includeBuiltInShareAction = includeBuiltInShareAction
        self.initialScrollIndex = initialScrollIndex
        self.initialFilter = initialFilter
        self.onSelect = onSelect
        self.onSelectWithFilteredItems = onSelectWithFilteredItems
        self.onFilterChange = onFilterChange
        self.onDismiss = onDismiss
        _selectedFilter = State(initialValue: initialFilter)
    }

    private var gridColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 16)] // 3 wide portrait, 4 wide landscape
        #elseif os(tvOS)
        [GridItem(.adaptive(minimum: 300, maximum: 500), spacing: 32)] // Larger items on tvOS
        #else
        [GridItem(.adaptive(minimum: 200, maximum: 600), spacing: 16)] // Larger items on macOS
        #endif
    }

    public var body: some View {
        ZStack {
            // Main scrollable content
            ScrollViewReader { proxy in
                ScrollView {
                    gridContent
                        .padding(16)
                        #if os(iOS) || os(tvOS)
                        // Small top padding when filter bar is visible (safeAreaInset handles the main offset)
                        .padding(.top, (!isMultiSelectMode && hasMultipleMediaTypes) ? 8 : 0)
                        #else
                        .padding(.top, 46)
                        #endif
                        .padding(.bottom, (isMultiSelectMode && !selectedItems.isEmpty) ? 70 : 0)
                }
                .refreshable {
                    await refreshCacheAsync()
                }
                #if os(iOS)
                // Safe area inset to push content (and refresh indicator) below the filter bar overlay
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: (!isMultiSelectMode && hasMultipleMediaTypes) ? 44 : 0)
                }
                #endif
                .onAppear {
                    scrollToInitialIndex(proxy: proxy)
                }
            }

            // Overlay glass UI elements
            VStack(spacing: 0) {
                #if os(iOS) || os(tvOS)
                // iOS/tvOS: Fixed filter bar overlay
                if !isMultiSelectMode && hasMultipleMediaTypes {
                    filterBar
                }
                #elseif os(macOS)
                // macOS: Show filter bar if multiple media types, and multi-select controls
                // Uses filterBarContent (without glass) since outer HStack provides the glass bar
                HStack {
                    if !isMultiSelectMode && hasMultipleMediaTypes {
                        filterBarContent
                    } else if isMultiSelectMode {
                        multiSelectControlBar
                    }

                    // Select, refresh and download buttons on macOS
                    if !isMultiSelectMode {
                        Spacer()

                        HStack(spacing: 12) {
                            // Download button for local caching
                            MediaDownloadButton(
                                mediaItems: mediaItems,
                                headerProvider: { url in await MediaStreamConfiguration.headersAsync(for: url) }
                            )

                            // Refresh button to clear cache
                            Button(action: {
                                refreshCache()
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                isMultiSelectMode = true
                            }) {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.trailing, 16)
                        .padding(.vertical, hasMultipleMediaTypes ? 0 : 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .mediaStreamGlassBar()
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
                HStack(spacing: 12) {
                    if isMultiSelectMode {
                        Button("Select All") {
                            selectAll()
                        }
                        .disabled(selectedItems.count == filteredItems.count)

                        Button("Clear") {
                            clearSelection()
                        }
                        .disabled(selectedItems.isEmpty)
                    } else {
                        // Download button for local caching
                        MediaDownloadButton(
                            mediaItems: mediaItems,
                            headerProvider: { url in await MediaStreamConfiguration.headersAsync(for: url) }
                        )

                        Button("Done") {
                            onDismiss()
                        }
                    }
                }
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { showShareSheet && !shareItems.isEmpty },
            set: { showShareSheet = $0 }
        )) {
            ShareSheet(items: shareItems)
        }
        #elseif os(macOS)
        .background(
            Group {
                if showShareSheet && !shareItems.isEmpty {
                    ShareSheetMac(items: shareItems, isPresented: $showShareSheet)
                }
            }
        )
        #endif
        .onAppear {
            checkMediaTypes()
            applyFilters()
            // Thumbnails are now loaded lazily as items become visible
        }
        .onChange(of: selectedFilter) { _, newFilter in
            applyFilters()
            onFilterChange?(newFilter)
        }
        .onDisappear {
            // Clear visible items tracking when view disappears
            visibleItemIds.removeAll()
            loadingItemIds.removeAll()
        }
        .onChange(of: selectedFilter) { _, _ in
            applyFilters()
        }
    }

    private var multiSelectToolbar: some View {
        HStack(spacing: 16) {
            // Built-in share action
            if includeBuiltInShareAction {
                Button(action: {
                    executeBuiltInShareAction()
                }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }

            // Custom action buttons
            ForEach(multiSelectActions) { action in
                Button(action: {
                    executeMultiSelectAction(action)
                }) {
                    Label(action.title, systemImage: action.icon)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .mediaStreamGlassBar()
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Filter bar content - glass bar is applied by parent on macOS, directly on iOS
    private var filterBarContent: some View {
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
    }

    /// Filter bar with glass effect - use on iOS where it's standalone
    private var filterBar: some View {
        filterBarContent
            .mediaStreamGlassBar()
    }

    /// Grid content extracted for use in both iOS and macOS layouts
    private var gridContent: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                LazyThumbnailView(
                    mediaItem: item,
                    videoDuration: videoDurations[item.id],
                    videoHasAudio: videoHasAudio[item.id],
                    isSelected: selectedItems.contains(item.id),
                    showSelection: isMultiSelectMode,
                    onVisible: { itemId in
                        handleItemVisible(itemId: itemId, index: index)
                    },
                    onHidden: { itemId in
                        handleItemHidden(itemId: itemId)
                    },
                    onTypeResolved: { _ in
                        // webp/heic resolved to actual type after download;
                        // re-check media types and re-filter so badges and
                        // filter chips reflect the verified animation state.
                        checkMediaTypes()
                        applyFilters()
                    }
                )
                .id("\(item.id)-\(refreshID)")  // Combined ID forces recreation on refresh
                .onTapGesture {
                    handleItemTap(item: item, index: index)
                }
                .contextMenu {
                    Button(action: {
                        if let onSelectWithFilteredItems = onSelectWithFilteredItems {
                            onSelectWithFilteredItems(filteredItems, index)
                        } else {
                            let originalIndex = mediaItems.firstIndex(where: { $0.id == item.id }) ?? index
                            onSelect(originalIndex)
                        }
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
        .mediaStreamGlassBar()
    }
    #endif

    private func handleItemTap(item: any MediaItem, index: Int) {
        if isMultiSelectMode {
            toggleSelection(for: item.id)
        } else {
            // Call the filtered items callback if provided (preferred for respecting filters)
            if let onSelectWithFilteredItems = onSelectWithFilteredItems {
                onSelectWithFilteredItems(filteredItems, index)
            } else {
                // Fallback to original behavior - convert to original index
                let originalIndex = mediaItems.firstIndex(where: { $0.id == item.id }) ?? index
                onSelect(originalIndex)
            }
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
                        #if os(iOS) || os(tvOS)
                        if let image = shareableItem as? UIImage {
                            print("📤 ShareSelected: Got UIImage, creating temp file")
                            if let tempURL = await createTemporaryImageFile(from: image, isAnimated: mediaItem.type == .animatedImage) {
                                items.append(tempURL)
                            }
                            continue
                        }
                        #elseif os(macOS)
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

    /// Clear all caches and reload thumbnails (sync version for button)
    private func refreshCache() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Clear all caches
        MediaStreamCache.clearAll()

        // Clear local tracking
        videoDurations.removeAll()
        videoHasAudio.removeAll()

        // Generate new refresh ID to force all LazyThumbnailViews to recreate
        refreshID = UUID()

        // Brief delay to allow UI to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isRefreshing = false
        }
    }

    /// Clear all caches and reload thumbnails (async version for pull-to-refresh)
    private func refreshCacheAsync() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Clear all caches
        MediaStreamCache.clearAll()

        // Clear local tracking
        videoDurations.removeAll()
        videoHasAudio.removeAll()

        // Generate new refresh ID to force all LazyThumbnailViews to recreate
        refreshID = UUID()

        // Brief delay to allow UI to update and show the refresh indicator
        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
        isRefreshing = false
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
            #if os(iOS) || os(tvOS)
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
            #elseif os(macOS)
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

        #if os(iOS) || os(tvOS)
        guard let data = image.pngData() else {
            print("⚠️ Failed to create PNG data from UIImage")
            return nil
        }
        #elseif os(macOS)
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

    /// Handle an item becoming visible in the viewport
    private func handleItemVisible(itemId: UUID, index: Int) {
        visibleItemIds.insert(itemId)

        // Load video metadata if not cached
        if let item = mediaItems.first(where: { $0.id == itemId }), item.type == .video {
            if videoDurations[itemId] == nil {
                Task {
                    if let duration = await item.getVideoDuration() {
                        await MainActor.run {
                            videoDurations[itemId] = duration
                        }
                    }
                    let hasAudio = await item.hasAudioTrack()
                    await MainActor.run {
                        videoHasAudio[itemId] = hasAudio
                    }
                }
            }
        }
    }

    /// Handle an item becoming hidden (scrolled out of view)
    private func handleItemHidden(itemId: UUID) {
        visibleItemIds.remove(itemId)
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
                        #if os(tvOS)
                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.3))
                        #elseif canImport(UIKit)
                        .fill(isSelected ? Color.blue : Color(UIColor.tertiarySystemFill))
                        #elseif canImport(AppKit)
                        .fill(isSelected ? Color.blue : Color(NSColor.tertiaryLabelColor).opacity(0.2))
                        #endif
                )
        }
        .buttonStyle(.plain)
    }
}

/// Lazy-loading thumbnail view that only loads images when visible
struct LazyThumbnailView: View {
    let mediaItem: any MediaItem
    let videoDuration: TimeInterval?
    var videoHasAudio: Bool? = nil
    var isSelected: Bool = false
    var showSelection: Bool = false
    var onVisible: ((UUID) -> Void)? = nil
    var onHidden: ((UUID) -> Void)? = nil
    /// Called after thumbnail loads if the item's MediaType changed (e.g., webp/heic
    /// resolved from .image → .animatedImage). Use to trigger grid re-filter.
    var onTypeResolved: ((UUID) -> Void)? = nil

    @State private var thumbnail: PlatformImage?
    @State private var isLoading = false
    @State private var hasAppeared = false
    @State private var loadTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = thumbnail {
                        // Always use static Image for thumbnails (no animation in grid)
                        // Crop SBS thumbnails to left half, TB to top half for clarity
                        #if canImport(UIKit)
                        let image = Image(uiImage: thumbnail).resizable()
                        #elseif canImport(AppKit)
                        let image = Image(nsImage: thumbnail).resizable()
                        #endif
                        if mediaItem.vrProjection?.isSBS == true {
                            image.scaledToFill()
                                .frame(width: geometry.size.width * 2, height: geometry.size.width)
                                .frame(width: geometry.size.width, height: geometry.size.width, alignment: .leading)
                        } else if mediaItem.vrProjection?.isTB == true {
                            image.scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.width * 2)
                                .frame(width: geometry.size.width, height: geometry.size.width, alignment: .top)
                        } else {
                            image.scaledToFill()
                        }
                    } else if isLoading {
                        Color.gray.opacity(0.3)
                        ProgressView()
                    } else if mediaItem.type == .audio {
                        // Show music note placeholder for audio files without artwork
                        audioPlaceholderView
                    } else {
                        Color.gray.opacity(0.3)
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

                    // VR badge
                    if let vrProj = mediaItem.vrProjection {
                        Text(vrProj.displayName)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.8)))
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            onVisible?(mediaItem.id)
            loadThumbnailIfNeeded()
        }
        .onDisappear {
            onHidden?(mediaItem.id)
            // Cancel any in-flight thumbnail load — no point downloading/decoding
            // thumbnails for a gallery that has already been dismissed.
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func loadThumbnailIfNeeded() {
        // Skip disk cache for animated images to preserve animation data
        let isAnimated = mediaItem.type == .animatedImage
        let diskCacheKey = isAnimated ? nil : mediaItem.diskCacheKey

        // Check memory cache first, then disk cache (skip disk for animated)
        if let cached = ThumbnailCache.shared.get(mediaItem.id, diskCacheKey: diskCacheKey) {
            self.thumbnail = cached
            return
        }

        guard !isLoading else { return }
        isLoading = true

        let typeBeforeLoad = mediaItem.type

        loadTask = Task(priority: .utility) {
            // Use concurrency limiting to prevent too many simultaneous loads
            await ThumbnailLoadingQueue.shared.withLimit {
                // Bail out if gallery was dismissed while waiting in the queue.
                guard !Task.isCancelled else {
                    await MainActor.run { self.isLoading = false }
                    return
                }

                // Double-check cache after waiting in queue (memory and disk)
                if let cached = ThumbnailCache.shared.get(mediaItem.id, diskCacheKey: diskCacheKey) {
                    await MainActor.run {
                        self.thumbnail = cached
                        self.isLoading = false
                    }
                    return
                }

                // Use the optimized loadThumbnail method which can use ImageIO
                // for efficient downsampling without loading full image into memory
                var thumb = await mediaItem.loadThumbnail(targetSize: ThumbnailCache.thumbnailSize)

                // If no thumbnail loaded, use fallback placeholder for audio/video
                if thumb == nil {
                    switch mediaItem.type {
                    case .audio:
                        thumb = ThumbnailCache.createAudioPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
                    case .video:
                        thumb = ThumbnailCache.createVideoPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
                    default:
                        break
                    }
                }

                // Skip caching/display if cancelled during the load itself.
                guard !Task.isCancelled else {
                    await MainActor.run { self.isLoading = false }
                    return
                }

                if let thumb = thumb {
                    // Cache it (both memory and disk if key available, skip disk for animated)
                    ThumbnailCache.shared.set(mediaItem.id, image: thumb, diskCacheKey: diskCacheKey)

                    await MainActor.run {
                        self.thumbnail = thumb
                        self.isLoading = false
                        // If type changed (e.g., webp/heic resolved from .image → .animatedImage),
                        // notify the parent grid to re-check media types and re-filter.
                        if self.mediaItem.type != typeBeforeLoad {
                            self.onTypeResolved?(self.mediaItem.id)
                        }
                    }
                } else {
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Music note placeholder view for audio files without artwork
    private var audioPlaceholderView: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundColor(.gray)
        }
    }
}

/// Legacy thumbnail view for backwards compatibility
struct MediaThumbnailView: View {
    let mediaItem: any MediaItem
    let thumbnail: PlatformImage?
    let videoDuration: TimeInterval?
    var videoHasAudio: Bool? = nil
    var isSelected: Bool = false
    var showSelection: Bool = false

    var body: some View {
        LazyThumbnailView(
            mediaItem: mediaItem,
            videoDuration: videoDuration,
            videoHasAudio: videoHasAudio,
            isSelected: isSelected,
            showSelection: showSelection
        )
    }
}

// MARK: - Preview Support

#if DEBUG
import ImageIO

// MARK: - MediaGalleryFullView Preview (Use This!)
// This is the recommended preview - it shows the combined grid + slideshow view

#Preview("📸 MediaGalleryFullView") {
    @Previewable @State var isPresented = true

    NavigationStack {
        MediaGalleryFullView(
            mediaItems: PreviewSampleMedia.createComprehensiveTestMedia(),
            configuration: MediaGalleryConfiguration(
                slideshowDuration: 5.0,
                showControls: true,
                backgroundColor: .black
            ),
            onDismiss: {
                print("Gallery dismissed")
            }
        )
    }
}

#Preview("📸 MediaGalleryFullView - Local Files Only") {
    NavigationStack {
        MediaGalleryFullView(
            mediaItems: PreviewSampleMedia.createLocalTestMedia(),
            configuration: MediaGalleryConfiguration(
                slideshowDuration: 5.0,
                showControls: true
            ),
            onDismiss: {
                print("Gallery dismissed")
            }
        )
    }
}

#Preview("Comprehensive Gallery with Real Media") {
    @Previewable @State var selectedIndex: Int? = nil
    @Previewable @State var displayedItems: [any MediaItem] = []

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
                    // Fallback - not using filtered items
                    displayedItems = mediaItems
                    selectedIndex = index
                },
                onSelectWithFilteredItems: { filteredItems, index in
                    // Use filtered items for navigation
                    displayedItems = filteredItems
                    selectedIndex = index
                },
                onDismiss: {
                    // Dismissed completely
                }
            )
        } else {
            // Show slideshow with filtered items
            MediaGalleryView(
                mediaItems: displayedItems.isEmpty ? mediaItems : displayedItems,
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

        // Search paths for test media
        let searchPaths = [
            "/Users/Shared",
            "/tmp/MediaGalleryTestAssets",
            "/Volumes/unity/test",  // External drive test folder
            NSString(string: "~/Downloads").expandingTildeInPath,
            NSString(string: "~/Desktop").expandingTildeInPath
        ]

        // Add real test media files if they exist
        let testFiles: [(String, MediaType)] = [
            // WebM videos (VLC player)
            ("test.webm", .video),
            ("test_vp9.webm", .video),
            ("Big_Buck_Bunny_1080_10s_30MB.webm", .video),  // High-res WebM test
            ("Big_Buck_Bunny_1080_10s_30MB-2.webm", .video),
            // Standard videos
            ("test.mp4", .video),
            ("test_video.mp4", .video),
            ("test.mov", .video),
            // Images
            ("test.jpg", .image),
            ("test.png", .image),
            ("sample.jpg", .image),
            ("test.heic", .image),
            // Animated images
            ("test_animated.gif", .animatedImage),
            ("test_animated.png", .animatedImage),
            ("test.gif", .animatedImage),
            ("test_single.gif", .image),
        ]

        print("📁 Searching for test media in: \(searchPaths)")

        for searchPath in searchPaths {
            for (filename, type) in testFiles {
                let url = URL(fileURLWithPath: "\(searchPath)/\(filename)")
                if FileManager.default.fileExists(atPath: url.path) {
                    // Check if we already have this file
                    let alreadyAdded = items.contains { _ in
                        // Can't easily check, so skip duplicates by filename
                        false
                    }
                    guard !alreadyAdded else { continue }

                    print("✓ Found: \(filename) in \(searchPath)")
                    if type == .video {
                        let capturedURL = url
                        let capturedFilename = filename
                        items.append(VideoMediaItem(
                            id: UUID(),
                            videoURLLoader: { capturedURL },
                            thumbnailLoader: {
                                // Use WebView for WebM thumbnails, AVFoundation for others
                                if capturedFilename.hasSuffix(".webm") {
                                    print("🎬 Generating WebView thumbnail for: \(capturedFilename)")
                                    return await ThumbnailCache.createVideoThumbnailWithWebView(
                                        from: capturedURL,
                                        targetSize: ThumbnailCache.thumbnailSize,
                                        headers: nil
                                    )
                                } else {
                                    // Generate thumbnail from video using AVFoundation
                                    let asset = AVAsset(url: capturedURL)
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
                                        print("⚠️ Failed to generate thumbnail for \(capturedFilename): \(error)")
                                        return ThumbnailCache.createVideoPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
                                    }
                                }
                            }
                        ))
                    } else if type == .animatedImage {
                        let capturedURL = url
                        items.append(AnimatedImageMediaItem(
                            id: UUID(),
                            imageLoader: {
                                #if canImport(UIKit)
                                return UIImage(contentsOfFile: capturedURL.path)
                                #elseif canImport(AppKit)
                                return NSImage(contentsOfFile: capturedURL.path)
                                #endif
                            },
                            durationLoader: {
                                await AnimatedImageHelper.getAnimatedImageDuration(from: capturedURL)
                            }
                        ))
                    } else {
                        let capturedURL = url
                        items.append(ImageMediaItem(
                            id: UUID(),
                            imageLoader: {
                                #if canImport(UIKit)
                                return UIImage(contentsOfFile: capturedURL.path)
                                #elseif canImport(AppKit)
                                return NSImage(contentsOfFile: capturedURL.path)
                                #endif
                            }
                        ))
                    }
                }
            }
        }

        let localMediaCount = items.count
        print("📊 Loaded \(localMediaCount) local test media files")

        // Add networked test media items
        print("🌐 Adding networked test media items...")

        // Public test video - MP4 (Big Buck Bunny - Creative Commons)
        let networkVideoURL = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4")!
        items.insert(VideoMediaItem(
            id: UUID(),
            videoURLLoader: { networkVideoURL },
            thumbnailLoader: {
                print("🌐 Loading networked MP4 video thumbnail...")
                // Try to generate thumbnail using AVFoundation with network support
                let asset = AVURLAsset(url: networkVideoURL)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true

                do {
                    let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                    print("✅ Networked MP4 video thumbnail generated")
                    #if canImport(UIKit)
                    return UIImage(cgImage: cgImage)
                    #elseif canImport(AppKit)
                    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    #endif
                } catch {
                    print("⚠️ Failed to generate networked MP4 video thumbnail: \(error)")
                    return ThumbnailCache.createVideoPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
                }
            }
        ), at: 0)
        print("✓ Added networked MP4 video: Big Buck Bunny (360p)")

        // Public test video - WebM (Big Buck Bunny - Creative Commons)
        // Uses WebView for thumbnail generation since AVFoundation doesn't support WebM
        let networkWebmURL = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/webm/vp9/360/Big_Buck_Bunny_360_10s_1MB.webm")!
        items.insert(VideoMediaItem(
            id: UUID(),
            videoURLLoader: { networkWebmURL },
            thumbnailLoader: {
                print("🌐 Loading networked WebM video thumbnail via WebView...")
                let thumbnail = await ThumbnailCache.createVideoThumbnailWithWebView(
                    from: networkWebmURL,
                    targetSize: ThumbnailCache.thumbnailSize,
                    headers: nil
                )
                if thumbnail != nil {
                    print("✅ Networked WebM video thumbnail generated")
                } else {
                    print("⚠️ Failed to generate networked WebM video thumbnail")
                }
                return thumbnail ?? ThumbnailCache.createVideoPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
            }
        ), at: 1)
        print("✓ Added networked WebM video: Big Buck Bunny VP9 (360p)")

        // Public test image (placeholder image service)
        let networkImageURL = URL(string: "https://picsum.photos/800/600")!
        items.insert(ImageMediaItem(
            id: UUID(),
            imageLoader: {
                print("🌐 Loading networked image...")
                do {
                    let (data, _) = try await URLSession.shared.data(from: networkImageURL)
                    #if canImport(UIKit)
                    if let image = UIImage(data: data) {
                        print("✅ Networked image loaded")
                        return image
                    }
                    #elseif canImport(AppKit)
                    if let image = NSImage(data: data) {
                        print("✅ Networked image loaded")
                        return image
                    }
                    #endif
                } catch {
                    print("⚠️ Failed to load networked image: \(error)")
                }
                return nil
            }
        ), at: 2)
        print("✓ Added networked image: Random from picsum.photos")

        // Public animated GIFs from Giphy
        let animatedGIFURLs: [(URL, String)] = [
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExcDd2OWRyMnNhMzVkOWt0N2RjZnNhNjN3NnV3OXBwNHo2ZGtvbWhueSZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/3o7aCSPqXE5C6T8tBC/giphy.gif")!, "Stars Animation"),
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExYzRlMjM5NzY0MzdiYjhhZTgzMjJlMjBiOWE4OWRjMmM2YTk0OTYwNyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/l0HlBO7eyXzSZkJri/giphy.gif")!, "Wave Animation"),
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExNDhiMzYxMjU0ZjJkNjM5ZDE5NWY2ZWE3NTg1MTBiMzM5MjNlNDIwMyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/xT9IgzoKnwFNmISR8I/giphy.gif")!, "Loading Animation")
        ]

        for (index, (gifURL, name)) in animatedGIFURLs.enumerated() {
            let capturedURL = gifURL
            items.insert(AnimatedImageMediaItem(
                id: UUID(),
                imageLoader: {
                    print("🌐 Loading animated GIF: \(name)...")
                    do {
                        let (data, _) = try await URLSession.shared.data(from: capturedURL)
                        #if canImport(UIKit)
                        if let image = PreviewSampleMedia.animatedImageFromGIFData(data) {
                            print("✅ Animated GIF loaded: \(name)")
                            return image
                        }
                        #elseif canImport(AppKit)
                        if let image = NSImage(data: data) {
                            print("✅ Animated GIF loaded: \(name)")
                            return image
                        }
                        #endif
                    } catch {
                        print("⚠️ Failed to load animated GIF: \(error)")
                    }
                    return nil
                },
                durationLoader: {
                    return 2.0  // Approximate duration
                }
            ), at: 3 + index)
            print("✓ Added animated GIF: \(name)")
        }

        let realMediaCount = items.count
        print("📊 Total real media files (local + networked): \(realMediaCount)")

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

    /// Create local-only test media (no network requests)
    /// Uses colored placeholder images for consistent Xcode canvas previewing
    static func createLocalTestMedia() -> [any MediaItem] {
        var items: [any MediaItem] = []

        // Search for any real local files first
        let searchPaths = [
            "/Users/Shared",
            "/tmp/MediaGalleryTestAssets",
            NSString(string: "~/Downloads").expandingTildeInPath,
            NSString(string: "~/Desktop").expandingTildeInPath
        ]

        let testFiles: [(String, MediaType)] = [
            ("test.mp4", .video),
            ("test.mov", .video),
            ("test.jpg", .image),
            ("test.png", .image),
            ("test.gif", .animatedImage),
        ]

        for searchPath in searchPaths {
            for (filename, type) in testFiles {
                let url = URL(fileURLWithPath: "\(searchPath)/\(filename)")
                if FileManager.default.fileExists(atPath: url.path) {
                    let capturedURL = url
                    if type == .video {
                        items.append(VideoMediaItem(
                            id: UUID(),
                            videoURLLoader: { capturedURL },
                            thumbnailLoader: {
                                let asset = AVAsset(url: capturedURL)
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
                                    return ThumbnailCache.createVideoPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
                                }
                            }
                        ))
                    } else if type == .animatedImage {
                        items.append(AnimatedImageMediaItem(
                            id: UUID(),
                            imageLoader: {
                                #if canImport(UIKit)
                                return UIImage(contentsOfFile: capturedURL.path)
                                #elseif canImport(AppKit)
                                return NSImage(contentsOfFile: capturedURL.path)
                                #endif
                            },
                            durationLoader: {
                                await AnimatedImageHelper.getAnimatedImageDuration(from: capturedURL)
                            }
                        ))
                    } else {
                        items.append(ImageMediaItem(
                            id: UUID(),
                            imageLoader: {
                                #if canImport(UIKit)
                                return UIImage(contentsOfFile: capturedURL.path)
                                #elseif canImport(AppKit)
                                return NSImage(contentsOfFile: capturedURL.path)
                                #endif
                            }
                        ))
                    }
                }
            }
        }

        // Generate 30 colored placeholder images for consistent testing
        let colors: [(Color, String, MediaType)] = [
            (.red, "Red Image", .image),
            (.blue, "Blue Image", .image),
            (.green, "Green Image", .image),
            (.orange, "Orange Image", .image),
            (.purple, "Purple Image", .image),
            (.pink, "Pink GIF", .animatedImage),
            (.yellow, "Yellow Image", .image),
            (.teal, "Teal Image", .image),
            (.indigo, "Video", .video),
            (.mint, "Mint Image", .image),
            (.cyan, "Cyan GIF", .animatedImage),
            (.brown, "Brown Image", .image)
        ]

        var colorIndex = 0
        while items.count < 30 {
            let (color, _, type) = colors[colorIndex % colors.count]
            let itemNumber = items.count + 1

            if type == .video {
                items.append(VideoMediaItem(
                    id: UUID(),
                    videoURLLoader: { nil },  // No actual video
                    thumbnailLoader: {
                        await MainActor.run {
                            generateColorImage(color: color, text: "🎬\(itemNumber)")
                        }
                    }
                ))
            } else if type == .animatedImage {
                items.append(AnimatedImageMediaItem(
                    id: UUID(),
                    imageLoader: {
                        await MainActor.run {
                            generateColorImage(color: color, text: "✨\(itemNumber)")
                        }
                    },
                    durationLoader: { 2.0 }
                ))
            } else {
                items.append(ImageMediaItem(
                    id: UUID(),
                    imageLoader: {
                        await MainActor.run {
                            generateColorImage(color: color, text: "#\(itemNumber)")
                        }
                    }
                ))
            }
            colorIndex += 1
        }

        print("✅ Local test media: \(items.count) items")
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

    #if canImport(UIKit)
    /// Create an animated UIImage from GIF data
    static func animatedImageFromGIFData(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            return UIImage(data: data)
        }

        var images: [UIImage] = []
        var duration: TimeInterval = 0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(UIImage(cgImage: cgImage))

            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, delayTime > 0 {
                    duration += delayTime
                } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? Double {
                    duration += delayTime
                } else {
                    duration += 0.1
                }
            } else {
                duration += 0.1
            }
        }

        return UIImage.animatedImage(with: images, duration: duration)
    }
    #endif
}
#endif
