import Foundation

// Minimal host app: its only job is to embed MasteringAU.appex in
// Contents/PlugIns so that launching this app registers the AUv3 extension
// with PluginKit (after which auval / Logic can see it). It stays alive for
// 30 s so PluginKit has time to scan and register the embedded extension at
// launch; an app that exits immediately may be gone before the scan happens.
print("MasteringAUHost launched; staying alive 30s so PluginKit can register the extension...", terminator: "")
fflush(stdout)
Thread.sleep(forTimeInterval: 30)
print("done.")
