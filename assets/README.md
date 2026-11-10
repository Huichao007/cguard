# assets

README 配图的源文件。图是**代码画的**，不是 AI 生图——因为 AI 生图写中文必然错字，
而这里的每张图都含精确数字。

## 文件

| 文件               | 用途                | 出现在                                  |
| ------------------ | ------------------- | --------------------------------------- |
| `zh-hero.png`      | 中文首屏效果图      | `README.zh-CN.md` 顶部                  |
| `zh-what-eats.png` | 谁吃了 C 盘（中文） | `README.zh-CN.md` 第二屏                |
| `hero.png`         | 英文首屏效果图      | `README.md` 顶部、GitHub social preview |
| `what-eats.png`    | 谁吃了 C 盘（英文） | `README.md` The problem                 |
| `how-it-works.png` | 三步流程 + 安装命令 | 中英文 README 的用法段                  |

`*.html` 是源文件，`render.mjs` 负责渲染。

## 改图

HTML 直接改，然后用无头 Chromium 重新导出：

```powershell
cd assets
npm link playwright        # 或者把 playwright 放到 node_modules
node render.mjs            # 全部
node render.mjs zh-hero    # 单张
```

渲染参数：`deviceScaleFactor: 2`，所以 1280 宽的图实际输出 2560px，Retina 也清晰。

## 尺寸不要随便改

每张图的高度写在 `render.mjs` 的 `shots` 里，是**固定值**。不要改成自动量高：

- 背景的 `glow` / `grid` 是绝对定位，会超出布局盒，`document.scrollHeight` 会把它们算进去，量出巨大空白。
- hero 用了 `margin-top:auto` 把卡片推到底部，测量时若临时改 `height:auto`，布局会塌，卡片挤到正文正下方。

改内容后如果留白不对，直接调 HTML 里的 `margin-top`，不要动渲染器的量高逻辑。

## 不许做的事

- 不许在图上写**没有实测依据**的数字。2026-11-10 第一版曾凭印象写了「卷影副本 ~46 GB」
  和「Windows Update ~22 GB」，没有任何记录支撑，已删掉，改成文字说明 + 实测项。
- 不许用 emoji。
- 不许把红绿当作涨跌语义 —— 这里是「危险 / 安全」，全世界的磁盘工具都这么用。
- 不许超过 3 张主图堆在 README 里，加载会变慢。

## 中文图的字体

`Microsoft YaHei` → `PingFang SC` → 无衬线兜底。Windows 上渲染用雅黑，Mac 上自动回落
到苹方。不要在 CSS 里写死只有某一台机器才有的字体。
