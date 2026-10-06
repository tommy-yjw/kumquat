import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// 金桔应用图标生成脚本(开发期工具,非 app 运行时组件)。
// 用法:swift Tools/make_icon.swift /tmp/kumquat_icon_1024.png
// 生成 1024×1024 主图后,由 make_icon.sh 配合 sips + iconutil 产出 .icns。

let side: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, a])!
}

// 背景:圆角矩形 + 橙色渐变(macOS 图标栅格:1024 画布,824 主体,190 圆角)
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 190, cornerHeight: 190, transform: nil)
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: colorSpace,
                    colors: [rgb(255, 187, 77), rgb(244, 112, 27)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

// 顶部柔和高光
ctx.setFillColor(rgb(255, 255, 255, 0.10))
ctx.fillEllipse(in: CGRect(x: 140, y: 690, width: 744, height: 330))

// 果实:奶白圆(金桔果体),圆心 (512, 540) 半径 218(CG 坐标系 y 向上)
ctx.setFillColor(rgb(255, 247, 228))
ctx.fillEllipse(in: CGRect(x: 512 - 218, y: 540 - 218, width: 436, height: 436))

// 果柄(棕色圆头短线,从果实顶部伸向右上)
ctx.setStrokeColor(rgb(122, 74, 33))
ctx.setLineWidth(18)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 512, y: 748))
ctx.addLine(to: CGPoint(x: 596, y: 802))
ctx.strokePath()

// 叶子(绿色椭圆,绕叶柄旋转,朝右上扬起)
ctx.saveGState()
ctx.translateBy(x: 686, y: 838)
ctx.rotate(by: 0.42)
let leaf = CGGradient(colorsSpace: colorSpace,
                      colors: [rgb(72, 176, 84), rgb(26, 118, 52)] as CFArray,
                      locations: [0, 1])!
ctx.addEllipse(in: CGRect(x: -128, y: -52, width: 256, height: 104))
ctx.clip()
ctx.drawLinearGradient(leaf, start: CGPoint(x: -128, y: 0), end: CGPoint(x: 128, y: 0), options: [])
ctx.restoreGState()

// 果脐(顶部小圆点)
ctx.setFillColor(rgb(238, 214, 168))
ctx.fillEllipse(in: CGRect(x: 512 - 22, y: 736 - 22, width: 44, height: 44))

let image = ctx.makeImage()!
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let outURL = URL(fileURLWithPath: outPath) as CFURL
let dst = CGImageDestinationCreateWithURL(outURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, image, nil)
CGImageDestinationFinalize(dst)
print("written \(outPath)")
