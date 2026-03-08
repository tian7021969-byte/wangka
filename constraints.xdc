# ===========================================================================
#
#  constraints.xdc
#  Creative Sound Blaster AE-9 — Xilinx Artix-7 75T Captain 开发板
#  引脚分配与时序约束
#
# ===========================================================================
#
#  目标器件 : XC7A75T-FGG484
#  PCIe 配置 : Gen2 x1 (5.0 GT/s, 单 GTP 通道)
#  参考时钟 : 来自 PCIe 连接器的 100 MHz 差分时钟
#  GTP Bank  : Bank 216
#
#  本文件定义：
#    1. PCIe 参考时钟引脚 (REFCLK)
#    2. PCIe 复位引脚 (PERST#)
#    3. 通用 I/O 引脚 (LED 状态指示灯)
#    4. 时序约束 (参考时钟、false path)
#    5. Bitstream 配置选项
#
#  重要说明 — GTP 收发器数据通道 (TX/RX):
#    PCIe 数据通道 (pcie_tx_p/n, pcie_rx_p/n) 是 GTP Quad 内部的
#    专用串行引脚，由 Xilinx PCIe IP 核根据 REFCLK 所在的 GTP Quad
#    自动放置。在 XDC 中 **不可** 对这些引脚使用 PACKAGE_PIN 约束，
#    否则会触发 [Vivado 12-1141] 放置冲突错误。
#
# ===========================================================================


# ===========================================================================
#  PCIe 参考时钟 (100 MHz 差分)
# ===========================================================================
#
#  来自 PCIe 金手指连接器的 100 MHz 参考时钟，路由至 GTP Bank 216 的
#  专用 MGTREFCLK0 引脚对 (F6/E6)。
#
#  这些是 MGT Quad 内的专用模拟引脚，不需要也不允许设置 IOSTANDARD，
#  IBUFDS_GTE2 原语会在内部处理差分输入终端。
#
#  PCIe IP 核会根据此 REFCLK 的位置 (Bank 216) 自动将 GTP 收发器通道
#  (TX/RX) 放置在同一 Quad 内的正确位置，无需手动指定数据通道引脚。

set_property PACKAGE_PIN F6 [get_ports { pcie_clk_p }]
set_property PACKAGE_PIN E6 [get_ports { pcie_clk_n }]


# ===========================================================================
#  PCIe 基本复位信号 (PERST#)
# ===========================================================================
#
#  来自 PCIe 连接器的低电平有效复位信号。在 Captain 75T 开发板上，
#  该信号路由至 Bank 34 的通用 I/O 引脚 J1。
#
#  内部上拉电阻确保 FPGA 在板级上电时序完成之前（主机尚未拉低
#  PERST# 时）不会看到误复位。Bank 34 VCCO 为 3.3V，使用 LVCMOS33。

set_property PACKAGE_PIN J1         [get_ports { pcie_rst_n }]
set_property IOSTANDARD  LVCMOS33   [get_ports { pcie_rst_n }]
set_property PULLUP      true       [get_ports { pcie_rst_n }]


# ===========================================================================
#  PCIe x1 GTP 收发器通道 (Lane 0, Bank 216)
# ===========================================================================
#
#  注意: 此处 **不设置** PACKAGE_PIN 约束!
#
#  GTP 收发器的 TX/RX 差分对属于 GTPE2_CHANNEL 原语的内部端口，
#  由 PCIe IP 核在综合/实现时自动放置到 REFCLK (F6/E6) 所在的
#  Bank 216 GTP Quad 中。
#
#  如果在 XDC 中对 pcie_tx_p/n 或 pcie_rx_p/n 使用 set_property
#  PACKAGE_PIN，会导致 [Vivado 12-1141] 错误，因为 Vivado 无法
#  同时满足用户指定的 LOC 和 IP 内部的相对放置约束。
#
#  对于 FGG484 封装 Bank 216 GTP Quad，实际物理引脚为:
#    MGTPTXP0 = D2,  MGTPTXN0 = D1
#    MGTPRXP0 = E2,  MGTPRXN0 = E1
#  这些引脚由 IP 核自动使用，仅作参考记录。


