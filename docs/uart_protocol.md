# UART 帧协议与测试方法

## 1. 为什么不再使用裸回显

裸回显只能证明“某些字节能来回传输”，无法区分命令、向量、结果和错误，也无法发现插入/丢失一个字节后剩余数据整体错位。当前协议增加长度、序号和 CRC，使故障可以被检测并定位。

## 2. 帧格式

所有多字节整数均为小端。

| 字段 | 字节数 | 说明 |
|---|---:|---|
| Magic | 2 | 固定 `A5 5A` |
| Version | 1 | 当前为 `01` |
| Command | 1 | 响应为 `请求命令 | 0x80` |
| Sequence | 1 | 主机递增，响应必须原样返回 |
| Payload length | 2 | 小端，固件最大 64 |
| Payload | N | 命令数据；响应的第一个字节总是 status |
| CRC16 | 2 | 对 Version 到 Payload 计算，低字节先发 |

CRC 算法为 CRC-16/CCITT-FALSE：初始值 `0xFFFF`，多项式 `0x1021`，不反射，无最终异或。Magic 不参与 CRC，便于接收端先搜索边界。

## 3. 命令

| 命令 | 名称 | 请求 payload | 成功响应数据（status 之后） |
|---:|---|---|---|
| `0x01` | PING | 无 | ASCII `PONG` |
| `0x02` | GET_INFO | 无 | 版本、lane 数、位宽、125 MHz 时钟 |
| `0x03` | ECHO | 任意 0–64 字节 | 原数据 |
| `0x10` | DOT4_ACCEL | A 的 4 个 INT8 + B 的 4 个 INT8 | `int32 result` + `uint32 cycles` |
| `0x11` | DOT4_CPU | 同上 | PicoRV32 C 结果 + 周期 |
| `0x20` | GET_STATS | 无 | overflow/framing/false-start 计数和 FIFO level |
| `0x21` | CLEAR_STATS | 无 | 清除 UART 错误计数 |

状态码：`0` 成功，`1` 版本错误，`2` 长度错误，`3` CRC 错误，`4` 未知命令，`5` 加速器超时。

## 4. DOT4 数据含义

请求的前 4 字节是 `a[0..3]`，后 4 字节是 `b[0..3]`，每个字节都按补码解释为 `-128..127`：

```text
result = a0*b0 + a1*b1 + a2*b2 + a3*b3
```

例如：

```text
[1, -2, 3, -4] · [5, 6, 7, 8]
= 1*5 + (-2)*6 + 3*7 + (-4)*8
= -18
```

四项乘积的极值仍远小于 32 位范围，因此 Python、PicoRV32 C 和 RTL 必须逐位完全相等，不使用浮点容差。

## 5. Python 脚本如何验证

`scripts/uart_echo_test.py` 的 `dot4` 模式执行：

1. PING 确认协议在线；
2. 运行全零、全 127、全 -128、正负混合等边界向量；
3. 用固定 seed 生成随机 INT8 向量；
4. Python 用整数运算生成黄金结果；
5. 发送 `DOT4_ACCEL`，比较硬件结果并记录 `rdcycle`；
6. 对前 `--cpu-samples` 组再运行 `DOT4_CPU`，三方交叉比较；
7. 发送未知命令和故意破坏的 CRC，确认固件拒绝；
8. 读取 UART 错误计数；
9. 可把全部指标保存为 JSON。

`Driver speedup` 比较的是两条固件调用路径的周期，不含 UART/USB/Windows 延迟。它适合评价“CPU 发起一次点积时是否更快”，但不能冒充批量神经网络吞吐量。真正评价 AI 加速器还需增加更长向量、批处理、每秒 MAC、能效和资源效率测试。

## 6. 失败如何解释

- `timed out waiting for response frame magic`：没有看到完整响应，先查 LED2/CPU trap、TX 接线和板端复位；
- `response command ... does not match`：可能是旧响应，或请求命令被破坏；status=3 表示 CRC 已检测到损坏；
- `framing_errors > 0`：波特率、地线、电平或信号质量问题；
- `rx_overflow > 0`：CPU/固件没有及时消费，需增大 FIFO、降低波特率或使用流控；
- 数学 mismatch 且 CRC/UART 计数为 0：才优先检查有符号扩展、字节顺序和加速器 RTL。
