# SoC 与 MMIO 寄存器表

所有寄存器均为 32 位、小端。PicoRV32 使用原生 `valid/ready` 存储器接口访问 RAM 和 MMIO。

## 地址空间

| 地址范围 | 部件 | 作用 |
|---|---|---|
| `0x0000_0000–0x0000_FFFF` | 64 KiB RAM | 固件、常量、栈 |
| `0x1000_0000–0x1000_0FFF` | 仿真 tohost | 仅用于 testbench 自检结果 |
| `0x2000_0000–0x2000_0FFF` | UART MMIO | RX/TX FIFO、分频与错误统计 |
| `0x4000_0000–0x4000_0FFF` | 加速器 CSR | 向量、控制、结果和 IRQ |

## UART（基地址 `0x2000_0000`）

| 偏移 | 名称 | 权限 | 说明 |
|---:|---|---|---|
| `0x00` | `CLKDIV` | RW | 每个 UART bit 的系统时钟数；125 MHz/115200 使用 1085 |
| `0x04` | `DATA` | RW | 读：弹出 RX FIFO；空时返回 `0xFFFF_FFFF`。写：压入 TX FIFO；满时总线等待 |
| `0x08` | `STATUS` | RO | bit0 RX空，1 RX满，2 TX空，3 TX满，4溢出，5帧错，6假起始 |
| `0x0C` | `RX_LEVEL` | RO | RX FIFO 当前字节数 |
| `0x10` | `TX_LEVEL` | RO | TX FIFO 当前字节数 |
| `0x14` | `RX_OVERFLOW` | RO | FIFO 满时丢弃的 RX 字节数，饱和计数 |
| `0x18` | `FRAMING_ERRORS` | RO | stop bit 不是高电平的次数，饱和计数 |
| `0x1C` | `FALSE_STARTS` | RO | 起始位中点已恢复高电平的毛刺次数，饱和计数 |
| `0x20` | `CONTROL` | WO | bit0 写 1 清除上述三项错误计数 |

RX/TX FIFO 都是同步 FIFO，因为 UART 核、FIFO 和 PicoRV32 MMIO 都工作在同一个 125 MHz `sysclk`。异步边界只存在于外部 `uart_rx` 管脚，它先经过两级同步器。若未来让 UART 核与总线使用不同的时钟，才需要 Gray 指针的异步 FIFO。

## INT8 加速器（基地址 `0x4000_0000`）

| 偏移 | 名称 | 权限 | 复位值 | 说明 |
|---:|---|---|---:|---|
| `0x00` | `CTRL` | WO | 0 | bit0 写 1 启动；busy 时启动写入被忽略 |
| `0x04` | `STATUS` | RO/W1C | 0 | bit0=`busy`，bit1=`done_pending`；bit1 写 1 清除 |
| `0x08` | `VECTOR_A` | RW | 0 | 四个有符号 INT8，lane0 位于 `[7:0]` |
| `0x0C` | `VECTOR_B` | RW | 0 | 四个有符号 INT8，lane0 位于 `[7:0]` |
| `0x10` | `RESULT` | RO | 0 | 32 位有符号点积结果 |
| `0x14` | `IRQ_ENABLE` | RW | 0 | bit0 为完成中断使能 |
| `0x18` | `IRQ_STATUS` | RO/W1C | 0 | bit0=`done_pending`；写 1 清除 |

标准调用顺序：清旧完成位 → 写 A/B → 启动 → 等待完成 → 读结果 → 清完成位。硬件 `done` 只有一个周期，因此 CSR 把它转换成软件可可靠读取的粘滞 `done_pending`。

当前固件使用轮询。CSR 已产生 `irq`，但 PicoRV32 的 IRQ 功能仍关闭；不能在简历中声称已经完成 CPU 中断驱动。