# ===========================================================================
#  状态指示灯 — 链路连接指示 (LED)
# ===========================================================================
#
#  由 PCIe IP 的 user_lnk_up 信号驱动（高电平有效）:
#    LED 亮 = PCIe 链路训练完成，设备已被主机枚举
#    LED 灭 = 链路断开、训练中、或处于 D3hot 电源状态
#
#  Bank 34, LVCMOS33, 默认 8 mA 驱动能力。

set_property PACKAGE_PIN G1         [get_ports { led_status }]
set_property IOSTANDARD  LVCMOS33   [get_ports { led_status }]


# ===========================================================================
#  时序约束
# ===========================================================================

# ---------------------------------------------------------------------------
#  PCIe 参考时钟 — 100 MHz (周期 10.000 ns)
# ---------------------------------------------------------------------------
#  定义 GTP 收发器 PLL 的参考时钟。时钟名 "pcie_sys_clk" 与 Xilinx
#  PCIe IP 核内部时序约束中引用的名称一致。波形指定 50% 占空比。

create_clock -period 10.000 -name pcie_sys_clk \
    -waveform {0.000 5.000} \
    [get_ports pcie_clk_p]

# ---------------------------------------------------------------------------
#  PERST# False Path
# ---------------------------------------------------------------------------
#  PERST# 是异步外部复位信号，由 PCIe IP 核在内部进行同步处理。
#  从该端口出发的所有时序路径均排除在静态时序分析之外。

set_false_path -from [get_ports pcie_rst_n]

# ---------------------------------------------------------------------------
#  LED 输出 — 宽松时序
# ---------------------------------------------------------------------------
#  LED 输出为纯状态指示，无时序要求。设置 false path 防止工具
#  过度约束该输出并浪费布线资源。

set_false_path -to [get_ports led_status]

# ---------------------------------------------------------------------------
#  异步时钟域隔离 — PCIe 时钟 vs MMCM 24 MHz Wall Clock
# ---------------------------------------------------------------------------
#  pcie_sys_clk 域 (100 MHz REFCLK → PCIe IP 内部 user_clk 62.5 MHz)
#  与 u_mmcm_walclk 产生的 24 MHz Wall Clock 是完全异步的两个时钟域。
#  RTL 中已使用 toggle + 3 级同步器进行跨域处理，无需 Vivado 强行
#  对齐这两个域之间的时序路径。
#
#  此约束消除 WNS 时序违规报告中 clk_24m 相关的跨域路径。

set_clock_groups -asynchronous \
    -group [get_clocks pcie_sys_clk] \
    -group [get_clocks -of_objects [get_pins u_mmcm_walclk/CLKOUT0]]


# ===========================================================================
#  Bitstream 配置 (Flash 烧录参数)
# ===========================================================================

# SPI Flash 总线宽度: x4 (Quad-SPI 加速配置加载)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4       [current_design]

# 配置时钟频率: 50 MHz
set_property BITSTREAM.CONFIG.CONFIGRATE    50      [current_design]

# SPI Flash 下降沿采样 (增加时序余量, 提高可靠性)
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES     [current_design]

# 注: PERSIST 已移除 — Artix-7 PCIe 设计中 SPI 引脚在配置完成后
# 由 UNUSEDPIN=PULLUP 保护, 不需要 PERSIST (且 PERSIST 要求
# CONFIG_MODE 引脚约束, 会触发 DRC PRST-1)。

# 内部配置电压: 3.3V (匹配 Captain 开发板设计)
set_property CONFIG_VOLTAGE                 3.3     [current_design]
set_property CFGBVS                         VCCO    [current_design]

# 启用位流压缩 (减小 .bit 文件体积，加快 SPI Flash 加载速度)
set_property BITSTREAM.GENERAL.COMPRESS     TRUE    [current_design]

# 未使用引脚在配置期间上拉 (防止浮空输入)
set_property BITSTREAM.CONFIG.UNUSEDPIN     PULLUP  [current_design]


# ===========================================================================
#  约束文件结束
# ===========================================================================
