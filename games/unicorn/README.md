# 圣兽之王：macOS ARM64 原生运行

基于 MacNativeGames 的 Bayonetta 3 运行层建立独立副本。当前输入为
`010054B01AD92000` 的 **1.05（本体＋v262144 更新）与两个 DLC**，运行 `main` 和 `sdk`
两个 ARM64 模块。数字美术集属于独立应用，没有加入；尚未验证完整流程。

## 本机启动

双击 `/Users/yangjiawang/game/圣兽之王.app`。App 引用
`games/unicorn/UNICORN_build-1.05` 中的原生程序、重写模块和资源，请保留工作目录。
每次启动的日志为 `UNICORN_build-1.05/boot.log`。
旧版保留为 `圣兽之王 1.0.0.app`，仍使用 `UNICORN_build`。新版存档从旧版复制，之后各自独立。

| 键盘 | 游戏手柄 |
| --- | --- |
| J / K | A 确认 / B 返回 |
| I / U | X / Y |
| W A S D | 左摇杆 |
| T G F H | 方向键：上、下、左、右 |
| Return / Tab | + / − |
| Q / E | L / R |
| Option / Shift | ZL / ZR |
| 1 | 显示或隐藏性能与快捷键提示 |

## 使用现有本机数据重新构建

需要 Apple silicon、macOS 26 SDK、Command Line Tools、Homebrew 的 `opus` 和 `libvpx`。
Python 环境位于本机 `TOTK_build/venv`；游戏文件和生成文件均被 Git 忽略。

```sh
cd /Users/yangjiawang/game/games/unicorn
make prepare PY=/Users/yangjiawang/game/TOTK_build/venv/bin/python
make -j8 runtime shader-tools app
```

`assets/expected-v1.05.json` 固定更新后的 ExeFS、重写模块、RomFS 和两个 DLC 的校验值。
准备脚本拒绝不匹配的数据。首次构建 SPIRV-Cross 会使用 Makefile 固定的上游提交。

更新通过 `scripts/extract_exefs.py --update` 提取代码，`scripts/merge_romfs.py` 合并资源。
合并结果的六层 IVFC 全部通过校验，控制数据中的显示版本确认为 1.05。
两个 DLC 经 `scripts/extract_addons.py` 核验，编号为 1、2；其资源区都只有零字节占位文件。
游戏只导入 `ListAddOnContent` 查询编号，运行层验证 DLC 镜像后返回实际安装的两个编号，
由原游戏解锁本体中的内容。没有新增游戏未调用的资源挂载接口。

## 适配与验证

- 支持本体 SDK 请求的文件系统初始化、随机数服务及主模块 BSS 栈映射。
- SDK 弱 C++ 分配器符号服从主模块的强定义，避免分配与释放使用不同分配器。
- Opus 多流音频使用系统侧 libopus 实现；六声道编码、独立解码对照和错误输入检查通过。
- NVN 四边形、三角扇展开为 Metal 三角形；修复启动画面被跳过的问题。
- 客体 GPU 地址按 64 KiB 分配，并在录制时转换为 CPU 存储地址；修复新游戏的
  128 MiB 池因 CPU/GPU 对齐不同而耗尽的问题。没有扩大游戏的缓冲池。

1.05 的验证记录位于 `UNICORN_build-1.05/logs/`：两个模块结构检查通过，
新版 main 的 3264 个改写点无语义偏差，50 个注入错误全部被检出；源码测试共 256 项，1 项跳过，其余通过。
实际启动已确认标题、键盘确认与中文开场剧情；游戏已查询并收到两个 DLC 编号。
DLC 的后续纹章选择、完整战斗及存档重载尚未验证。
`probe-addons` 已验证镜像哈希、列表分页与输出边界；损坏或缺失 DLC 的负向检查也已通过。

1.0.0 的重写校验记录保留在 `UNICORN_build/struct-main.log`、`struct-sdk.log`、
`equiv-main.log`、`equiv-sdk.log`：两个模块均无结构违规和语义偏差，注入错误全部被检出。
运行时回归记录为 `probe-memory-final.log`、`probe-opus-final.log`、
`probe-gpu-address-final.log`，均在工作目录中。

```sh
cd /Users/yangjiawang/game/games/unicorn/UNICORN_build-1.05
./build/unicorn-native rewritten/v262144 probe-addons
```

旧版运行时回归命令：

```sh
cd /Users/yangjiawang/game/games/unicorn/UNICORN_build
./build/unicorn-native rewritten/v0 probe-memory
./build/test-opus-multistream
./build/unicorn-native rewritten/v0 probe-gpu-address
```

独立 GPU 探针与游戏共用单实例锁，运行探针前应先退出游戏。
复制自上游的完整 `probe-gfx` 在管线预测探针处崩溃，未计为通过；其日志保留为
`probe-gfx-final.log`。实际游戏启动与画面检查另行进行，不能用探针结果替代。
