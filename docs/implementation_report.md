# 第一阶段实施报告：PicoRV32 与 INT8 点积加速器

> 工程：`<repo-root>`  
> 目标板：PYNQ-Z2 / `xc7z020clg400-1`  
> 工具：Vivado 2024.2 / XSim 2024.2  
> 完成日期：2026-07-15

## 1. 完成结论

约定的前四步已经完成：

1. 将最小可行产品固化为“四路有符号 INT8 点积加速器”。
2. 检查并建立了基于现有 Vivado 2024.2 的可复现仿真、综合环境。
3. 引入 PicoRV32，并通过自检 RV32I程序验证 CPU能够正确执行指令和完成内存写事务。
4. 独立实现加速器 RTL，完成定向、极值、协议、复位和1000组随机测试，并完成 PYNQ-Z2目标器件综合。

最终一键回归结果：

```text
TEST_PASS: PicoRV32 executed RV32I smoke program in 22 cycles
TEST_PASS: int8_dot_accel passed 1007 cases
SYNTH_PASS: int8_dot_accel synthesized for PYNQ-Z2 at 100 MHz
ALL_PASS: PicoRV32 smoke test, accelerator regression, and synthesis
```

当前阶段还没有把加速器连接到 PicoRV32。CSR、AXI/片上总线、地址译码、中断、软件驱动及板级下载是下一阶段内容。先分别证明 CPU与计算核心正确，可以避免集成时同时排查 CPU、总线和算法三类问题。

## 2. 工程检查和环境选择

### 2.1 检查结果

原 Vivado工程是空工程，但板卡配置正确：

```text
BoardPart = tul.com.tw:pynq-z2:part0:1.0
Part      = xc7z020clg400-1
Vivado    = C:\Xilinx\Vivado\2024.2
```

本机可用 Git、Python和 Vivado，但没有发现：

- Verilator
- Icarus Verilog
- Yosys
- RISC-V GCC
- Make

### 2.2 实际采用的方案

没有在第一阶段引入新的系统依赖，而是使用已有的：

- `xvlog`：编译 Verilog/SystemVerilog；
- `xelab`：展开设计；
- `xsim`：运行自检仿真；
- `vivado -mode batch`：独立综合、时序检查和报告生成；
- PowerShell + Tcl：自动化执行。

这样做的原因是：现有工具已经可以完成前四步，减少安装、PATH、版本兼容和 Windows/WSL路径差异造成的额外故障。后续建设开源 CI时，再加入 Verilator、cocotb和 Yosys更合适。

## 3. PicoRV32 基础仿真

### 3.1 使用的版本

PicoRV32来自 `YosysHQ/picorv32`，当前检出提交为：

```text
87c89acc18994c8cf9a2311e871818e87d304568
```

源码位置：

```text
external/picorv32/picorv32.v
```

### 3.2 测试方法

测试平台 `tb/tb_picorv32_smoke.sv`提供：

- 时钟与复位；
- 256×32位简单存储器；
- PicoRV32原生 `mem_valid/mem_ready`存储器握手；
- 超时和异常自检；
- 一个无需交叉编译器的最小 RV32I程序。

程序内容等价于：

```asm
addi x1, x0, 5
addi x2, x0, 7
add  x3, x1, x2
sw   x3, 0x100(x0)
jal  x0, 0
```

testbench检查 CPU是否向 `0x0000_0100`写入十进制12。实际在22个仿真周期内完成。

### 3.3 为什么使用手工编码程序

当前机器没有 RISC-V GCC。为了把“CPU RTL/握手是否能运行”和“软件工具链是否安装”解耦，第一阶段直接在 testbench中放入五条已编码指令。

它的优点是：

- 无外部编译依赖；
- 测试规模小，波形容易阅读；
- 可以明确观察取指、执行和 store事务；
- 出错时定位范围非常小。

它的限制是不能替代真正的软件流程。下一阶段应安装 `riscv32-unknown-elf-gcc`或兼容工具链，增加启动代码、链接脚本、C驱动和 ELF/HEX加载。

## 4. INT8 加速器设计

### 4.1 算法

加速器计算四个有符号 INT8元素的点积：

```text
result = a0*b0 + a1*b1 + a2*b2 + a3*b3
```

`vector_a[7:0]`和`vector_b[7:0]`是 lane 0，其余 lane依次向高位排列。

### 4.2 微架构

```text
start/输入锁存
       ↓
四路并行 8×8 有符号乘法
       ↓
每个乘积扩展到32位后累加
       ↓
result寄存器 + done单周期脉冲
```

接口采用简单的 `start/busy/done`协议：

- 仅当 `busy=0`时接受 `start`；
- 运算期间 `busy=1`；
- busy期间再次出现的 `start`被忽略；
- 结果写入时 `done`拉高一个周期，并清除 `busy`。

