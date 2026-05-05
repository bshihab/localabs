import ExpoModulesCore
import UIKit

class LiquidGlassButtonView: ExpoView {
  private let visualEffectView = UIVisualEffectView()
  private let glossOverlay = UIView()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupView()
  }

  private func setupView() {
    // We let React Native control the border radius via style or we enforce it here if needed.
    // AppleButton.tsx applies a static borderRadius: 28 and overflow: hidden
    // We will apply the system ultra thin material.
    
    let effectStyle: UIBlurEffect.Style
    if self.traitCollection.userInterfaceStyle == .dark {
      effectStyle = .systemUltraThinMaterialDark
    } else {
      effectStyle = .systemUltraThinMaterialLight
    }
    
    visualEffectView.effect = UIBlurEffect(style: effectStyle)
    
    // Gloss overlay for typical Apple HIG highlight on top of the blur
    glossOverlay.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    glossOverlay.isUserInteractionEnabled = false
    
    addSubview(visualEffectView)
    addSubview(glossOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    visualEffectView.frame = bounds
    // Apply gloss over the top half for the pill
    glossOverlay.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if self.traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      let effectStyle: UIBlurEffect.Style
      if self.traitCollection.userInterfaceStyle == .dark {
        effectStyle = .systemUltraThinMaterialDark
      } else {
        effectStyle = .systemUltraThinMaterialLight
      }
      visualEffectView.effect = UIBlurEffect(style: effectStyle)
    }
  }
}
