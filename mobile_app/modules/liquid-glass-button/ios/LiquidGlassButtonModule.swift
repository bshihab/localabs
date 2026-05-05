import ExpoModulesCore

public class LiquidGlassButtonModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LiquidGlassButton")

    View(LiquidGlassButtonView.self) {
      // Pure visual effect view, no props needed for now
    }
  }
}
