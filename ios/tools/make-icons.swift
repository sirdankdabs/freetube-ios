// Writes the iOS app icon variants as SVGs, based on the FreeTube logo glyph (see _icons/icon.svg)
// They are rasterised by tools/make-icons.sh
// Usage: swift tools/make-icons.swift <output directory>
import Foundation

let glyph = """
<path d="M14.75 13C13.226 13 12 14.275 12 15.857v30C12 50.143 17.5 53 20.25 53H23V15.857C23 14.275 21.773 13 20.25 13zm14.092 0C27.267 13 26 14.226 26 15.75v5.5c0 1.523 1.267 2.75 2.842 2.75h17.053C50.158 24 53 18.5 53 15.75V13h-7.105zM27.32 27A1.291 1.141 0 0 0 26 28.143v14.719a1.291 1.141 0 0 0 1.936.986l7.21-3.68 7.21-3.68a1.291 1.141 0 0 0 0-1.976l-7.21-3.678-7.21-3.68A1.291 1.141 0 0 0 27.32 27" style="opacity:SHADOW"/>
<path d="M14.75 12C13.226 12 12 13.274 12 14.857v30C12 49.143 17.5 52 20.25 52H23V14.857C23 13.274 21.773 12 20.25 12zM26 20.25c0 1.523 1.268 2.75 2.842 2.75h17.053C50.158 23 53 17.5 53 14.75V12H28.842C27.268 12 26 13.226 26 14.75z" style="fill:RED"/>
<path d="M27.321 26A1.291 1.141 0 0 0 26 27.143V41.86a1.291 1.141 0 0 0 1.936.986l7.21-3.679 7.21-3.68a1.291 1.141 0 0 0 0-1.976l-7.21-3.679-7.21-3.68a1.291 1.141 0 0 0-.615-.153z" style="fill:BLUE"/>
"""

func svg(background: String?, red: String, blue: String, shadow: String) -> String {
  let bg = background.map { "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">\($0)</linearGradient></defs><rect x=\"0\" y=\"0\" width=\"65\" height=\"65\" fill=\"url(#g)\"/>" } ?? ""
  let body = glyph.replacingOccurrences(of: "RED", with: red)
    .replacingOccurrences(of: "BLUE", with: blue)
    .replacingOccurrences(of: "SHADOW", with: shadow)
  return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 65 65\">\(bg)<g transform=\"translate(32.5 32.5) scale(1.08) translate(-32.5 -32.5)\">\(body)</g></svg>"
}

func write(_ svgString: String, to path: String) {
  try! svgString.write(toFile: path, atomically: true, encoding: .utf8)
}

let out = CommandLine.arguments[1]
write(svg(background: "<stop offset=\"0\" stop-color=\"#f7f7f7\"/><stop offset=\"1\" stop-color=\"#dedede\"/>", red: "#f04242", blue: "#14a4df", shadow: ".1"),
      to: "\(out)/AppIcon.svg")
write(svg(background: "<stop offset=\"0\" stop-color=\"#2b2b2e\"/><stop offset=\"1\" stop-color=\"#161618\"/>", red: "#f04242", blue: "#14a4df", shadow: ".25"),
      to: "\(out)/AppIcon-Dark.svg")
write(svg(background: "<stop offset=\"0\" stop-color=\"#000000\"/><stop offset=\"1\" stop-color=\"#000000\"/>", red: "#ffffff", blue: "#a0a0a0", shadow: "0"),
      to: "\(out)/AppIcon-Tinted.svg")
