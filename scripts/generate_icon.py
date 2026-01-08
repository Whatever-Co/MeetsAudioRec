#!/usr/bin/env python3
"""Generate app icon for MeetsAudioRec using SF Symbols"""

from pathlib import Path

from AppKit import (
    NSBezierPath,
    NSBitmapImageRep,
    NSColor,
    NSCompositingOperationSourceOver,
    NSFontWeightHeavy,
    NSGradient,
    NSGraphicsContext,
    NSImage,
    NSImageSymbolConfiguration,
    NSMakeRect,
    NSPNGFileType,
)
from Foundation import NSPoint, NSSize


def create_icon(size: int = 1024) -> NSImage:
    """Create the app icon using SF Symbols mic.fill"""
    image = NSImage.alloc().initWithSize_(NSSize(size, size))
    image.lockFocus()

    ctx = NSGraphicsContext.currentContext()
    ctx.setShouldAntialias_(True)

    # White rounded rect background (Apple standard)
    icon_size = size
    corner_radius = icon_size * 0.22

    bg_rect = NSMakeRect(0, 0, icon_size, icon_size)
    bg_path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        bg_rect, corner_radius, corner_radius
    )

    # Top gradient overlay for subtle 3D effect
    top_gradient = NSGradient.alloc().initWithStartingColor_endingColor_(
        NSColor.colorWithCalibratedRed_green_blue_alpha_(1, 1, 1, 1.0),
        NSColor.colorWithCalibratedRed_green_blue_alpha_(0.95, 0.95, 0.95, 1.0),
    )
    top_gradient.drawInBezierPath_angle_(bg_path, 90)

    # SF Symbol: mic.fill
    symbol_name = "mic.fill"
    symbol_image = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
        symbol_name, None
    )

    if symbol_image:
        size_config = NSImageSymbolConfiguration.configurationWithPointSize_weight_(
            size * 0.52, NSFontWeightHeavy
        )

        dark_gray = NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.18, 0.18, 0.18, 1.0
        )
        color_config = NSImageSymbolConfiguration.configurationWithHierarchicalColor_(
            dark_gray
        )

        combined_config = size_config.configurationByApplyingConfiguration_(
            color_config
        )
        configured_symbol = symbol_image.imageWithSymbolConfiguration_(combined_config)
        if configured_symbol:
            symbol_image = configured_symbol

        symbol_size = symbol_image.size()
        x = (size - symbol_size.width) / 2
        y = (size - symbol_size.height) / 2

        symbol_image.drawAtPoint_fromRect_operation_fraction_(
            NSPoint(x, y),
            NSMakeRect(0, 0, symbol_size.width, symbol_size.height),
            NSCompositingOperationSourceOver,
            1.0,
        )

    image.unlockFocus()
    return image


def save_png(image: NSImage, path: Path, size: int):
    """Save NSImage as PNG at specified size"""
    if size != 1024:
        resized = NSImage.alloc().initWithSize_(NSSize(size, size))
        resized.lockFocus()
        NSGraphicsContext.currentContext().setImageInterpolation_(3)
        image.drawInRect_fromRect_operation_fraction_(
            NSMakeRect(0, 0, size, size),
            NSMakeRect(0, 0, 1024, 1024),
            NSCompositingOperationSourceOver,
            1.0,
        )
        resized.unlockFocus()
        image = resized

    tiff_data = image.TIFFRepresentation()
    bitmap = NSBitmapImageRep.imageRepWithData_(tiff_data)
    png_data = bitmap.representationUsingType_properties_(NSPNGFileType, None)

    png_data.writeToFile_atomically_(str(path), True)
    print(f"  Created: {path.name} ({size}x{size})")


def main():
    output_dir = (
        Path(__file__).parent.parent
        / "MeetsAudioRec"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    print("Creating icon with SF Symbol 'mic.fill'...")
    icon = create_icon(1024)

    sizes = [16, 32, 64, 128, 256, 512, 1024]

    print("\nGenerating PNG icons...")
    for size in sizes:
        output_path = output_dir / f"appicon_{size}.png"
        save_png(icon, output_path, size)

    print("\nAll icons generated successfully!")


if __name__ == "__main__":
    main()
