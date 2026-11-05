#!/usr/bin/env python3
"""Duo 折叠屏截图自动化布局审计：像素级检测文字裁切 / 贴边 / 大面积异常色块 / 黑屏。

这是「运行时取证」的规模化版本 —— 上一轮靠红色 spacer + PIL 逐行核对定位布局 bug，
这里把同一套像素分析做成批量检测，对每一张截图输出结构化结论，供视觉模型二次确认。

用法：
    python3 Scripts/audit-pixels.py <截图目录>
    python3 Scripts/audit-pixels.py <截图目录> --json > report.json
"""
import sys, os, json, argparse
from PIL import Image
from collections import Counter

def analyze(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    r = {"file": os.path.basename(path), "w": w, "h": h, "issues": []}

    # 1. 黑屏检测：整图平均亮度极低
    g = im.convert("L")
    ext = g.getextrema()
    if ext[1] <= 12:
        r["issues"].append("黑屏/息屏")
        return r

    # 2. 边缘贴边检测：四边是否有连续的非背景内容（文字/控件贴到屏幕边缘）
    #    取四边各一条 1px 带，统计"非统一背景"的比例
    def edge_nonuniform(edge_pixels):
        # 该边缘像素的方差：方差大说明有内容贴边（文字、控件边缘）
        vals = [sum(edge_pixels[i]) / 3 for i in range(len(edge_pixels))]
        mean = sum(vals) / len(vals)
        var = sum((v - mean) ** 2 for v in vals) / len(vals)
        return var

    top = [px[x, 0] for x in range(0, w, 3)]
    bot = [px[x, h - 1] for x in range(0, w, 3)]
    left = [px[0, y] for y in range(0, h, 3)]
    right = [px[w - 1, y] for y in range(0, h, 3)]
    # 阈值：方差 > 400 视为有内容贴边（经验值，纯背景方差 < 100）
    for name, edge in (("顶边", top), ("底边", bot), ("左边", left), ("右边", right)):
        v = edge_nonuniform(edge)
        if v > 400:
            r["issues"].append(f"{name}贴边(方差{v:.0f})")

    # 3. 大面积纯色异常块检测：只在图中间区域（非边缘留白）找纯色块，
    #    中间区域的纯色块才可能是遮挡/黑块/白块 bug。边缘留白是正常导航/状态栏。
    grid = 8
    cw, ch = w // grid, h // grid
    for gy in range(2, grid - 2):   # 跳过上下各 2 格（状态栏/导航栏/底部 tab）
        for gx in range(grid):
            x0, y0 = gx * cw, gy * ch
            x1, y1 = min(x0 + cw, w), min(y0 + ch, h)
            sample = px[x0, y0]
            diffs = 0
            cnt = 0
            for yy in range(y0, y1, max(1, (y1 - y0) // 8)):
                for xx in range(x0, x1, max(1, (x1 - x0) // 8)):
                    cnt += 1
                    if sum(abs(sample[i] - px[xx, yy][i]) for i in range(3)) > 60:
                        diffs += 1
            if cnt > 0 and diffs / cnt < 0.03:
                lum = sum(sample) / 3
                # 只报"异常纯色"：极黑（<30，疑似遮挡/黑块）或极白（>245，疑似白屏）
                if lum < 30 or lum > 245:
                    r["issues"].append(f"中间纯色块@({gx},{gy}) RGB{sample} lum{lum:.0f}")

    # 4. 主色统计：判断深色/浅色主题是否与预期一致
    small = im.resize((64, 64))
    colors = Counter(small.getdata())
    dominant = colors.most_common(1)[0][0]
    lum = sum(dominant) / 3
    r["dominant_lum"] = round(lum, 1)
    r["theme_guess"] = "dark" if lum < 128 else "light"

    return r

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.dir) if f.endswith(".png"))
    results = [analyze(os.path.join(args.dir, f)) for f in files]

    flagged = [r for r in results if r.get("issues")]
    clean = [r for r in results if not r.get("issues")]

    if args.json:
        print(json.dumps({"total": len(results), "flagged": flagged, "clean_count": len(clean)}, ensure_ascii=False, indent=2))
    else:
        print(f"共 {len(results)} 张，{len(flagged)} 张有疑点，{len(clean)} 张干净\n")
        for r in flagged:
            print(f"【{r['file']}】{r['w']}×{r['h']} 主题{r['theme_guess']}")
            for i in r["issues"]:
                print(f"   - {i}")
            print()

if __name__ == "__main__":
    main()
