//
//  TabBarAnimator.swift
//  yprompt
//

#if os(iOS)
import SwiftUI
import UIKit

/// Slides the root `UITabBar` down to hide and up to show.
@MainActor
enum TabBarAnimator {
    static let duration: TimeInterval = 0.35

    private static var isHidden = false

    static func setHidden(_ hidden: Bool, animated: Bool = true) {
        guard let tabBar = tabBarController()?.tabBar else { return }
        guard hidden != isHidden else { return }
        isHidden = hidden

        tabBar.layer.removeAllAnimations()

        let slideTransform = CGAffineTransform(translationX: 0, y: tabBar.bounds.height)

        if animated {
            if hidden {
                tabBar.isHidden = false
                tabBar.transform = .identity
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    tabBar.transform = slideTransform
                } completion: { finished in
                    guard finished, isHidden else { return }
                    tabBar.isHidden = true
                    tabBar.transform = .identity
                }
            } else {
                tabBar.isHidden = false
                tabBar.transform = slideTransform
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    tabBar.transform = .identity
                }
            }
        } else {
            tabBar.transform = .identity
            tabBar.isHidden = hidden
        }
    }

    private static func tabBarController() -> UITabBarController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                if let found = findTabBarController(from: window.rootViewController) {
                    return found
                }
            }
        }
        return nil
    }

    private static func findTabBarController(from viewController: UIViewController?) -> UITabBarController? {
        guard let viewController else { return nil }
        if let tabBarController = viewController as? UITabBarController {
            return tabBarController
        }
        for child in viewController.children {
            if let found = findTabBarController(from: child) {
                return found
            }
        }
        return findTabBarController(from: viewController.presentedViewController)
    }
}

/// Disables the interactive edge-swipe pop so exit can dismiss the player sheet first.
struct NavigationInteractivePopGestureDisabler: UIViewControllerRepresentable {
    var disabled: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = !disabled
        }
    }
}
#endif
