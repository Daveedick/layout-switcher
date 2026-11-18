#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: render-svg-png.swift <source.svg> <destination.png>\n", stderr)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let destinationURL = URL(fileURLWithPath: arguments[2])
guard let image = NSImage(contentsOf: sourceURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Unable to rasterize SVG: \(sourceURL.path)\n", stderr)
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode PNG: \(destinationURL.path)\n", stderr)
    exit(1)
}
try png.write(to: destinationURL, options: .atomic)
print("Rendered \(destinationURL.path) (\(cgImage.width)x\(cgImage.height))")
