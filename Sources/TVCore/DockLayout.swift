import Foundation
import CoreGraphics

/// 坞里多窗的排布方式。
///
/// 用户要求：「不同迷你窗的图层前后显示顺序需要可以拖拽」「多个窗口需要支持平铺处理」。
/// 这两件事是分开的：
///   · **z-order（谁在前）** —— 由 `VideoTaskCenter.tasks` 的数组顺序决定（首位 = 最上），
///     用户**点一下卡片**就把它挪到最前；
///   · **摆位（在哪）** —— 有「自由摆放」与「平铺」两种，这里给出平铺的算法。
public enum DockLayoutMode: String, CaseIterable, Codable, Sendable {
    /// 自由摆放：每张卡各自记自己的偏移，可以重叠。
    case free
    /// 锁定平铺：所有卡按网格自动排好，不重叠、**尺寸统一**，位置不接受拖动。
    case tiled
}

public enum DockLayout {

    /// 平铺时每张卡的尺寸与位置（相对坞容器，原点左上）。
    ///
    /// `size` 是**整张卡**的尺寸（含标题栏），不是画面的尺寸 ——
    /// 只有含标题栏，格子之间才不会因为那 30 多 pt 的标题条互相重叠。
    public struct Tile: Equatable, Sendable {
        public let origin: CGPoint
        public let size: CGSize
        public init(origin: CGPoint, size: CGSize) {
            self.origin = origin
            self.size = size
        }
    }

