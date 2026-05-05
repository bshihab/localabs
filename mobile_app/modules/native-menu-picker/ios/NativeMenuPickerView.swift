import ExpoModulesCore
import UIKit

class NativeMenuPickerView: ExpoView {
  var menuOptions: [String] = []
  var currentValue: String = ""
  let onSelectOption = EventDispatcher()
  
  private var menuButton: UIButton!

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    setupButton()
  }

  private func setupButton() {
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = .secondaryLabel
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    
    menuButton = UIButton(configuration: config)
    menuButton.showsMenuAsPrimaryAction = true
    menuButton.changesSelectionAsPrimaryAction = false
    menuButton.contentHorizontalAlignment = .trailing

    addSubview(menuButton)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    menuButton.frame = bounds
  }

  func rebuildMenu() {
    let displayText = currentValue.isEmpty ? "Not Set" : currentValue

    var config = menuButton.configuration ?? UIButton.Configuration.plain()
    var titleAttr = AttributedString(displayText)
    titleAttr.font = .systemFont(ofSize: 17)
    titleAttr.foregroundColor = currentValue.isEmpty ? .tertiaryLabel : .secondaryLabel
    config.attributedTitle = titleAttr
    menuButton.configuration = config

    let actions: [UIAction] = menuOptions.map { option in
      let state: UIMenuElement.State = (option == self.currentValue) ? .on : .off
      return UIAction(title: option, state: state) { [weak self] _ in
        guard let self = self else { return }
        self.onSelectOption([
          "value": option
        ])
      }
    }

    menuButton.menu = UIMenu(title: "", children: actions)
  }
}
