// Генерирует Resources/AppIcon.icns. Запуск: swift scripts/make-icon.swift
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 230, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.34),
                                          Color(red: 0.09, green: 0.10, blue: 0.15)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 480, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1.0),
                                                             Color(red: 0.45, green: 0.58, blue: 0.95)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .frame(width: 824, height: 824)
            .frame(width: 1024, height: 1024)
    }
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let renderer = ImageRenderer(content: Icon())
            renderer.scale = CGFloat(px) / 1024
            guard let cg = renderer.cgImage else { fatalError("render failed") }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! png.write(to: iconset.appendingPathComponent(name))
        }
    }
}

try FileManager.default.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns готов" : "iconutil упал")
