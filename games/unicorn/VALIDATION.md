# 圣兽之王 Mac 验证记录

环境：Apple M5、16 GiB、macOS 26.4。仅验证 macOS ARM64；没有构建或测试 iOS。
版本：亚洲版 `010054B01AD92000`，1.05 / v262144；DLC `010054B01AD93001`、`010054B01AD93002`。
本轮工作在 `codex/unicorn-pr-readiness`，基于上游 `a988b5e`；尚未创建或推送 PR。

## 2026-10-23：干净构建与回归

在新的 `UNICORN_build-1.05/pr-validation/clean` 内，从原始本体、更新、两个 DLC 的 NSP 开始，
重新提取 ExeFS、合并 RomFS、提取 DLC、改写 main/sdk、生成运行表并编译 App。
未复制旧的提取数据、改写模块、原生目标文件或着色器缓存；使用本机已有 Python 依赖和 Homebrew 库。
SPIRV-Cross 从 Makefile 固定的提交重新获取并编译。首次网络请求在沙箱内失败，在允许网络访问后完成。

| 检查 | 结果 | 范围 |
|---|---|---|
| 本体＋更新 RomFS | 通过 | 六层 IVFC；3,591,689,668 字节，SHA-256 与 expected-v1.05.json 相同 |
| main/sdk 改写 | 通过 | 全新输入重新生成，结构检查通过，准备阶段固定哈希匹配 |
| DLC 提取和查询 | 通过 | 六层 IVFC、镜像与包哈希、编号 1/2、分页与边界 |
| App 构建与签名 | 通过 | `make runtime shader-tools app`、`codesign --verify --deep --strict` |
| 根目录源码测试 | 通过 | 303 项，跳过 1 项，其余通过；不是游戏完整性测试 |
| Opus 多流 | 通过 | `make test-opus`，六声道 PCM 对照、final range、reset、截断包拒绝 |
| 内存探针 | 通过 | 新构建 1.05 的 `TOTK_HEADLESS=1 ... probe-memory` |
| CPU 图形探针 | 通过 | `TOTK_HEADLESS=1 ... probe-gfx`，对象布局、录制、预测状态；不代表 GPU 画面通过 |
| 图形负对照 | 符合预期 | `TOTK_PROBE_NEGATIVE=24/26/27` 分别拒绝错误变体、未翻译阶段和缺深度的猜测 |
| NSZ 命令 | 通过 | 一个 DLC 从原始 NSZ 转换后，NSP SHA-256 与已验证输入一致；未将此次小包验证冒充完整本体解压 |

构建文档现显式设置 `DM_ROOT` 和 `LLVM_BIN`，让结构检查缓存留在工作目录内，并列出 LLVM 依赖。
指纹记录于 `clean/build-inputs.sha256`。源码、生成文件、游戏和日志始终分开；原始文件不会被修改。

## 图形探针崩溃的原因

原探针 `dm_nvn_probe_prediction` 构造了 `nstage=1`、control 指针为空的模拟程序。
Bayonetta 3 的分阶段绑定路径会在检查翻译缓存前读取 `control+0x714` 的阶段编号，
因此探针在地址 `0x714` 处触发 SIGSEGV。命令
`TOTK_HEADLESS=1 ./build/unicorn-native rewritten/v262144 probe-gfx` 在修复前退出 139，
符号化栈为 `state_op → pso_predict_rest → dm_nvn_probe_prediction`。

修复只给测试程序补上有效的零初始化顶点 control 元数据；保留“程序未翻译”的缓存状态及全部断言，
没有跳过预测检查或给生产读取增加空指针兜底。相同命令退出 0，三个语义破坏负对照仍退出 134 并报告对应错误。
该修复仅位于本游戏的独立副本。

## 实际游玩与温控

测试使用原 profile 的独立副本，开始前记录原 profile 各文件的 SHA-256。
已从新游戏进入雨夜教程战场，选择伊蕾妮雅队、下达移动和进攻指令，并实际观察到交战后的 WIN 画面，
人物、雨景和结算画面可见；不是完整教程或完整画面对照。保存和新进程重读尚未验证，不能以文件系统探针替代。
测试期间 Mac 自动锁定，窗口捕获明确返回锁屏错误，后续交互在等待解锁。
1.05 标题、中文开场和 DLC 编号查询已经验证；DLC 纹章菜单仍未验证。

按用户选择先进行温度监测和提醒，再决定控制策略。检测器放在仓库外部提交范围的本地工具目录，
不加入游戏运行层依赖。CPU/GPU 平均传感器温度、整机功耗与系统热压力分开记录；
短时间采样不能证明持续游玩达到热平衡，也不能由 GPU 频率单独判定热降频。

独立 macmon 0.10.0 已在本机读到有效 CPU/GPU 摄氏度和功耗；一次 12 样本、每样本约 2 秒的
保活开启记录，平均 CPU 61.62°C、GPU 66.48°C，GPU 3.47 W、整机 16.20 W。
另一次关闭保活的探索记录为 CPU 62.18°C、GPU 64.06°C，GPU 1.71 W、整机 15.80 W。
两段采样的场景稳定性、后台负载和窗口可见性尚未形成完整对照记录，不能据此宣布降温或提帧成功；
它们证明传感器与现有 `keepalive_us` 测试开关可用。没有修改正式启动默认值或加入自动温控。
一次 Foundation `ProcessInfo.thermalState` 读取为 0（nominal）；这是热压力分级，不是摄氏度。
检测器对阈值触发、重复提醒抑制、降温 3°C 后恢复提醒、缺失传感器和 JSONL 输出的检查通过。

证据保存在被忽略的 `UNICORN_build-1.05/pr-validation/`：`clean/`、`source-tests.log`、
`test-opus.log`、`probe-gfx-after.log`、`probe-gfx-negative*.log`、`probe-addons-clean.log`。
旧版 1.0.0 的记录仍保留，但当前源码固定为 1.05，不能把旧二进制留存称作当前源码支持两版。
