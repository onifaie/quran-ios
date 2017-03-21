//
//  QuranViewController.swift
//  Quran
//
//  Created by Mohamed Afifi on 4/28/16.
//  Copyright © 2016 Quran.com. All rights reserved.
//

import UIKit
import KVOController

class QuranViewController: UIViewController, AudioBannerViewPresenterDelegate,
                        QuranDataSourceDelegate, QuranViewDelegate, QuranNavigationBarDelegate {

    private let bookmarksManager: BookmarksManager
    private let quranNavigationBar: QuranNavigationBar

    private let dataRetriever: AnyDataRetriever<[QuranPage]>
    private let audioViewPresenter: AudioBannerViewPresenter
    private let qarisControllerCreator: AnyCreator<QariTableViewController, ([Qari], Int, UIView?)>
    private let translationsSelectionControllerCreator: AnyCreator<UIViewController, Void>
    private let simplePersistence: SimplePersistence
    private var lastPageUpdater: LastPageUpdater!

    private let dataSource: QuranDataSource

    private let scrollToPageToken = Once()
    private let didLayoutSubviewToken = Once()
    private let interactiveGestureToken = Once()

    private var titleView: QuranPageTitleView? { return navigationItem.titleView as? QuranPageTitleView }

    private var quranView: QuranView! {
        return view as? QuranView
    }

    private var barsTimer: Timer?

    private var interactivePopGestureOldEnabled: Bool?
    private var barsHiddenTimerExecuted = false

    private var statusBarHidden = false {
        didSet {
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    private var initialPage: Int = 0 {
        didSet {
            title = Quran.nameForSura(Quran.PageSuraStart[initialPage - 1])
            titleView?.setPageNumber(initialPage, navigationBar: navigationController?.navigationBar)
        }
    }

    private var isTranslationView: Bool {
        set { simplePersistence.setValue(newValue, forKey: .showQuranTranslationView) }
        get { return simplePersistence.valueForKey(.showQuranTranslationView) }
    }

    var isBookmarked: Bool {
        return bookmarksManager.isBookmarked
    }

    override var prefersStatusBarHidden: Bool {
        return statusBarHidden || traitCollection.containsTraits(in: UITraitCollection(verticalSizeClass: .compact))
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .slide
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    init(imageService: AnyCacheableService<Int, UIImage>, // swiftlint:disable:this function_parameter_count
         dataRetriever: AnyDataRetriever<[QuranPage]>,
         ayahInfoRetriever: AyahInfoRetriever,
         audioViewPresenter: AudioBannerViewPresenter,
         qarisControllerCreator: AnyCreator<QariTableViewController, ([Qari], Int, UIView?)>,
         translationsSelectionControllerCreator: AnyCreator<UIViewController, Void>,
         bookmarksPersistence: BookmarksPersistence,
         lastPagesPersistence: LastPagesPersistence,
         simplePersistence: SimplePersistence,
         page: Int,
         lastPage: LastPage?) {
        self.initialPage                            = page
        self.dataRetriever                          = dataRetriever
        self.lastPageUpdater                        = LastPageUpdater(persistence: lastPagesPersistence)
        self.bookmarksManager                       = BookmarksManager(bookmarksPersistence: bookmarksPersistence)
        self.simplePersistence                      = simplePersistence
        self.audioViewPresenter                     = audioViewPresenter
        self.qarisControllerCreator                 = qarisControllerCreator
        self.translationsSelectionControllerCreator = translationsSelectionControllerCreator
        self.quranNavigationBar                     = QuranNavigationBar(simplePersistence: simplePersistence)

        let imagesDataSource = QuranImagesDataSource(
            reuseIdentifier: QuranPageCollectionViewCell.reuseId,
            imageService: imageService,
            ayahInfoRetriever: ayahInfoRetriever,
            bookmarkPersistence: bookmarksPersistence)

        let translationsDataSource = QuranTranslationsDataSource(
            reuseIdentifier: QuranTranslationPageCollectionViewCell.reuseId,
            imageService: imageService,
            ayahInfoRetriever: ayahInfoRetriever,
            bookmarkPersistence: bookmarksPersistence)

        dataSource = QuranDataSource( dataSourceRepresentables: [imagesDataSource.asQuranBasicDataSourceRepresentable(),
                                                                 translationsDataSource.asQuranBasicDataSourceRepresentable()])

        super.init(nibName: nil, bundle: nil)

        updateTranslationView()

        self.lastPageUpdater.configure(initialPage: page, lastPage: lastPage)

        audioViewPresenter.delegate = self
        imagesDataSource.delegate = self

        automaticallyAdjustsScrollViewInsets = false

        // page behavior
        let pageBehavior = ScrollViewPageBehavior()
        dataSource.scrollViewDelegate = pageBehavior
        kvoController.observe(pageBehavior, keyPath: "currentPage", options: .new) { [weak self] (_, _, _) in
            self?.onPageChanged()
        }
    }

    required init?(coder aDecoder: NSCoder) {
        unimplemented()
    }

    override func loadView() {
        view = QuranView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        quranView.delegate = self
        quranNavigationBar.delegate = self

        configureAudioView()
        quranView.collectionView.ds_useDataSource(dataSource)

        // set the custom title view
        navigationItem.titleView = QuranPageTitleView()

        dataRetriever.retrieve { [weak self] items in
            self?.dataSource.setItems(items)
            self?.scrollToFirstPage()
        }

        audioViewPresenter.onViewDidLoad()
    }

    private func configureAudioView() {
        quranView.audioView.onTouchesBegan = { [weak self] in
            self?.stopBarHiddenTimer()
        }
        audioViewPresenter.view = quranView.audioView
        quranView.audioView.delegate = audioViewPresenter
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        navigationController?.setNavigationBarHidden(false, animated: animated)
        interactiveGestureToken.once {
            interactivePopGestureOldEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
        }
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false

        // start hiding bars timer
        if !barsHiddenTimerExecuted {
            startHiddenBarsTimer()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        navigationController?.interactivePopGestureRecognizer?.isEnabled = interactivePopGestureOldEnabled ?? true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        didLayoutSubviewToken.once {}
        scrollToFirstPage()
    }

    fileprivate func scrollToFirstPage() {
        let currentIndex = dataSource.selectedDataSourceRepresentable.items.index(where: { $0.pageNumber == initialPage })
        guard let index = currentIndex, didLayoutSubviewToken.executed else {
            return
        }

        scrollToPageToken.once {
            let indexPath = IndexPath(item: index, section: 0)
            scrollToIndexPath(indexPath, animated: false)
            onPageChangedToPage(dataSource.selectedDataSourceRepresentable.item(at: indexPath))
        }
    }

    func stopBarHiddenTimer() {
        barsTimer?.cancel()
        barsTimer = nil
    }

    // MARK: - QuranImagesDataSourceDelegate

    func share(ayahText: String) {
        ShareController.showShareActivityWithText(ayahText, sourceViewController: self, handler: nil)
    }

    func lastViewedPage() -> Int {
        return lastPageUpdater.lastPage?.page ?? initialPage
    }

    // MARK: - Quran View Delegate

    func onQuranViewTapped(_ quranView: QuranView) {
        setBarsHidden(navigationController?.isNavigationBarHidden == false)
    }

    private func setBarsHidden(_ hidden: Bool) {
        // remove the timer
        barsHiddenTimerExecuted = true
        stopBarHiddenTimer()

        navigationController?.setNavigationBarHidden(hidden, animated: true)
        quranView.setBarsHidden(hidden)

        // animate the change
        UIView.animate(withDuration: 0.3, animations: {
            self.statusBarHidden = hidden
            self.view.layoutIfNeeded()
        })
    }

    fileprivate func startHiddenBarsTimer() {
        // increate the timer duration to give existing users the time to see the new buttons
        barsTimer = Timer(interval: 5) { [weak self] in
            if self?.presentedViewController == nil {
                self?.setBarsHidden(true)
            }
        }
    }

    fileprivate func scrollToIndexPath(_ indexPath: IndexPath, animated: Bool) {
        quranView.collectionView.scrollToItem(at: indexPath,
                                              at: .centeredHorizontally,
                                              animated: false)
    }

    fileprivate func onPageChanged() {
        guard let page = currentPage() else { return }
        onPageChangedToPage(page)
    }

    fileprivate func onPageChangedToPage(_ page: QuranPage) {
        updateBarToPage(page)
    }

    fileprivate func updateBarToPage(_ page: QuranPage) {
        titleView?.setPageNumber(page.pageNumber, navigationBar: navigationController?.navigationBar)

        bookmarksManager.calculateIsBookmarked(pageNumber: page.pageNumber)
            .then(on: .main) { _ -> Void in
                guard page.pageNumber == self.currentPage()?.pageNumber else { return }
                self.quranNavigationBar.updateRightBarItems(animated: false)
            }.cauterize(tag: "bookmarksPersistence.isPageBookmarked")

        // only persist if active
        if UIApplication.shared.applicationState == .active {
            Crash.setValue(page.pageNumber, forKey: .QuranPage)
            lastPageUpdater.updateTo(page: page.pageNumber)
        }
    }

    func onBookmarkButtonTapped() {
        guard let page = currentPage() else { return }

        bookmarksManager
            .toggleBookmarking(pageNumber: page.pageNumber)
            .cauterize(tag: "bookmarksPersistence.toggleBookmarking")
    }

    func onTranslationButtonTapped() {
        updateTranslationView()
    }

    func onSelectTranslationsButtonTapped() {
        let controller = translationsSelectionControllerCreator.create()
        present(controller, animated: true, completion: nil)
    }

    func showQariListSelectionWithQari(_ qaris: [Qari], selectedIndex: Int) {
        let controller = qarisControllerCreator.create((qaris, selectedIndex, quranView.audioView))
        controller.onSelectedIndexChanged = { [weak self] index in
            self?.audioViewPresenter.setQariIndex(index)
        }
        present(controller, animated: true, completion: nil)
    }

    func highlightAyah(_ ayah: AyahNumber) {
        var set = Set<AyahNumber>()
        set.insert(ayah)
        dataSource.highlightAyaht(set)

        // persist if not active
        guard UIApplication.shared.applicationState != .active else { return }
        Queue.background.async {
            let page = ayah.getStartPage()
            self.lastPageUpdater.updateTo(page: page)
            Crash.setValue(page, forKey: .QuranPage)
        }
    }

    func removeHighlighting() {
        dataSource.highlightAyaht(Set())
    }

    func currentPage() -> QuranPage? {
        return quranView.visibleIndexPath().map { dataSource.selectedDataSourceRepresentable.item(at: $0) }
    }

    func onErrorOccurred(error: Error) {
        showErrorAlert(error: error)
    }

    private func updateTranslationView() {
        dataSource.selectedDataSourceIndex = quranNavigationBar.isTranslationView ? 1 : 0
    }
}
