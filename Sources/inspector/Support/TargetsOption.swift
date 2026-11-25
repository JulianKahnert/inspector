import ArgumentParser

/// `--targets`: a gesture's answer also lists the targets on the screen after it.
struct TargetsOption: ParsableArguments {
  @Flag(
    help: """
      Also answer `targets`, the controls in the hierarchy Xcode captured after the gesture; \
      left out when INSPECTOR_EARLY answered before Xcode.
      """)
  var targets = false
}
