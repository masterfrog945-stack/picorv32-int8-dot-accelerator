# 第5～7步实施报告

> 工程：`<repo-root>`  
> 目标器件：PYNQ-Z2 / `xc7z020clg400-1`  
> 完成日期：2026-07-15

## 1. 完成结论

第5～7步已经形成完整、可重复执行的闭环：

```text
SystemVerilog断言与覆盖
        ↓
计算核心自检
        ↓
CSR/MMIO寄存器自检
        ↓
RISC-V GCC编译裸机C程序
        ↓
PicoRV32执行固件并访问加速器
        ↓
软件参考值与硬件结果比较
        ↓
tohost写入PASS
        ↓
完整SoC综合与时序报告
```

关键结果：

```text
COVERAGE_PASS: 8/8 functional coverage goals hit
TEST_PASS: int8_dot_accel passed 1007 cases
TEST_PASS: accel_csr passed 203 MMIO operations
TEST_PASS: PicoRV32 C firmware called INT8 accelerator successfully in 59172 cycles
SOC_SYNTH_PASS: PicoRV32 accelerator SoC synthesized at 100 MHz
```

## 2. 安装的编译环境

安装了官方 xPack GNU RISC-V Embedded GCC：

```text
版本：15.2.0-1
GCC：riscv-none-elf-gcc 15.2.0
位置：.tools\riscv-none-elf-gcc\xpack-riscv-none-elf-gcc-15.2.0-1
```

安装采用便携ZIP解压，没有修改系统PATH。项目脚本显式引用工具链位置，原因是：

- 不影响电脑上其他编译环境；
- 版本固定，结果更可复现；
- 删除工具目录即可卸载；
- 避免Vivado、WSL和Windows PATH之间的版本冲突。

固定版本安装脚本为：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\install_riscv_toolchain.ps1
```

脚本会校验官方压缩包SHA-256：

```text
85EF714DACD273B1DADF4AF4892774520AC01915BFA6DA816A56E7E41591E09E
```

官方安装说明：<https://xpack-dev-tools.github.io/riscv-none-elf-gcc-xpack/docs/install/>

本阶段没有安装 Verilator、Icarus和Yosys，因为 Vivado/XSim已经能完成所有需要的仿真、断言、综合和时序检查。后续建设跨平台CI时再安装这些工具更有价值。

## 3. 第5步：断言、覆盖与回归强化

### 3.1 新增SVA

`tb/int8_dot_assertions.sv`检查：

1. 空闲时接受的请求必须按固定延迟完成；
2. `done`只能保持一个周期；
3. `done`有效时必须已经退出busy；
4. 运算期间`result`保持稳定；
5. 复位必须清除`busy/done`。

断言与 DUT分离，计算核心中没有验证专用代码。这样同一个 RTL可以用于综合、独立验证和SoC集成。

### 3.2 功能覆盖目标

testbench维护八类显式覆盖计数：

- 零结果；
- 正结果；
- 负结果；
- 输入包含 `-128`；
- 输入包含 `127`；
- 正负混合输入；
- busy期间重复start；
- 运算期间复位。

回归结束时任何目标未命中都会 `$fatal`。实际结果：

```text
COVERAGE_PASS: 8/8 functional coverage goals hit
```

这里统计的是需求导向的功能覆盖目标，不等同于商业工具产生的行覆盖、分支覆盖或toggle覆盖。后续若需要签核式覆盖率，应加入代码覆盖数据库与覆盖率合并流程。

### 3.3 发现并修正的问题

第一次加入SVA时，完成延迟属性少计算了一个SVA采样点。RTL在上升沿NBA阶段更新`done`，属性要到下一采样点才能看到新值。修正后，断言与接口实际可观察时序一致。

这说明断言并非装饰：它迫使设计者精确定义“内部寄存器更新时刻”和“外部观察时刻”。

## 4. 第6步：CSR与MMIO接口

### 4.1 模块结构

```text
accel_csr
├── PicoRV32风格 valid/ready MMIO接口
├── CSR寄存器
├── done_pending粘滞状态
├── IRQ生成
└── int8_dot_accel计算核心
```

完整寄存器说明见 [register_map.md](register_map.md)。

### 4.2 为什么使用原生MMIO而不是立即实现AXI

PicoRV32的原生接口只有：

```text
valid, ready, addr, wdata, wstrb, rdata
```

它足以正确表达内存映射寄存器访问，并能让第7步尽快完成CPU闭环。AXI4-Lite有五个独立通道，地址与数据可以不同周期到达；如果此时同时加入AXI、CPU、固件和算法，失败定位范围会显著扩大。

当前选择不是放弃AXI，而是先固定一个经过验证的CSR核心。后续AXI4-Lite包装器只需要把AXI事务转换为当前本地请求，不需要改动寄存器和计算逻辑。

### 4.3 CSR自检内容

`tb/tb_accel_csr.sv`验证：

- 四字节独立写使能；
- 未映射地址读取返回0；
- 输入寄存器读写；
- 启动与busy状态；
- 软件轮询`done_pending`；
- 结果读取；
- IRQ使能与产生；
- W1C清除IRQ和完成状态；
- 3组定向与200组随机MMIO计算。

结果：

```text
TEST_PASS: accel_csr passed 203 MMIO operations
```

## 5. 第7步：PicoRV32 SoC与C固件

### 5.1 SoC结构

```text
PicoRV32 RV32I
      │ 原生memory bus
      ▼
