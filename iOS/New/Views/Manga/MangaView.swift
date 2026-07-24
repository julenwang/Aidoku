//
//  MangaView.swift
//  Aidoku
//
//  Created by Skitty on 8/14/23.
//

import AidokuRunner
import NukeUI
import SwiftUI

struct MangaView: View {
    @StateObject private var viewModel: ViewModel

    @State private var targetChapterKey: String?
    @State private var openAction: OpenAction?

    @State private var editMode = EditMode.inactive
    @State private var selectedChapters = Set<String>()
    
    @State private var gridColumns: [GridItem] = Self.getColumns()

    @State private var showingCoverView = false
    @State private var showRemoveAllConfirm = false
    @State private var showRemoveSelectedConfirm = false
    @State private var showConnectionAlert = false

    @State private var detailsLoaded = false
    @State private var descriptionExpanded = false

    @State private var loadingAlert: UIAlertController?

    @State private var openChapter: AidokuRunner.Chapter?

    @StateObject private var refreshController = RefreshController()

    private var path: NavigationCoordinator

    @Namespace private var transitionNamespace

    enum OpenAction: String {
        case read
        case readNext
        case readLatest
    }

    init(
        source: AidokuRunner.Source? = nil,
        manga: AidokuRunner.Manga,
        path: NavigationCoordinator,
        chapterKey: String? = nil,
        openAction: OpenAction? = nil
    ) {
        let source = source ?? SourceManager.shared.source(for: manga.sourceKey)
        self._viewModel = StateObject(wrappedValue: ViewModel(source: source, manga: manga))
        self.path = path
        self._targetChapterKey = State(initialValue: chapterKey)
        self._openAction = State(initialValue: openAction)
    }

