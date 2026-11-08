import SwiftUI
import UIKit
import PhotosUI

/// 사진: 앱 그룹 폴더 photos/<id>.jpg 로 저장. 동기화가 켜져 있으면 저장소 photos/ 에도 올라감.
enum PhotoStore {
    static var dir: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func url(_ id: String) -> URL { dir.appendingPathComponent(id + ".jpg") }
    static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ id: String) -> UIImage? {
        if let c = cache.object(forKey: id as NSString) { return c }
        guard let i = UIImage(contentsOfFile: url(id).path) else { return nil }
        cache.setObject(i, forKey: id as NSString)
        return i
    }

    /// 긴 변 1600px로 줄여 JPEG로 저장하고 ID를 돌려줌
    static func add(_ data: Data) -> String? {
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let s = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: (img.size.width * s).rounded(), height: (img.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = out.jpegData(compressionQuality: 0.82) else { return nil }
        let id = "p" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UUID().uuidString.prefix(5)).lowercased()
        do { try jpg.write(to: url(id), options: .atomic) } catch { return nil }
        return id
    }

    static func write(_ id: String, data: Data) {
        try? data.write(to: url(id), options: .atomic)
        cache.removeObject(forKey: id as NSString)
    }
}

/// 작은 사진 칸 (없으면 동기화 저장소에서 받아 옴)
struct PhotoThumb: View {
    let id: String
    var size: CGFloat = 46
    @State private var img: UIImage?
    @State private var viewing = false

    var body: some View {
        Button { if img != nil { viewing = true } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.line.opacity(0.5))
                if let img {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.borderless)
        .task(id: id) {
            if let i = PhotoStore.image(id) { img = i; return }
            if await SyncService.shared.download(photo: id) { img = PhotoStore.image(id) }
        }
        .fullScreenCover(isPresented: $viewing) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img { Image(uiImage: img).resizable().scaledToFit() }
            }
            .onTapGesture { viewing = false }
            .statusBarHidden()
        }
    }
}

struct PhotoStrip: View {
    let ids: [String]
    var size: CGFloat = 46
    var body: some View {
        if !ids.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(ids, id: \.self) { PhotoThumb(id: $0, size: size) } }
            }
        }
    }
}

/// 수정 창의 사진 편집 (추가·빼기)
struct PhotoEditor: View {
    @Binding var ids: [String]
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ids, id: \.self) { id in
                    PhotoThumb(id: id, size: 58)
                        .overlay(alignment: .topTrailing) {
                            Button { ids.removeAll { $0 == id } } label: {
                                Image(systemName: "xmark.circle.fill").font(.body)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .offset(x: 6, y: -6)
                        }
                }
                PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .images) {
                    Label("사진", systemImage: "plus")
                        .font(.subheadline)
                        .frame(height: 58)
                        .padding(.horizontal, 14)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 6)
        }
        .onChange(of: picks) { _, sel in
            guard !sel.isEmpty else { return }
            Task {
                for p in sel {
                    if let d = try? await p.loadTransferable(type: Data.self), let id = PhotoStore.add(d) { ids.append(id) }
                }
                picks = []
            }
        }
    }
}