    /// 把 `count` 张卡排进 `container`。
    ///
    /// 规则（刻意简单，因为要能预测）：
    ///   · 列数取 `ceil(sqrt(n))`，让格子接近正方形 —— 8 张是 3×3，4 张是 2×2；
    ///   · 格子宽高按容器等分，**保持画面宽高比**（`aspect`），不拉伸；
    ///   · `chrome` 是画面下方的标题栏高度：**必须算进格子的高**，
    ///     否则每张卡都会比自己的格子高 30 多 pt，上下两排就叠在一起
    ///     （这正是用户说的「整理完图层互相折叠」）；
    ///   · 整组在容器内**居中**，不做左上对齐（视觉上更稳）；
    ///   · 容器太小就自动退化为 1 列。
    ///
    /// 空 `count` 或非正容器尺寸返回空数组 —— 调用方据此不画。
    public static func tiles(count: Int,
                             in container: CGSize,
                             aspect: CGFloat,
                             chrome: CGFloat = 0,
                             spacing: CGFloat = 8) -> [Tile] {
        guard count > 0, container.width > 1, container.height > 1 else { return [] }
        let cols = max(1, Int(ceil(Double(count).squareRoot())))
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))
        let safeChrome = max(0, chrome)

        let cellW = (container.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (container.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
        guard cellW > 1, cellH > 1 else {
            // 容器太小放不下网格：退化成「一列铺满」。
            let h = max(1, (container.height - spacing * CGFloat(count + 1)) / CGFloat(count))
            return (0..<count).map { i in
                Tile(origin: CGPoint(x: spacing, y: spacing + CGFloat(i) * (h + spacing)),
                     size: CGSize(width: max(1, container.width - spacing * 2), height: h))
            }
        }

        // 按格子定卡片尺寸：宽取格子宽，高 = 宽 / 画面宽高比 + 标题栏，超高就反过来压宽。
        let safeAspect = max(aspect, 0.2)
        var w = cellW
        var h = w / safeAspect + safeChrome
        if h > cellH {
            h = cellH
            w = max(1, (h - safeChrome) * safeAspect)
        }

        // 整组居中。
        let gridW = CGFloat(cols) * w + CGFloat(cols + 1) * spacing
        let gridH = CGFloat(rows) * h + CGFloat(rows + 1) * spacing
        let originX = max(spacing, (container.width - gridW) / 2 + spacing)
        let originY = max(spacing, (container.height - gridH) / 2 + spacing)

        return (0..<count).map { i in
            let r = i / cols
            let c = i % cols
            return Tile(origin: CGPoint(x: originX + CGFloat(c) * (w + spacing),
                                        y: originY + CGFloat(r) * (h + spacing)),
                        size: CGSize(width: w, height: h))
        }
    }

    /// 整理多窗：**统一视窗宽**、逐行排开、互不重叠，从右下角往里收。
    ///
    /// 与上面那个「铺满容器」的 `tiles` 是两种用途：
    ///   · `tiles` 是「把容器等分」，格子会很大（一张卡就能占半屏）；
    ///   · 这里是**整理**：每张卡保持「平时那么大」（`cardWidth`），
    ///     能并排就并排，排不下就往上加一行，实在放不下才整体等比缩小。
    ///
    /// 为什么统一的是**宽**而不是宽高同时：卡片画面比例各自不同（竖屏短剧 9:16、
    /// 电影 2.35:1），强行统一高度只能拉伸或加黑边。统一宽度 + 按各自比例算高，
    /// 同一个「视窗宽」，看起来才是一排整齐的窗。
    ///
    /// 行高取该行**最高**的那张（`aspects` 里最小的比例 = 最高的卡）再加 `chrome`，
    /// 所以标题栏那 30 多 pt 也被算进去了 —— 少了这一步，上下两排就会叠在一起，
    /// 那正是用户说的「整理完图层互相折叠」。
    public static func packedTiles(count: Int,
                                   aspects: [CGFloat],
                                   cardWidth: CGFloat,
                                   chrome: CGFloat,
                                   in container: CGSize,
                                   spacing: CGFloat = 10) -> [Tile] {
        guard count > 0, container.width > 1, container.height > 1, cardWidth > 1 else { return [] }
        let safeChrome = max(0, chrome)
        let ratios = (0..<count).map { i in
            max(i < aspects.count ? aspects[i] : 16.0 / 9.0, 0.2)
        }

        // 从「卡片原尺寸」开始往下试，直到整组能塞进容器。
        // 步进而不是解析求解：这里最多几十次循环，换来的是「一定不会算错」。
        var scale: CGFloat = 1
        var layout = pack(ratios: ratios, width: cardWidth, chrome: safeChrome,
                          scale: scale, in: container, spacing: spacing)
        while layout.gridHeight > container.height - spacing * 2, scale > 0.3 {
            scale -= 0.05
            layout = pack(ratios: ratios, width: cardWidth, chrome: safeChrome,
                          scale: scale, in: container, spacing: spacing)
        }
        return layout.tiles
    }

    /// 一次试探：给定缩放，算列数、行高与实际格子。
    private static func pack(ratios: [CGFloat],
                             width: CGFloat,
                             chrome: CGFloat,
                             scale: CGFloat,
                             in container: CGSize,
                             spacing: CGFloat) -> (tiles: [Tile], gridHeight: CGFloat) {
        let w = max(1, width * scale)
        let cols = max(1, Int((container.width - spacing) / (w + spacing)))
        let rows = max(1, Int(ceil(Double(ratios.count) / Double(cols))))

        // 每行的高度单独算：同排里最高那张决定这一行。
        var rowHeights: [CGFloat] = []
        for r in 0..<rows {
            var tallest: CGFloat = 1
            for c in 0..<cols {
                let i = r * cols + c
                guard i < ratios.count else { break }
                tallest = max(tallest, w / ratios[i] + chrome)
            }
            rowHeights.append(tallest)
        }
        let gridW = CGFloat(cols) * w + CGFloat(cols - 1) * spacing
        let gridH = rowHeights.reduce(0, +) + CGFloat(rows - 1) * spacing

        // 锚在右下角：最右一列贴右边缘，最后一行贴下边缘。
        let rightEdge = container.width - spacing
        let bottomEdge = container.height - spacing
        var tiles: [Tile] = []
        var y = bottomEdge - gridH
        for r in 0..<rows {
            let bandHeight = rowHeights[r]
            for c in 0..<cols {
                let i = r * cols + c
                guard i < ratios.count else { break }
                let cardH = w / ratios[i] + chrome
                let x = rightEdge - gridW + CGFloat(c) * (w + spacing)
                // 同一行内**底边对齐**（视觉上齐脚），高度差由各自比例决定。
                tiles.append(Tile(origin: CGPoint(x: x, y: y + (bandHeight - cardH)),
                                  size: CGSize(width: w, height: cardH)))
            }
            y += bandHeight + spacing
        }
        return (tiles, gridH)
    }

    /// 把平铺的绝对位置换算成坞使用的「相对右下角」偏移。
    ///
    /// 坞里卡片位置一律存成「相对容器右下角」的偏移（往左/上为负），
    /// 平铺算出来是左上原点，所以要转一次。转换放在这里，
    /// 是为了不让 UI 层重复写这个减法（写错过一次就会全歪）。
    public static func offset(for tile: Tile, in container: CGSize) -> CGSize {
        CGSize(width: tile.origin.x + tile.size.width - container.width,
               height: tile.origin.y + tile.size.height - container.height)
    }
}
