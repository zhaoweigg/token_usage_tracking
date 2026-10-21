import SwiftUI
import UIKit

@MainActor
enum ApricotAppearance {
    static func configure() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = HeadroomStyle.backgroundColor
        navigation.shadowColor = .clear
        navigation.titleTextAttributes = [.font: HeadroomTypography.uiFont(size: 17, weight: .semibold, textStyle: .headline),
                                          .foregroundColor: HeadroomStyle.primaryTextColor]
        navigation.largeTitleTextAttributes = [.font: HeadroomTypography.uiFont(size: 32, weight: .bold, textStyle: .largeTitle),
                                               .foregroundColor: HeadroomStyle.primaryTextColor]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().tintColor = HeadroomStyle.accentColor

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = HeadroomStyle.surfaceColor
        tab.shadowColor = .clear
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = HeadroomStyle.secondaryTextColor
            item.normal.titleTextAttributes = [.font: HeadroomTypography.uiFont(size: 11, weight: .medium, textStyle: .caption2),
                                               .foregroundColor: HeadroomStyle.secondaryTextColor]
            item.selected.iconColor = HeadroomStyle.accentColor
            item.selected.titleTextAttributes = [.font: HeadroomTypography.uiFont(size: 11, weight: .semibold, textStyle: .caption2),
                                                 .foregroundColor: HeadroomStyle.accentColor]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = HeadroomStyle.accentColor

        UISegmentedControl.appearance().backgroundColor = HeadroomStyle.tintColor
        UISegmentedControl.appearance().selectedSegmentTintColor = HeadroomStyle.surfaceColor
        UISegmentedControl.appearance().setTitleTextAttributes([.font: HeadroomTypography.uiFont(size: 13, weight: .medium, textStyle: .subheadline),
                                                               .foregroundColor: HeadroomStyle.secondaryTextColor], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: HeadroomTypography.uiFont(size: 13, weight: .semibold, textStyle: .subheadline),
                                                               .foregroundColor: HeadroomStyle.primaryTextColor], for: .selected)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: HeadroomTypography.uiFont(size: 15, weight: .semibold, textStyle: .subheadline)], for: .normal)
    }
}

private struct ApricotScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.apricot(.body))
            .foregroundStyle(HeadroomStyle.primaryText)
            .scrollContentBackground(.hidden)
            .background(HeadroomStyle.background)
            .tint(HeadroomStyle.accent)
            .toolbarBackground(HeadroomStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func apricotScreen() -> some View { modifier(ApricotScreen()) }
}

struct ApricotTestPresentation: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let values = ProcessInfo.processInfo.environment
            content
                .preferredColorScheme(values["HEADROOM_UI_TEST_APPEARANCE"] == "dark" ? .dark : .light)
                .dynamicTypeSize(values["HEADROOM_UI_TEST_LARGE_TEXT"] == "1" ? .accessibility1 : .large)
        } else { content }
        #else
        content
        #endif
    }
}
