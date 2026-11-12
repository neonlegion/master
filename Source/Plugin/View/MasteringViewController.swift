import Cocoa
import SwiftUI
import AudioToolbox

// AUv3 view principal class. The host instantiates this in the AUv3 UI
// extension and injects the audio unit via the `audioUnit` property.
@objc(MasteringViewController)
class MasteringViewController: NSViewController, AUAudioUnitViewController {

    var audioUnit: AUAudioUnit?

    private var hostingView: NSHostingView<MasteringView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let au = audioUnit as? MasteringAUAudioUnit else { return }
        let view = MasteringView(audioUnit: au)
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: self.view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        self.hostingView = hosting
    }
}