### 4.3 关键实现决定

#### 计算核心与总线解耦

`rtl/int8_dot_accel.sv`只包含计算与请求协议，不包含 AXI和 CSR。

原因是计算错误与总线错误的排查方式不同。分层以后可以：

- 单独复用计算核心；
- 独立验证 AXI从机；
- 更换 PicoRV32原生总线、AXI4-Lite或 PCPI而不修改算术逻辑；
- 避免一个巨大状态机同时处理乘法、寄存器和总线握手。

#### 所有输入按有符号 INT8处理

代码在锁存时显式使用 `$signed`，避免 `8'hff`被当作255而不是-1。

#### 乘积先符号扩展再累加

每个乘积为16位。如果直接把多个16位表达式相加，表达式可能在扩展到32位结果之前发生中间溢出。实现先把每个乘积符号扩展到32位，再执行求和。

#### 当前固定为四路

第一阶段固定四路可以让接口、波形和边界条件保持清晰。参数化 lane数量是合理的后续优化，但现在就参数化会同时引入结果位宽推导、循环边界和不同配置回归，扩大第一阶段验证面。

## 5. 验证策略和结果

`tb/tb_int8_dot_accel.sv`包含自计算参考模型，不依赖人工查看波形。

### 5.1 定向测试

覆盖：

- 全零；
- 全1；
- 正负混合；
- `-128 × -128`最大正向极值；
- `-128 × 127`负向极值；
- busy期间重复 start；
- 运算过程中复位；
- 复位后重新提交任务。

### 5.2 随机测试

额外生成1000组随机的32位 `vector_a/vector_b`，testbench逐 lane转为有符号8位，计算软件参考值并与 RTL结果比较。

总通过数为1007：

```text
TEST_PASS: int8_dot_accel passed 1007 cases
```

### 5.3 为什么不只看波形

波形适合定位失败原因，但不适合证明大量输入正确。自检回归有以下优点：

- 失败时立即给出输入、期望值和实际值；
- 可以重复执行；
- 可以进入 CI；
- 修改流水线后可快速发现回归；
- 简历和面试中有可量化的验证结果。

## 6. 综合与时序结果

目标器件为 PYNQ-Z2 的 `xc7z020clg400-1`，采用100 MHz独立时钟约束。

### 6.1 资源利用率

| 资源 | 使用 | 器件总量 | 占比 |
|---|---:|---:|---:|
| Slice LUT | 295 | 53,200 | 0.55% |
| Slice Register | 150 | 106,400 | 0.14% |
| Block RAM Tile | 0 | 140 | 0.00% |
| DSP | 0 | 220 | 0.00% |

Vivado当前把四个8×8乘法器实现成 LUT逻辑，没有使用 DSP48。这不是功能错误，而是综合器针对较小乘法位宽做出的资源选择。

### 6.2 时序

```text
目标周期：10.000 ns（100 MHz）
WNS：+4.293 ns
结论：All user specified timing constraints are met.
```

这表示独立综合网表在当前估算下满足100 MHz，并有正的建立时间裕量。

### 6.3 报告中的预期警告

报告存在以下警告，均来自“只综合独立加速器、尚未集成完整 Zynq顶层”这一事实：

- `HD.CLK_SRC`未设置：独立 OOC模块不知道最终顶层时钟缓冲位置；
- DRC只执行了适用于 OOC设计的部分连接检查；
- `ZPS7-1 PS7 block required`：Zynq最终可下载设计需要 Processing System 7实例；
- 设计太小，不满足 Vivado并行综合条件。

这些警告不能在当前 OOC阶段通过随意指定引脚或伪造 PS7实例来“消除”。下一阶段构建 PYNQ-Z2完整 SoC顶层、实例化 PS7/时钟或纯 PL系统外壳之后，应重新运行实现和最终 DRC。

## 7. 自动化与工程组织

新增内容：

```text
project_1/
├── rtl/
│   └── int8_dot_accel.sv
├── tb/
│   ├── tb_int8_dot_accel.sv
│   └── tb_picorv32_smoke.sv
├── constraints/
│   └── int8_dot_accel.xdc
├── external/
│   └── picorv32/
├── scripts/
│   ├── add_sources_to_project.tcl
│   ├── run_accel_sim.ps1
│   ├── run_picorv32_smoke.ps1
│   ├── run_synth.ps1
│   ├── synth_accel.tcl
│   └── run_all.ps1
├── docs/
│   ├── design_spec.md
│   └── implementation_report.md
├── README.md
└── .gitignore
```

RTL、加速器 testbench和 XDC已经登记到 `build/vivado_project/picorv32_int8_accelerator.xpr`：

- Design Sources顶层：`int8_dot_accel`
- Simulation Sources顶层：`tb_int8_dot_accel`
- Constraints：`int8_dot_accel.xdc`

