# SwiftBar 状态图标

文件使用 `颜色_主题格数.png` 命名，亮色和暗色各一套。PNG 原图为 64 × 36 像素，SwiftBar 以 32 × 18 点显示。

若需要重新生成图标，请在仓库根目录运行：

```bash
clang -fobjc-arc -framework AppKit -framework CoreGraphics make-icons.m -o make-icons
./make-icons icons
```
