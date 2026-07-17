// Dieses Manifest-Target wird nicht in die Apps gelinkt. Es teilt SwiftPM nur
// explizit mit, dass die von build-app.sh verwendete Sparkle-Abhängigkeit lebt.
import Sparkle

public typealias FavenioSparkleUpdaterController =
    SPUStandardUpdaterController
