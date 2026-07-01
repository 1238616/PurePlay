import Foundation
import AppKit
import PurePlayCore

final class AlbumGridView: NSView {
    private let collectionView = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    
    var albums: [AlbumRecord] = [] {
        didSet {
            collectionView.reloadData()
        }
    }
    
    var onAlbumSelected: ((AlbumRecord) -> Void)?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1.0).cgColor
        
        // Configure flow layout
        flowLayout.itemSize = NSSize(width: 200, height: 240)
        flowLayout.minimumInteritemSpacing = 16
        flowLayout.minimumLineSpacing = 16
        flowLayout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        
        // Configure collection view
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        
        // Register cell class
        collectionView.register(AlbumGridItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("AlbumGridItem"))
        
        addSubview(collectionView)
        
        // Layout
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

extension AlbumGridView: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return albums.count
    }
    
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("AlbumGridItem"), for: indexPath) as! AlbumGridItem
        let album = albums[indexPath.item]
        item.configure(with: album)
        return item
    }
}

extension AlbumGridView: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        let album = albums[indexPath.item]
        onAlbumSelected?(album)
    }
}

final class AlbumGridItem: NSCollectionViewItem {
    private let coverImageView = NSImageView()
    private let titleLabel = NSTextField()
    private let artistLabel = NSTextField()
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        // Cover image
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.imageScaling = .scaleProportionallyUpOrDown
        coverImageView.wantsLayer = true
        coverImageView.layer?.cornerRadius = 4
        coverImageView.layer?.masksToBounds = true
        view.addSubview(coverImageView)
        
        // Title label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        view.addSubview(titleLabel)
        
        // Artist label
        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        artistLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1
        view.addSubview(artistLabel)
        
        // Layout
        NSLayoutConstraint.activate([
            coverImageView.topAnchor.constraint(equalTo: view.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coverImageView.heightAnchor.constraint(equalTo: coverImageView.widthAnchor),
            
            titleLabel.topAnchor.constraint(equalTo: coverImageView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    func configure(with album: AlbumRecord) {
        titleLabel.stringValue = album.title
        artistLabel.stringValue = album.artist
        
        // Load cover art
        if let coverPath = album.coverArtPath,
           let image = NSImage(contentsOfFile: coverPath) {
            coverImageView.image = image
        } else {
            // Default placeholder
            coverImageView.image = createPlaceholderImage()
        }
    }
    
    private func createPlaceholderImage() -> NSImage {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        
        NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.25, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()
        
        let text = "♪"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 80, weight: .light),
            .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1.0)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        text.draw(at: textOrigin, withAttributes: attributes)
        
        image.unlockFocus()
        return image
    }
    
    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.35, alpha: 1.0).cgColor
                : nil
        }
    }
}
