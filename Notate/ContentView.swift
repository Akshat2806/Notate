//
//  ContentView.swift
//  Notate
//
//  Created by Akshat Srivastava on 21/09/26.
//

import SwiftUI

enum NotateAppearence: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    
    var id: Self { self }
    
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case.dark: .dark
        }
    }
}


/// User-facing defaults shared by Settings and newly created documetns.
/// /// Existing documents retain their own canvas preferences
enum NotatePreferences {
    static let appearenceKey = "notate.settings.appearence"
    static let drawWithFingerKey = "notate.settings.drawWithFingerByDefault"
    static let scrollDirectionKey = "notate.settings.defaultScrollDirection"
    
    static var defaultCanvasPreferences: CanvasPreferences {
        CanvasPreferences(
            inputMode: drawWithFingerKey ? .pencilAndFinger : .pencilOnly,
            pageLayout: CanvasPageLayoutPreferences(
                scrollDirection: defaultScrollDirection,
                pageDisplayMode: .singlePage
            )
        )
    }
}

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
