import ExpoModulesCore

public class NativeMenuPickerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("NativeMenuPicker")

    View(NativeMenuPickerView.self) {
      Events("onSelectOption")

      Prop("options") { (view, options: [String]) in
        view.menuOptions = options
        view.rebuildMenu()
      }

      Prop("selectedValue") { (view, value: String) in
        view.currentValue = value
        view.rebuildMenu()
      }
    }
  }
}
