import XCTest
import CoreImage
import UIKit
@testable import Blink

final class QRImageDecoderTests: XCTestCase {
    func testQRImagesRoundTripLinksAndMultilineConfigs() throws {
        let payloads = [
            "https://panel.example/sub/fixture?token=a%2Bb",
            "vless://00000000-0000-4000-8000-000000000001@example.org:443?security=tls#Test",
            "[Interface]\nPrivateKey = fixture=\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = peer=\nEndpoint = example.org:51820"
        ]
        let context = CIContext()
        for payload in payloads {
            let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
            filter.setValue(Data(payload.utf8), forKey: "inputMessage")
            let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
            let rendered = try XCTUnwrap(context.createCGImage(image, from: image.extent))
            let png = try XCTUnwrap(UIImage(cgImage: rendered).pngData())
            XCTAssertEqual(try QRImageDecoder.decode(png), payload)
        }
    }

    func testInvalidImageIsRejected() {
        XCTAssertThrowsError(try QRImageDecoder.decode(Data("not an image".utf8)))
    }
}