地址译码
 ├── 0x0000_0000：64 KiB RAM
 ├── 0x1000_0000：tohost测试设备
 └── 0x4000_0000：INT8加速器CSR
```

新增RTL：

- `simple_ram.sv`：支持字节写的64 KiB单端口RAM；
- `soc_test_device.sv`：接收固件最终PASS/FAIL码；
- `picorv32_accel_soc.sv`：CPU、地址译码和从设备集成。

### 5.2 固件构建

新增软件：

```text
sw/start.S       复位入口、栈初始化、调用main、写tohost
sw/linker.ld     64 KiB RAM链接布局
sw/accel.h       驱动声明
sw/accel.c       volatile MMIO驱动
sw/main.c        软件参考模型和软硬件比较
```

编译选项采用：

```text
-march=rv32i
-mabi=ilp32
-ffreestanding
-nostdlib
-nostartfiles
```

编译结果：

| 区域 | 大小 |
|---|---:|
| text | 576 bytes |
| data | 0 |
| bss | 0 |
| 总计 | 576 bytes |

`scripts/bin_to_hex.py`把小端二进制转换为每行一个32位字的`firmware.hex`，供 `$readmemh`加载。

### 5.3 软件测试内容

固件执行：

- 5组定向测试；
- 16组xorshift伪随机测试；
- 每组都由 C软件参考模型计算期望值；
- 通过MMIO配置并启动硬件；
- 轮询完成状态；
- 读取硬件结果并比较；
- 任一失败返回带测试编号的`0xbadxxxxx`诊断码；
- 全部通过返回1。

启动代码把main返回值写到 `0x1000_0000`。testbench只有看到真实CPU store事务写入1才判定PASS。

结果：

```text
TEST_PASS: PicoRV32 C firmware called INT8 accelerator successfully in 59172 cycles
```

### 5.4 完整SoC综合

PYNQ-Z2目标、100 MHz约束下：

| 资源 | 使用 | 总量 | 占比 |
|---|---:|---:|---:|
| Slice LUT | 1,276 | 53,200 | 2.40% |
| Slice Register | 812 | 106,400 | 0.76% |
| Block RAM Tile | 16 | 140 | 11.43% |
| DSP | 0 | 220 | 0.00% |

时序：

```text
目标周期：10.000 ns
WNS：+3.495 ns
结论：All user specified timing constraints are met.
```

64 KiB RAM映射为16个 RAMB36E1。四路8×8乘法仍由Vivado自动映射到LUT，没有强制占用DSP。

## 6. 一键执行

在工程根目录运行：

```powershell
cd <repo-root>

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_all.ps1 `
  -VivadoBin C:\Xilinx\Vivado\2024.2\bin
```

