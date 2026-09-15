import SwiftUI

/// SwiftUI's `State` under another name.
///
/// In the macOS 27 SDK the `@State` attribute is expanded by a macro plugin that ships
/// with Xcode but not with the Command Line Tools this project builds with ("plugin for
/// module 'SwiftUIMacros' not found"). Spelling the attribute differently selects the
/// `State` property wrapper itself — the same type with the same behaviour — so the app
/// still builds without Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>
