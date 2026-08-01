# INT8 加速器 CSR 寄存器表

SoC中的加速器基地址为：

```text
0x4000_0000
```

所有寄存器均为32位，小端。当前总线使用 PicoRV32原生 `valid/ready` MMIO协议。

| 偏移 | 名称 | 权限 | 复位值 | 说明 |
|---:|---|---|---:|---|
| `0x00` | `CTRL` | WO | 0 | bit0写1启动；busy时写入被忽略 |
| `0x04` | `STATUS` | RO/W1C | 0 | bit0=`busy`，bit1=`done_pending`；bit1写1清除 |
| `0x08` | `VECTOR_A` | RW | 0 | 四个有符号INT8，lane0位于`[7:0]` |
| `0x0c` | `VECTOR_B` | RW | 0 | 四个有符号INT8，lane0位于`[7:0]` |
| `0x10` | `RESULT` | RO | 0 | 32位有符号点积结果 |
| `0x14` | `IRQ_ENABLE` | RW | 0 | bit0为完成中断使能 |
| `0x18` | `IRQ_STATUS` | RO/W1C | 0 | bit0=`done_pending`；写1清除 |

## 调用顺序

```text
1. IRQ_STATUS写1，清除旧完成状态
2. 写VECTOR_A
3. 写VECTOR_B
4. CTRL.bit0写1
5. 轮询STATUS.bit1
6. 读取RESULT
7. IRQ_STATUS.bit0写1清除完成状态
```

核心的 `done`只有一个周期，软件无法可靠直接采样。因此 CSR包装器把它转换为 `done_pending`粘滞位，直到软件通过W1C明确清除。

## 字节写

`VECTOR_A`与`VECTOR_B`支持四位 byte strobe，未选中的字节保持原值。其他可写寄存器仅使用最低字节。

## 中断

```text
irq = IRQ_ENABLE.bit0 && done_pending
```

当前 SoC固件使用轮询以简化第一个端到端闭环，IRQ已经由 CSR模块输出，但尚未连接到 PicoRV32自定义中断入口。

