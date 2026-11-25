#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>

typedef struct {
    const char *name;
    uint32_t top;
    uint32_t bottom;
    uint32_t edge;
    BOOL showsSignal;
} Palette;

static void components(uint32_t rgb, CGFloat out[4])
{
    out[0] = ((rgb >> 16) & 255) / 255.0;
    out[1] = ((rgb >> 8) & 255) / 255.0;
    out[2] = (rgb & 255) / 255.0;
    out[3] = 1;
}

static BOOL saveIcon(NSString *folder, Palette palette, int level)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef canvas = CGBitmapContextCreate(
        NULL, 64, 36, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGRect dot = CGRectMake(2.5, 6.5, 23, 23);

    CGFloat gradientColors[8];
    components(palette.top, gradientColors);
    components(palette.bottom, gradientColors + 4);
    CGGradientRef fill = CGGradientCreateWithColorComponents(space, gradientColors, NULL, 2);
    CGContextSaveGState(canvas);
    CGContextAddEllipseInRect(canvas, dot);
    CGContextClip(canvas);
    CGContextDrawLinearGradient(canvas, fill, CGPointMake(14, 30), CGPointMake(14, 6),
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(canvas);

    CGFloat edge[4];
    components(palette.edge, edge);
    CGContextSetRGBStrokeColor(canvas, edge[0], edge[1], edge[2], edge[3]);
    CGContextSetLineWidth(canvas, 1);
    CGContextStrokeEllipseInRect(canvas, dot);

    BOOL dark = strstr(palette.name, "_dark") != NULL;
    CGFloat ink = dark ? 1.0 : 0.10;
    for (int index = 0; index < 4; ++index) {
        CGRect bar = CGRectMake(32 + index * 7, 7, 5, 7 + index * 6);
        CGFloat opacity = index < level ? 0.92 : (dark ? 0.26 : 0.22);
        CGPathRef path = CGPathCreateWithRoundedRect(bar, 1.5, 1.5, NULL);
        CGContextSetRGBFillColor(canvas, ink, ink, ink, opacity);
        CGContextAddPath(canvas, path);
        CGContextFillPath(canvas);
        CGPathRelease(path);
    }

    CGImageRef image = CGBitmapContextCreateImage(canvas);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [folder stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%s%d.png", palette.name, level]];
    BOOL saved = [png writeToFile:path atomically:YES];

    CGImageRelease(image);
    CGGradientRelease(fill);
    CGContextRelease(canvas);
    CGColorSpaceRelease(space);
    return saved;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 2)
            return 2;
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        const Palette palettes[] = {
            {"red_light",    0xff6b62, 0xff5f57, 0xe34c43, YES},
            {"red_dark",     0xff6d66, 0xff5f57, 0xe24c44, YES},
            {"yellow_light", 0xffc841, 0xfebc2e, 0xe1a31f, NO},
            {"yellow_dark",  0xffcc45, 0xfebc2e, 0xdca01e, NO},
            {"green_light",  0x36d24a, 0x28c840, 0x18ac2e, YES},
            {"green_dark",   0x3bd74e, 0x28c840, 0x1aab30, YES},
            {"gray_light",   0xc0c0c3, 0xacacaf, 0x96969a, NO},
            {"gray_dark",    0x848489, 0x737378, 0x626268, NO},
        };
        for (size_t i = 0; i < sizeof(palettes) / sizeof(palettes[0]); ++i) {
            int maxLevel = palettes[i].showsSignal ? 4 : 0;
            for (int level = 0; level <= maxLevel; ++level) {
                if (!saveIcon(folder, palettes[i], level))
                    return 1;
            }
        }
    }
    return 0;
}