它依次执行：

1. PicoRV32最小指令烟雾测试；
2. 带SVA和覆盖目标的核心回归；
3. CSR/MMIO回归；
4. 固件编译和SoC端到端仿真；
5. 独立计算核心综合；
6. 完整SoC综合。

单独运行：

```powershell
.\scripts\run_accel_sim.ps1
.\scripts\run_csr_sim.ps1
.\scripts\build_firmware.ps1
.\scripts\run_soc_sim.ps1
.\scripts\run_soc_synth.ps1
```

若PowerShell限制脚本执行，使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <脚本路径>
```

这只影响该次子进程，不修改系统执行策略。

## 7. Vivado GUI中的仿真集

工程已经创建三个仿真集：

| 仿真集 | 顶层 | 用途 |
|---|---|---|
| `sim_1` | `tb_int8_dot_accel` | 核心、SVA和覆盖目标 |
| `sim_csr` | `tb_accel_csr` | CSR/MMIO接口 |
| `sim_soc` | `tb_picorv32_accel_soc` | C固件端到端SoC |

在Vivado的 Sources窗口切换 Simulation Sources下拉框，选择需要的仿真集，再执行 Behavioral Simulation。

`sim_soc`已经通过Vivado工程模式实际验证，工具能够自动把`firmware.hex`暂存到XSim运行目录；启动后在Tcl Console执行`run all`即可得到端到端PASS。

## 8. 替代方案与取舍

### 8.1 AXI4-Lite

更通用，也适合未来接PYNQ的ARM PS。当前先使用原生MMIO是为了降低首次CPU集成风险。推荐下一阶段增加AXI4-Lite适配器，并重点验证AW/W独立到达、读写背压和响应保持。

### 8.2 PCPI自定义指令

可以把点积变成PicoRV32自定义指令，调用延迟更低；但与特定CPU耦合，并绕过CSR和SoC总线学习目标。适合后续作为性能对比，不适合替代当前memory-mapped基线。

### 8.3 ARM PS控制

PYNQ-Z2的Cortex-A9可通过PS-PL AXI直接控制加速器，方便使用Linux、DDR和Python；但项目将变成ARM/Zynq加速系统，而不是RISC-V SoC。建议保留同一计算核心，后续增加第二种控制路径。

### 8.4 Verilator + cocotb

更适合开源CI和复杂Python参考模型。当前XSim可以同时支持SVA、现有Vivado工程和目标器件综合，减少工具差异。矩阵/卷积扩展时再引入NumPy/cocotb更划算。

### 8.5 轮询与中断

当前CSR已经生成IRQ，但固件使用轮询。原因是PicoRV32的IRQ机制包含自定义指令和固件处理流程；先验证MMIO和计算闭环更容易定位问题。下一阶段可启用`ENABLE_IRQ`，加入中断入口和ISR，并测量轮询与中断的CPU开销。

## 9. 尚未包含的板级工作

当前完成到“可综合SoC + 真实固件仿真”，尚未生成可下载bitstream。PYNQ-Z2是Zynq器件，最终板级设计还需：

- 实例化Processing System 7；
- 配置并输出PL时钟；
- 加入Processor System Reset；
- 选择BRAM固件初始化方式；
- 用LED、UART或ILA提供板上可见结果；
- 完成Implementation、最终STA、DRC和bitstream。

当前DRC中的 `ZPS7-1 PS7 block required`正是因为这里只进行了PL SoC的out-of-context综合。它不是本次RTL功能错误，也不能通过伪造约束合理消除。
