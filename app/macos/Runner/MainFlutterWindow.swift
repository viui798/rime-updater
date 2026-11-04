import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 初始窗口大小：足够放下设备表、日志和备份区
    self.setContentSize(NSSize(width: 980, height: 760))
    self.minSize = NSSize(width: 360, height: 500)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.title = "Rime 更新器"
  }
}
