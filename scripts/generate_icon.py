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


def create_squircle_path(x: float, y: float, width: float, height: float) -> NSBezierPath:
    """
    Create Apple's continuous curvature rounded rectangle (squircle).
    Based on PaintCode's reverse-engineering of iOS 7+ UIBezierPath.
    https://www.paintcodeapp.com/news/code-for-ios-7-rounded-rectangles
    """
    path = NSBezierPath.bezierPath()

    # Apple's magic constant for radius limiting
    LIMIT_FACTOR = 1.52866483

    # Control point multipliers (relative to limited radius)
    # These define the continuous curvature Bézier segments
    TOP_RIGHT_P1 = 1.52866483
    TOP_RIGHT_P2 = 1.08849323
    TOP_RIGHT_P3 = 0.86840689
    TOP_RIGHT_P4 = 0.66993427
    TOP_RIGHT_P5 = 0.63149399
    TOP_RIGHT_P6 = 0.37282392
    TOP_RIGHT_P7 = 0.16906013
    TOP_RIGHT_P8 = 0.07491176

    TOP_RIGHT_CP1 = 0.06549600
    TOP_RIGHT_CP2 = 0.07491100
    TOP_RIGHT_CP3 = 0.16905899
    TOP_RIGHT_CP4 = 0.37282401
    TOP_RIGHT_CP5 = 0.63149399

    # For a square icon, use 22% corner radius (Apple standard)
    corner_radius = min(width, height) * 0.22

    # Limit the radius as Apple does
    max_radius = min(width, height) / 2
    limited_radius = min(corner_radius, max_radius / LIMIT_FACTOR)
    r = limited_radius

    # Calculate corner positions
    left = x
    right = x + width
    top = y + height
    bottom = y

    # Start at the top edge, after top-left corner
    path.moveToPoint_(NSPoint(left + r * TOP_RIGHT_P1, top))

    # Top edge (straight line to top-right corner start)
    path.lineToPoint_(NSPoint(right - r * TOP_RIGHT_P1, top))

    # Top-right corner (3 cubic Bézier segments for continuous curvature)
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P4, top - r * TOP_RIGHT_CP1),
        NSPoint(right - r * TOP_RIGHT_P2, top),
        NSPoint(right - r * TOP_RIGHT_P3, top),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_CP2, top - r * TOP_RIGHT_P5),
        NSPoint(right - r * TOP_RIGHT_P6, top - r * TOP_RIGHT_CP3),
        NSPoint(right - r * TOP_RIGHT_P7, top - r * TOP_RIGHT_CP4),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right, top - r * TOP_RIGHT_P1),
        NSPoint(right, top - r * TOP_RIGHT_P3),
        NSPoint(right, top - r * TOP_RIGHT_P2),
    )

    # Right edge
    path.lineToPoint_(NSPoint(right, bottom + r * TOP_RIGHT_P1))

    # Bottom-right corner
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_CP1, bottom + r * TOP_RIGHT_P4),
        NSPoint(right, bottom + r * TOP_RIGHT_P2),
        NSPoint(right, bottom + r * TOP_RIGHT_P3),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P5, bottom + r * TOP_RIGHT_CP2),
        NSPoint(right - r * TOP_RIGHT_CP3, bottom + r * TOP_RIGHT_P6),
        NSPoint(right - r * TOP_RIGHT_CP4, bottom + r * TOP_RIGHT_P7),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(right - r * TOP_RIGHT_P1, bottom),
        NSPoint(right - r * TOP_RIGHT_P3, bottom),
        NSPoint(right - r * TOP_RIGHT_P2, bottom),
    )

    # Bottom edge
    path.lineToPoint_(NSPoint(left + r * TOP_RIGHT_P1, bottom))

    # Bottom-left corner
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P4, bottom + r * TOP_RIGHT_CP1),
        NSPoint(left + r * TOP_RIGHT_P2, bottom),
        NSPoint(left + r * TOP_RIGHT_P3, bottom),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_CP2, bottom + r * TOP_RIGHT_P5),
        NSPoint(left + r * TOP_RIGHT_P6, bottom + r * TOP_RIGHT_CP3),
        NSPoint(left + r * TOP_RIGHT_P7, bottom + r * TOP_RIGHT_CP4),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left, bottom + r * TOP_RIGHT_P1),
        NSPoint(left, bottom + r * TOP_RIGHT_P3),
        NSPoint(left, bottom + r * TOP_RIGHT_P2),
    )

    # Left edge
    path.lineToPoint_(NSPoint(left, top - r * TOP_RIGHT_P1))

    # Top-left corner
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_CP1, top - r * TOP_RIGHT_P4),
        NSPoint(left, top - r * TOP_RIGHT_P2),
        NSPoint(left, top - r * TOP_RIGHT_P3),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P5, top - r * TOP_RIGHT_CP2),
        NSPoint(left + r * TOP_RIGHT_CP3, top - r * TOP_RIGHT_P6),
        NSPoint(left + r * TOP_RIGHT_CP4, top - r * TOP_RIGHT_P7),
    )
    path.curveToPoint_controlPoint1_controlPoint2_(
        NSPoint(left + r * TOP_RIGHT_P1, top),
        NSPoint(left + r * TOP_RIGHT_P3, top),
        NSPoint(left + r * TOP_RIGHT_P2, top),
    )

    path.closePath()
    return path


def create_icon(size: int = 1024) -> NSImage:
    """Create the app icon using SF Symbols mic.fill"""
    image = NSImage.alloc().initWithSize_(NSSize(size, size))
    image.lockFocus()

    ctx = NSGraphicsContext.currentContext()
    ctx.setShouldAntialias_(True)

    # macOS standard: 832x832 icon within 1024x1024 canvas (96px margin each side)
    # This matches Apple's icon template safe zone
    icon_size = size * 0.8125  # 832/1024 = 0.8125
    margin = (size - icon_size) / 2  # 96px at 1024 canvas

    # Use proper Apple squircle (continuous curvature) instead of simple rounded rect
    bg_path = create_squircle_path(margin, margin, icon_size, icon_size)

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
        # Symbol size proportional to background (52% of 832 = ~42% of 1024)
        symbol_point_size = icon_size * 0.52
        size_config = NSImageSymbolConfiguration.configurationWithPointSize_weight_(
            symbol_point_size, NSFontWeightHeavy
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
        # Center symbol within the background rect, not the full canvas
        x = margin + (icon_size - symbol_size.width) / 2
        y = margin + (icon_size - symbol_size.height) / 2

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
