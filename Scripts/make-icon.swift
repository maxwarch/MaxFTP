// Génère Resources/AppIcon.icns à partir de Resources/Icon/AppIcon-source.jpg.
//
// L'image source montre le carré arrondi de l'icône posé sur un fond clair, avec
// une ombre. On détecte ce carré (pixels sombres), on le détoure avec des coins
// transparents, puis on le place sur la grille macOS : 824 px de corps centrés
// dans une toile de 1024 px (comme les icônes système). Toutes les tailles de
// l'iconset sont ensuite produites, et `iconutil` assemble le .icns.
//
// Usage : swift Scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Icon/AppIcon-source.jpg")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
    exit(1)
}

guard let provider = CGDataProvider(url: source as CFURL),
      let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
else { fail("Image source illisible : \(source.path)") }

// Pixels RGBA 8 bits, origine en haut à gauche.
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let reader = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("Contexte de lecture impossible") }
reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// Le corps de l'icône est bleu foncé ; le fond et l'ombre sont clairs.
func isIcon(_ x: Int, _ y: Int) -> Bool {
    let i = ((height - 1 - y) * width + x) * 4  // le contexte CG a son origine en bas
    let luminance = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
    return luminance < 150
}

// Boîte englobante : lignes / colonnes dont une part significative est « icône »
// (évite qu'un pixel isolé de l'ombre n'élargisse le cadre).
func span(count: Int, other: Int, hit: (Int, Int) -> Bool) -> ClosedRange<Int> {
    let minimum = other / 10
    let rows = (0..<count).filter { a in (0..<other).filter { b in hit(a, b) }.count > minimum }
    guard let first = rows.first, let last = rows.last else { fail("Icône introuvable dans l'image") }
    return first...last
}
let xs = span(count: width, other: height) { x, y in isIcon(x, y) }
let ys = span(count: height, other: width) { y, x in isIcon(x, y) }
let body = CGRect(x: xs.lowerBound, y: ys.lowerBound, width: xs.count, height: ys.count)
print("Corps détecté : \(Int(body.width))×\(Int(body.height)) en (\(Int(body.minX)), \(Int(body.minY)))")

// Le corps est carré : l'excédent vertical vient de l'ombre portée, sous l'icône.
// On centre donc depuis le bord haut, et on rentre de 1 % pour éliminer le liseré clair.
let bodySize = min(body.width, body.height)
let side = bodySize * 0.98
let center = CGPoint(x: body.midX, y: body.minY + bodySize / 2)
let crop = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).integral
guard let cropped = image.cropping(to: crop) else { fail("Recadrage impossible") }

// Toile 1024 : corps 824×824 centré, coins arrondis (≈ 22,5 % du côté, grille Apple).
let canvas = 1024, inset = 100.0, bodySide = 824.0
guard let writer = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("Contexte d'écriture impossible") }
writer.interpolationQuality = .high
let target = CGRect(x: inset, y: inset, width: bodySide, height: bodySide)
writer.addPath(CGPath(roundedRect: target, cornerWidth: bodySide * 0.225, cornerHeight: bodySide * 0.225, transform: nil))
writer.clip()
writer.draw(cropped, in: target)
guard let master = writer.makeImage() else { fail("Rendu impossible") }

// Iconset puis .icns.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func writePNG(size: Int, name: String) throws {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("Contexte \(size) impossible") }
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    else { fail("PNG \(size) impossible") }
    try data.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    try writePNG(size: base, name: "icon_\(base)x\(base).png")
    try writePNG(size: base * 2, name: "icon_\(base)x\(base)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil a échoué") }
try? FileManager.default.removeItem(at: iconset)

// Aperçu 1024 px à côté, pratique pour vérifier le détourage.
if let preview = NSBitmapImageRep(cgImage: master).representation(using: .png, properties: [:]) {
    try preview.write(to: root.appendingPathComponent("Resources/Icon/AppIcon-1024.png"))
}
print("✅ \(output.path)")
