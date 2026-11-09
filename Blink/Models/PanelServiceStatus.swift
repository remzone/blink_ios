import Foundation
struct PanelServiceStatus: Decodable {
    let revision: Int64
    let maintenance: Bool
    let message: String
    let started_at: Int64
    let updated_at: Int64
    let expected_end: Int64
}