    var body: some View {
        let list = ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    headerView

                    if let error = viewModel.error {
                        ErrorView(error: error) {
                            viewModel.error = nil
                            await viewModel.fetchData()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: UIDevice.current.userInterfaceIdiom == .pad ? 16 : 12) {
                            ForEach(viewModel.chapters.indices, id: \.self) { index in
                                let chapter = viewModel.chapters[index]
                                viewForChapter(chapter, index: index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        // hide the separator if there are no chapters, or all the chapters are filtered and the other section is shown
                        if !viewModel.chapters.isEmpty || (!(viewModel.manga.chapters?.isEmpty ?? true) && !viewModel.otherDownloadedChapters.isEmpty) {
                            bottomSeparator
                        }
                    }

                    if !viewModel.otherDownloadedChapters.isEmpty {
                        VStack {
                            HStack {
                                Text(NSLocalizedString("DOWNLOADED_CHAPTERS"))
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            ListDivider()
                        }

                        LazyVGrid(columns: gridColumns, spacing: UIDevice.current.userInterfaceIdiom == .pad ? 16 : 12) {
                            ForEach(viewModel.otherDownloadedChapters.indices, id: \.self) { index in
                                let chapter = viewModel.otherDownloadedChapters[index]
                                viewForChapter(chapter, index: index, secondSection: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        bottomSeparator
                    }
                }
            }
            .transition(.opacity)
            .refreshable {
                await viewModel.refresh()
            }
            .introspect(.scrollView, on: .iOS(.v15, .v16, .v17, .v18)) { list in
                refreshController.list = list
            }
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialogOrAlert(
                NSLocalizedString("REMOVE_ALL_DOWNLOADS"),
                isPresented: $showRemoveAllConfirm,
                actions: {
                    Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                    Button(NSLocalizedString("REMOVE"), role: .destructive) {
                        Task {
                            await DownloadManager.shared.deleteChapters(for: viewModel.manga.identifier)
                        }
                    }
                },
                message: {
                    Text(NSLocalizedString("REMOVE_ALL_DOWNLOADS_CONFIRM"))
                }
            )
            .confirmationDialogOrAlert(
                NSLocalizedString("REMOVE_DOWNLOADS"),
                isPresented: $showRemoveSelectedConfirm,
                actions: {
                    Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                    Button(NSLocalizedString("REMOVE"), role: .destructive) {
                        Task {
                            await DownloadManager.shared.delete(chapters: selectedChapters.map {
                                .init(
                                    sourceKey: viewModel.manga.sourceKey,
                                    mangaKey: viewModel.manga.key,
                                    chapterKey: $0
                                )
                            })
                            withAnimation {
                                editMode = .inactive
                            }
                        }
                    }
                },
                message: {
                    Text(NSLocalizedString("REMOVE_DOWNLOADS_CONFIRM"))
                }
            )
            .alert(
                NSLocalizedString("NO_WIFI_ALERT_TITLE"),
                isPresented: $showConnectionAlert,
                actions: {
                    Button(NSLocalizedString("OK"), role: .cancel) {}
                },
                message: {
                    Text(NSLocalizedString("NO_WIFI_ALERT_MESSAGE"))
                }
            )
            .scrollBackgroundHiddenPlease()
            .navigationBarBackButtonHidden(editMode == .active)
            .fullScreenCover(isPresented: $showingCoverView) {
                MangaCoverPageView(
                    source: viewModel.source,
                    manga: viewModel.manga
                )
            }
            .task {
                guard !detailsLoaded else { return }
                await viewModel.markUpdatesViewed()
                await viewModel.fetchDetails()

                if let openAction {
                    switch openAction {
                        case .read:
                            if let targetChapterKey, let chapter = viewModel.chapters.first(where: { $0.key == targetChapterKey }) {
                                openChapter = chapter
                            }
                        case .readNext:
                            if let nextChapter = viewModel.nextChapter {
                                openChapter = nextChapter
                            }
                        case .readLatest:
                            if let latestChapter = viewModel.chapters.first {
                                openChapter = latestChapter
                            }
                    }
                } else if let targetChapterKey {
                    withAnimation {
                        proxy.scrollTo(targetChapterKey, anchor: .center)
                    }
                }
                self.openAction = nil
                self.targetChapterKey = nil

                await viewModel.syncTrackerProgress()
                detailsLoaded = true
            }
            .onAppear {
                viewModel.refreshReadButtonState()
            }
            .onChange(of: editMode) { mode in
                guard let navigationController = path.rootViewController?.navigationController
                else { return }
                if mode == .active {
                    navigationController.setDismissGesturesEnabled(false)
                    UIView.animate(withDuration: 0.3) {
                        navigationController.isToolbarHidden = false
                        navigationController.toolbar.alpha = 1
                        if #available(iOS 26.0, *) {
                            navigationController.tabBarController?.isTabBarHidden = true
                        }
                    }
                } else {
                    navigationController.setDismissGesturesEnabled(true)
                    UIView.animate(withDuration: 0.3) {
                        navigationController.toolbar.alpha = 0
                        if #available(iOS 26.0, *) {
                            navigationController.tabBarController?.isTabBarHidden = false
                        }
                    } completion: { _ in
                        navigationController.isToolbarHidden = true
                    }
                }
            }
            .fullScreenCover(item: $openChapter) { chapter in
                SwiftUIReaderNavigationController(
                    source: viewModel.source,
                    manga: {
                        var mangaWithFilteredChapters = viewModel.manga
                        mangaWithFilteredChapters.chapters = if viewModel.chapterSortAscending {
                            viewModel.chapters.reversed()
                        } else {
                            viewModel.chapters
                        }
                        return mangaWithFilteredChapters
                    }(),
                    chapter: chapter
                )
                .ignoresSafeArea()
                .navigationTransitionZoom(sourceID: chapter, in: transitionNamespace)
            }
            .environment(\.editMode, $editMode)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // Delay slightly to ensure bounds are updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    gridColumns = Self.getColumns()
                }
            }
        }

        if #available(iOS 26.0, *) {
            list
                .toolbar {
                    toolbarContentiOS26
                }
        } else {
            list
                .toolbar {
                    toolbarContentBase

                    ToolbarItemGroup(placement: .bottomBar) {
                        if editMode == .active {
                            toolbar
                        }
                    }
                }
        }
    }

    static private func getColumns() -> [GridItem] {
        let layout = UserDefaults.standard.string(forKey: "Appearance.layout")
        let containerWidth = UIScreen.main.bounds.size.width - 32 // Approximate horizontal padding

        let itemsPerRow: Int
        switch layout {
            case "standard":
                let idealWidth: CGFloat = 180
                itemsPerRow = max(1, Int(floor(containerWidth / idealWidth)))
            case "compact":
                let idealWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 150 : 120
                itemsPerRow = max(1, Int(floor(containerWidth / idealWidth)))
            default: // custom
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                let orientation =
                    if #available(iOS 16.0, *) {
                        scene?.effectiveGeometry.interfaceOrientation
                    } else {
                        scene?.interfaceOrientation
                    }
                let isLandscape = orientation?.isLandscape ?? false
                let key = isLandscape ? "Appearance.customLandscapeRows" : "Appearance.customPortraitRows"
                itemsPerRow = UserDefaults.standard.integer(forKey: key)
        }

        let spacing: CGFloat = 12
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: itemsPerRow)
    }
}

