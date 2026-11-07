import Foundation
import ImageIO
import Vision

enum QRImageDecoder {
    static func decode(_ data: Data) throws -> String {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw QRImageError.unreadable }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payloads = Set((request.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty })
        guard !payloads.isEmpty else { throw QRImageError.notFound }
        guard payloads.count == 1, let text = payloads.first else { throw QRImageError.multiple }
        return text
    }
}

enum QRImageError: LocalizedError {
    case unreadable, notFound, multiple
    var errorDescription: String? {
        switch self {
        case .unreadable: return "Не удалось прочитать изображение. Выберите фото размером до 20 МБ."
        case .notFound: return "QR-код на изображении не найден. Выберите более чёткое фото."
        case .multiple: return "На изображении несколько разных QR-кодов. Обрежьте фото до нужного кода."
        }
    }
}
