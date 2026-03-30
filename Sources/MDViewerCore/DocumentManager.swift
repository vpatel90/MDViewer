import SwiftUI

@MainActor
public class DocumentManager: ObservableObject {
    @Published public var tabs: [DocumentTab] = []
    @Published public var selectedTabID: UUID?
    public init() {}
}
