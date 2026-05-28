import SwiftUI

public struct PasswordManageriOSAppRoot: View {
    @State private var vaultStore = VaultStore()

    public init() {}

    public var body: some View {
        ContentView(store: vaultStore)
    }
}