PicoRV32烟雾测试独立运行，避免把 CPU和加速器两个顶层混入同一个默认仿真集。

## 8. 如何重新运行

### 8.1 一键验证

在 `<repo-root>`运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\run_all.ps1 `
  -VivadoBin C:\Xilinx\Vivado\2024.2\bin
```

这会依次执行：

1. PicoRV32烟雾测试；
2. 加速器1007例回归；
3. PYNQ-Z2目标综合和时序检查。

### 8.2 单独运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_picorv32_smoke.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_accel_sim.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synth.ps1
```

### 8.3 输出位置

```text
build/sim_picorv32/picorv32_xsim.log
build/sim_accel/accel_xsim.log
build/synth_accel/utilization.rpt
build/synth_accel/timing_summary.rpt
build/synth_accel/drc.rpt
build/synth_accel/int8_dot_accel_synth.dcp
```

## 9. 替代方案及取舍

### 9.1 Ibex代替 PicoRV32

Ibex的 SystemVerilog编码、配置与验证成熟度更接近工业级 CPU项目，但依赖和工程规模更大。第一阶段采用 PicoRV32是为了更快理解取指、存储器握手和 SoC集成。等总线与软件链路跑通后，可以将同一个加速器接入 Ibex作为升级项目。

### 9.2 PCPI自定义指令代替内存映射加速器

PicoRV32提供 PCPI协处理器接口，可以把点积做成自定义指令：

- 优点：控制开销小，CPU调用简单；
- 缺点：与 PicoRV32绑定较紧，不能自然展示 CSR、AXI和 DMA。

目标简历项目强调 SoC总线与软件驱动，因此后续优先使用 memory-mapped CSR/AXI；PCPI适合作为性能对比扩展。

### 9.3 ARM PS控制加速器

PYNQ-Z2本身带 Cortex-A9，可以直接通过 PS-PL AXI控制加速器：

- 优点：容易使用 DDR、Linux和 Python；
- 缺点：项目会变成 ARM/Zynq加速系统，而不是 RISC-V SoC。

建议保留为第二条演示路径：同一个加速器分别由 PicoRV32和 ARM PS控制，比较软件栈与数据通路。

### 9.4 cocotb代替 SystemVerilog testbench

cocotb适合用 Python实现参考模型、随机激励和 CI；当前使用 SystemVerilog testbench是因为 XSim已经安装且没有额外依赖。加速器扩展到矩阵、卷积后，Python/Numpy参考模型会更方便，届时引入 cocotb更有价值。

### 9.5 Verilator/Icarus代替 XSim

开源仿真器更适合 GitHub Actions和无 Vivado环境的复现。XSim的优势是与当前 PYNQ-Z2/Vivado工程完全一致。较好的后续方案不是二选一，而是：

- 本机使用 XSim和 Vivado综合；
- CI使用 Verilator进行快速回归；
- 两套仿真共用相同测试向量或参考模型。

### 9.6 强制使用 DSP48

可以使用综合属性或重构算术表达式，尝试让四个乘法映射到 DSP48：

- 优点：节省 LUT，通常更利于高频；
- 缺点：消耗 DSP资源，小位宽乘法不一定更划算。

当前保留 Vivado自动选择的 LUT实现，作为基线。下一阶段应分别综合“自动/LUT”和“强制DSP”版本，用真实的 LUT、DSP、WNS和功耗数据决定，而不是先凭经验强制一种实现。

## 10. 为什么当前方案更适合作为第一阶段

当前方案的优势不在于功能最多，而在于形成了四个闭环：

1. **规格闭环**：算法、位宽、协议和验收条件已经写清楚；
2. **CPU闭环**：PicoRV32能真实执行指令并完成存储事务；
3. **RTL闭环**：加速器在边界、协议、复位和随机输入下自检通过；
4. **实现闭环**：代码已针对目标器件综合，有真实面积和时序数据。

如果一开始直接加入 AXI、DMA、Linux和 FPGA下载，出错时很难判断问题位于算法、握手、地址映射、软件缓存还是板级配置。当前分层方法把每类问题限定在小范围内，同时保留后续扩展到完整简历项目的路径。

## 11. 推荐的下一阶段

按以下顺序继续：

1. 为加速器增加 CSR寄存器模块和明确的地址映射；
2. 单独实现并验证总线从机，重点测试背压和读写通道不同步；
3. 构建 PicoRV32 + BRAM + 地址译码 + 加速器的 SoC顶层；
4. 安装 RISC-V GCC，加入启动代码、链接脚本和 C驱动；
5. 将轮询完成升级为中断；
6. 完成 PYNQ-Z2顶层时钟/复位、实现、bitstream和板级验证；
7. 比较 CPU软件点积与硬件点积的周期数；
8. 再扩展为参数化向量或矩阵加速器。

