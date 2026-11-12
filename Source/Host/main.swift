import Foundation

// Minimal host app: its only job is to embed MasteringAU.appex in
// Contents/PlugIns so that launching this app registers the AUv3 extension
// with PluginKit (after which auval / Logic can see it).
print("MasteringAUHost launched; embedded extension is now registered.")