extension MangaView {
    var headerView: some View {
        ZStack {
            MangaDetailsHeaderView(
                source: $viewModel.source,
                manga: $viewModel.manga,
                chapters: $viewModel.chapters,
                nextChapter: $viewModel.nextChapter,
                readingInProgress: $viewModel.readingInProgress,
                allChaptersLocked: $viewModel.allChaptersLocked,
                allChaptersRead: $viewModel.allChaptersRead,
                initialDataLoaded: $viewModel.initialDataLoaded,
                bookmarked: $viewModel.bookmarked,
                coverPressed: $showingCoverView,
                chapterSortOption: $viewModel.chapterSortOption,
                chapterSortAscending: $viewModel.chapterSortAscending,
                filters: $viewModel.chapterFilters,
                langFilter: $viewModel.chapterLangFilter,
                scanlatorFilter: $viewModel.chapterScanlatorFilter,
                descriptionExpanded: $descriptionExpanded,
                chapterTitleDisplayMode: $viewModel.chapterTitleDisplayMode,
                hasOtherDownloads: !viewModel.otherDownloadedChapters.isEmpty,
                onTrackerButtonPressed: {
                    let vc = TrackerModalViewController(manga: viewModel.manga)
                    vc.modalPresentationStyle = .overFullScreen
                    path.present(vc, animated: false)
                },
                onReadButtonPressed: {
                    if let nextChapter = viewModel.nextChapter {
                        openChapter = nextChapter
                    }
                }
            )
            .environmentObject(path)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var bottomSeparator: some View {
        VStack {
            Color.clear.frame(height: 28) // padding for bottom of list
        }
        .padding(.top, {
            // add a little spacing above on ios 15, since the separator ends up hidden
            if #available(iOS 16.0, *) { 0 } else { 0.5 }
        }())
    }

    @ViewBuilder
    func viewForChapter(_ chapter: AidokuRunner.Chapter, index: Int, secondSection: Bool = false) -> some View {
        let last = index == (secondSection ? viewModel.otherDownloadedChapters : viewModel.chapters).count - 1
        let downloadStatus = viewModel.downloadStatus[chapter.key, default: .none]
        let downloaded = downloadStatus == .finished
        let locked = chapter.locked && !downloaded
        let read = viewModel.readingHistory[chapter.key]?.page == -1
        let opacity: Double = if locked {
            0.5
        } else if read {
            0.4
        } else {
            1
        }

        ChapterCellView(
            source: viewModel.source,
            sourceKey: viewModel.manga.sourceKey,
            chapter: chapter,
            read: read,
            page: viewModel.readingHistory[chapter.key]?.page,
            downloadStatus: downloadStatus,
            downloadProgress: viewModel.downloadProgress[chapter.key],
            displayMode: viewModel.chapterTitleDisplayMode,
            isEditing: editMode == .active,
            isSelected: selectedChapters.contains(chapter.key)
        ) {
            if editMode == .inactive {
                openChapter = chapter
            } else {
                if selectedChapters.contains(chapter.key) {
                    selectedChapters.remove(chapter.key)
                } else {
                    selectedChapters.insert(chapter.key)
                }
            }
        } contextMenu: {
            contextMenu(
                chapter: chapter,
                downloadStatus: downloadStatus,
                index: index,
                last: last,
                secondSection: secondSection
            )
        }
        // use equatableview to determine when to refresh the view
        // improves the scrolling performance of the list
        .equatable()
        .disabled(locked)
        .opacity(opacity)
        .id(chapter.key)
        .tag(chapter.key, selectable: !locked)
        .matchedTransitionSourcePlease(id: chapter, in: transitionNamespace)
    }

    @ViewBuilder
    func contextMenu(
        chapter: AidokuRunner.Chapter,
        downloadStatus: DownloadStatus,
        index: Int,
        last: Bool,
        secondSection: Bool
    ) -> some View {
        let identifier = ChapterIdentifier(
            sourceKey: viewModel.manga.sourceKey,
            mangaKey: viewModel.manga.key,
            chapterKey: chapter.key
        )

        let hasDownloadButton = viewModel.source != nil && !viewModel.manga.isLocal() && downloadStatus != .finished && downloadStatus != .downloading
        let hasShareButton = downloadStatus == .finished || chapter.url != nil
        Section {
            let inControlGroup = hasDownloadButton && hasShareButton
            let buttons = Group {
                if hasDownloadButton {
                    Button {
                        let downloadOnlyOnWifi = UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi")
                        if
                            downloadOnlyOnWifi && Reachability.getConnectionType() == .wifi
                                || !downloadOnlyOnWifi
                        {
                            Task {
                                await DownloadManager.shared.download(
                                    manga: viewModel.manga,
                                    chapters: [chapter]
                                )
                            }
                        } else {
                            showConnectionAlert = true
                        }
                    } label: {
                        Label(
                            NSLocalizedString("DOWNLOAD"),
                            systemImage: inControlGroup ? "arrow.down.circle.fill" : "arrow.down.circle"
                        )
                    }
                }
                if hasShareButton {
                    Button {
                        showShareSheet(chapter: chapter)
                    } label: {
                        Label(
                            NSLocalizedString("SHARE"),
                            systemImage: inControlGroup ? "square.and.arrow.up.fill" : "square.and.arrow.up"
                        )
                    }
                }
            }
            if inControlGroup {
                ControlGroup {
                    buttons
                }
            } else {
                buttons
            }
        }

        Section {
            if viewModel.readingHistory[chapter.key]?.page != nil {
                Button {
                    Task {
                        await viewModel.markUnread(chapters: [chapter])
                    }
                } label: {
                    Label(NSLocalizedString("MARK_UNREAD"), systemImage: "minus.circle")
                }
            }
            if viewModel.readingHistory[chapter.key]?.page != -1 {
                Button {
                    Task {
                        await viewModel.markRead(chapters: [chapter])
                    }
                } label: {
                    Label(NSLocalizedString("MARK_READ"), systemImage: "checkmark.circle")
                }
            }
            if !last && !secondSection {
                Menu(NSLocalizedString("MARK_PREVIOUS")) {
                    Button {
                        let chapters = [AidokuRunner.Chapter](viewModel.chapters[
                            index + 1..<viewModel.chapters.count
                        ])
                        Task {
                            await viewModel.markRead(chapters: chapters)
                        }
                    } label: {
                        Label(NSLocalizedString("READ"), systemImage: "checkmark.circle")
                    }
                    Button {
                        let chapters = [AidokuRunner.Chapter](viewModel.chapters[
                            index + 1..<viewModel.chapters.count
                        ])
                        Task {
                            await viewModel.markUnread(chapters: chapters)
                        }
                    } label: {
                        Label(NSLocalizedString("UNREAD"), systemImage: "minus.circle")
                    }
                }
            }
        }

        Section {
            if viewModel.manga.isLocal() {
                // if the chapter is from the local source, add a button to remove it instead of download
                Button(role: .destructive) {
                    Task {
                        await LocalFileManager.shared.removeChapter(
                            mangaId: viewModel.manga.key,
                            chapterId: chapter.key
                        )
                        if let index = viewModel.chapters.firstIndex(of: chapter) {
                            withAnimation {
                                _ = viewModel.chapters.remove(at: index)
                            }
                        }
                    }
                } label: {
                    Label(NSLocalizedString("REMOVE"), systemImage: "trash")
                }
            } else {
                if downloadStatus == .finished {
                    Button(role: .destructive) {
                        Task {
                            await DownloadManager.shared.delete(chapters: [identifier])
                        }
                    } label: {
                        Label(NSLocalizedString("REMOVE_DOWNLOAD"), systemImage: "trash")
                    }
                } else if downloadStatus == .downloading {
                    Button {
                        Task {
                            await DownloadManager.shared.cancelDownload(for: identifier)
                        }
                    } label: {
                        Label(NSLocalizedString("CANCEL_DOWNLOAD"), systemImage: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    var rightNavbarButton: some View {
        RightNavbarButton(
            viewModel: viewModel,
            refreshController: refreshController,
            markAllRead: {
                // only show loading indicator for a larger number of chapters
                if viewModel.chapters.count > 100 {
                    showLoadingIndicator()
                }
                Task {
                    await viewModel.markRead(chapters: viewModel.chapters)
                    hideLoadingIndicator()
                }
            },
            markAllUnread: {
                if viewModel.chapters.count > 100 {
                    showLoadingIndicator()
                }
                Task {
                    await viewModel.markUnread(chapters: viewModel.chapters)
                    hideLoadingIndicator()
                }
            },
            editCategories: {
                path.present(
                    UINavigationController(
                        rootViewController: CategorySelectViewController(
                            manga: viewModel.manga
                        )
                    )
                )
            },
            migrate: {
                let migrateView = MigrateSelectDestinationView(
                    selectedSeries: [viewModel.manga],
                    selectedSources: viewModel.source.flatMap { [$0.toInfo()] } ?? []
                )
                let viewController = SwiftUINavigationViewController(rootView: migrateView)
                path.present(viewController)
            },
            showShareSheet: showShareSheet(item:),
            removeDownloads: {
                showRemoveAllConfirm = true
            },
            editMode: $editMode
        ).equatable()
    }
}

extension MangaView {
    @ToolbarContentBuilder
    var toolbarContentBase: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            rightNavbarButton
        }

        ToolbarItem(placement: .topBarLeading) {
            if editMode == .active {
                let allSelected = selectedChapters.count == viewModel.chapters.count
                Button {
                    if allSelected {
                        selectedChapters = Set()
                    } else {
                        selectedChapters = Set(viewModel.chapters.map { $0.key })
                    }
                } label: {
                    if allSelected {
                        Text(NSLocalizedString("DESELECT_ALL"))
                    } else {
                        Text(NSLocalizedString("SELECT_ALL"))
                    }
                }
                .disabled(viewModel.chapters.isEmpty)
            }
        }
    }

    @available(iOS 26.0, *)
    @ToolbarContentBuilder
    var toolbarContentiOS26: some ToolbarContent {
        toolbarContentBase

        if editMode == .active {
            ToolbarItem(placement: .bottomBar) {
                toolbarMarkMenu
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            if !viewModel.manga.isLocal() {
                ToolbarItem(placement: .bottomBar) {
                    toolbarDownloadButton
                }
            }
        }
    }

    var toolbar: some View {
        HStack {
            toolbarMarkMenu

            Spacer()

            toolbarDownloadButton
        }
    }

    var toolbarMarkMenu: some View {
        Menu(NSLocalizedString("MARK")) {
            let title = if selectedChapters.count == 1 {
                NSLocalizedString("1_CHAPTER")
            } else {
                String(format: NSLocalizedString("%i_CHAPTERS"), selectedChapters.count)
            }
            Section(title) {
                Button {
                    let markChapters = selectedChapters.compactMap { id in
                        viewModel.chapters.first(where: { $0.key == id })
                    }
                    Task {
                        await viewModel.markUnread(chapters: markChapters)
                    }
                    withAnimation {
                        editMode = .inactive
                    }
                } label: {
                    Label(NSLocalizedString("UNREAD"), systemImage: "minus.circle")
                }
                Button {
                    let markChapters = selectedChapters.compactMap { id in
                        viewModel.chapters.first(where: { $0.key == id })
                    }
                    Task {
                        await viewModel.markRead(chapters: markChapters)
                    }
                    withAnimation {
                        editMode = .inactive
                    }
                } label: {
                    Label(NSLocalizedString("READ"), systemImage: "checkmark.circle")
                }
            }
        }
        .disabled(selectedChapters.isEmpty)
    }

    @ViewBuilder
    var toolbarDownloadButton: some View {
        let allChaptersQueued = !selectedChapters.contains(where: {
            viewModel.downloadStatus[$0] != .queued
        })
        let allChaptersDownloaded = !selectedChapters.contains(where: {
            viewModel.downloadStatus[$0] != .finished
        })
        if !selectedChapters.isEmpty && allChaptersQueued {
            Button(NSLocalizedString("CANCEL")) {
                Task { [selectedChapters] in
                    await DownloadManager.shared.cancelDownloads(for: selectedChapters.map {
                        .init(
                            sourceKey: viewModel.manga.sourceKey,
                            mangaKey: viewModel.manga.key,
                            chapterKey: $0
                        )
                    })
                }
                withAnimation {
                    editMode = .inactive
                }
            }
        } else if !selectedChapters.isEmpty && allChaptersDownloaded {
            Button(NSLocalizedString("REMOVE")) {
                showRemoveSelectedConfirm = true
            }
        } else {
            Button(NSLocalizedString("DOWNLOAD")) {
                let downloadChapters = (viewModel.manga.chapters ?? viewModel.chapters)
                    .filter { chapter in
                        let isSelected = selectedChapters.contains(chapter.key)
                        guard isSelected else { return false }
                        let isDownloaded = viewModel.downloadStatus[chapter.key] == .finished
                        let isDownloading = viewModel.downloadStatus[chapter.key] == .downloading
                        let isQueued = viewModel.downloadStatus[chapter.key] == .queued
                        guard !isDownloaded, !isDownloading, !isQueued else { return false }
                        return true
                    }
                    .reversed()

                let downloadOnlyOnWifi = UserDefaults.standard.bool(forKey: "Library.downloadOnlyOnWifi")
                if
                    downloadOnlyOnWifi && Reachability.getConnectionType() == .wifi
                        || !downloadOnlyOnWifi
                {
                    Task {
                        await DownloadManager.shared.download(
                            manga: viewModel.manga,
                            chapters: Array(downloadChapters)
                        )
                    }
                } else {
                    showConnectionAlert = true
                }
                withAnimation {
                    editMode = .inactive
                }
            }
            .disabled(viewModel.source == nil || viewModel.manga.isLocal() || selectedChapters.isEmpty)
        }
    }
}

extension MangaView {
    func showShareSheet(chapter: AidokuRunner.Chapter) {
        if viewModel.downloadStatus[chapter.key] == .finished {
            Task {
                let identifier = ChapterIdentifier(
                    sourceKey: viewModel.manga.sourceKey,
                    mangaKey: viewModel.manga.key,
                    chapterKey: chapter.key
                )
                if let url = await DownloadManager.shared.getCompressedFile(for: identifier) {
                    showShareSheet(item: url)
                }
            }
        } else if let url = chapter.url {
            showShareSheet(item: url)
        }
    }

    func showShareSheet(item: Any) {
        let activityViewController = UIActivityViewController(
            activityItems: [item],
            applicationActivities: nil
        )
        guard let sourceView = path.rootViewController?.view else { return }
        activityViewController.popoverPresentationController?.sourceView = sourceView
        // manually positioned in top right of screen, near the right navigation bar button
        activityViewController.popoverPresentationController?.sourceRect = CGRect(
            x: UIScreen.main.bounds.width - 30,
            y: 60,
            width: 0,
            height: 0
        )
        path.present(activityViewController)
    }

    func showLoadingIndicator() {
        (UIApplication.shared.delegate as? AppDelegate)?.showLoadingIndicator()
    }

    func hideLoadingIndicator() {
        Task {
            await (UIApplication.shared.delegate as? AppDelegate)?.hideLoadingIndicator()
        }
    }
}

private struct ChapterCellView<T: View>: View, Equatable {
    let source: AidokuRunner.Source?
    let sourceKey: String
    let chapter: AidokuRunner.Chapter
    let read: Bool
    let page: Int?
    let downloadStatus: DownloadStatus
    let downloadProgress: Float?
    let displayMode: ChapterTitleDisplayMode
    let isEditing: Bool
    let isSelected: Bool

    var onPressed: (() -> Void)?
    var contextMenu: (() -> T)?

    private var locked: Bool {
        chapter.locked && !(downloadStatus == .finished)
    }

    var body: some View {
        let title = {
            if let t = chapter.title, !t.isEmpty {
                return t
            }
            return chapter.formattedTitle(forceMode: displayMode)
        }()
        
        let view = Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .aspectRatio(2/3, contentMode: .fill)
            .background {
                if let thumbnail = chapter.thumbnail {
                    SourceImageView(
                        source: source,
                        imageUrl: thumbnail,
                        downsampleWidth: 400
                    )
                }
            }
            .overlay(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.7),
                        .init(color: Color.black.opacity(0.7), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Text(title)
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8),
                alignment: .bottomLeading
            )
            .overlay(
                VStack {
                    HStack {
                        Spacer()
                        if locked {
                            Image(systemName: "lock.fill").imageScale(.small).padding(6).background(Color.black.opacity(0.6)).clipShape(Circle()).padding(4).foregroundStyle(.white)
                        } else if downloadStatus == .finished {
                            Image(systemName: "arrow.down.circle.fill").imageScale(.small).padding(6).background(Color.black.opacity(0.6)).clipShape(Circle()).padding(4).foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(UIColor.quaternarySystemFill), lineWidth: 1)
            )

        let finalView = ZStack {
            view
            if isEditing {
                Color.black.opacity(0.4).clipShape(RoundedRectangle(cornerRadius: 5))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
            }
        }

        Button {
            onPressed?()
        } label: {
            finalView
        }
        .tint(.primary)
        .contextMenu {
            if !locked {
                contextMenu?()
            }
        }
    }

    static nonisolated func == (lhs: ChapterCellView<T>, rhs: ChapterCellView<T>) -> Bool {
        lhs.chapter == rhs.chapter
            && lhs.read == rhs.read
            && lhs.page == rhs.page
            && lhs.downloadStatus == rhs.downloadStatus
            && lhs.downloadProgress == rhs.downloadProgress
            && lhs.displayMode == rhs.displayMode
            && lhs.isEditing == rhs.isEditing
            && lhs.isSelected == rhs.isSelected
    }
}

private struct RightNavbarButton: View, Equatable {
    private let bookmarked: Bool
    private let hasCategories: Bool
    private let url: URL?
    private let hasDownloads: Bool
    private let isEditing: Bool
    private let refresh: () async -> Void

    let markAllRead: () -> Void
    let markAllUnread: () -> Void
    let editCategories: () -> Void
    let migrate: () -> Void
    let showShareSheet: (URL) -> Void
    let removeDownloads: () -> Void

    @Binding var editMode: EditMode

    init(
        viewModel: MangaView.ViewModel,
        refreshController: RefreshController,
        markAllRead: @escaping () -> Void,
        markAllUnread: @escaping () -> Void,
        editCategories: @escaping () -> Void,
        migrate: @escaping () -> Void,
        showShareSheet: @escaping (URL) -> Void,
        removeDownloads: @escaping () -> Void,
        editMode: Binding<EditMode>
    ) {
        self.bookmarked = viewModel.bookmarked
        self.hasCategories = !CoreDataManager.shared.getCategoryTitles(sorted: false).isEmpty
        self.url = viewModel.manga.url
        self.hasDownloads = viewModel.downloadStatus.contains(where: { $0.value == .finished })
        self.refresh = refreshController.refresh

        self.markAllRead = markAllRead
        self.markAllUnread = markAllUnread
        self.editCategories = editCategories
        self.migrate = migrate
        self.showShareSheet = showShareSheet
        self.removeDownloads = removeDownloads

        self.isEditing = editMode.wrappedValue == .active
        self._editMode = editMode
    }

    var body: some View {
        if editMode == .inactive {
            Menu {
                if let url {
                    Section {
                        Button {
                            showShareSheet(url)
                        } label: {
                            Label(NSLocalizedString("SHARE"), systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section {
                    Menu(NSLocalizedString("MARK_ALL")) {
                        Button {
                            markAllRead()
                        } label: {
                            Label(NSLocalizedString("READ"), systemImage: "checkmark.circle")
                        }
                        Button {
                            markAllUnread()
                        } label: {
                            Label(NSLocalizedString("UNREAD"), systemImage: "minus.circle")
                        }
                    }
                    Button {
                        withAnimation {
                            editMode = .active
                        }
                    } label: {
                        Label(NSLocalizedString("SELECT_CHAPTERS"), systemImage: "checkmark.circle")
                    }
                    if bookmarked {
                        if hasCategories {
                            Button {
                                editCategories()
                            } label: {
                                Label(NSLocalizedString("EDIT_CATEGORIES"), systemImage: "folder.badge.gearshape")
                            }
                        }
                        Button {
                            migrate()
                        } label: {
                            Label(NSLocalizedString("MIGRATE"), systemImage: "arrow.left.arrow.right")
                        }
                        if #available(iOS 18.0, *) { // only for system versions supporting swipe down to dismiss
                            Button {
                                Task {
                                    await refresh()
                                }
                            } label: {
                                Label(NSLocalizedString("REFRESH_DETAILS"), systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }

                if hasDownloads {
                    Section {
                        Button(role: .destructive) {
                            removeDownloads()
                        } label: {
                            Label(
                                NSLocalizedString("REMOVE_ALL_DOWNLOADS"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            } label: {
                MoreIcon()
            }
        } else {
            DoneButton {
                withAnimation {
                    editMode = .inactive
                }
            }
        }

    }

    static nonisolated func == (lhs: RightNavbarButton, rhs: RightNavbarButton) -> Bool {
        lhs.bookmarked == rhs.bookmarked
            && lhs.hasCategories == rhs.hasCategories
            && lhs.url == rhs.url
            && lhs.hasDownloads == rhs.hasDownloads
            && lhs.isEditing == rhs.isEditing
    }
}

// hack for programmatically starting the refresh control from swiftui
@MainActor
private class RefreshController: ObservableObject {
    weak var list: UIScrollView?

    func refresh() {
        guard let list, let refreshControl = list.refreshControl else { return }
        if #available(iOS 17.4, *) {
            list.stopScrollingAndZooming() // fixes not scrolling down after refresh finishes
        }
        list.setContentOffset(CGPoint(x: 0, y: -list.safeAreaInsets.top - refreshControl.frame.height), animated: true)
        refreshControl.beginRefreshing()
        refreshControl.sendActions(for: .valueChanged)
    }
}
