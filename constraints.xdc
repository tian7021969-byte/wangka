# ===========================================================================
#
#  constraints.xdc
#  Intel I211 Gigabit Ethernet Controller - Xilinx Artix-7 Captain DMA 75T V3.0
#  Pin Assignment and Timing Constraints
#
# ===========================================================================
#
#  Target Device : XC7A75T-FGG484
#  PCIe Config   : Gen1 x1 (2.5 GT/s, single GTP lane)
#  Reference Clk : 100 MHz differential clock from PCIe connector
#  GTP Bank      : Bank 216
#
#  This file defines:
#    1. PCIe reference clock pins (REFCLK)
#    2. PCIe reset pin (PERST#)
#    3. General I/O pins (LED status indicator)
#    4. Timing constraints (reference clock, false paths)
#    5. Bitstream configuration options
#
#  IMPORTANT NOTE - GTP Transceiver Data Lanes (TX/RX):
#    PCIe data lanes (pcie_tx_p/n, pcie_rx_p/n) are dedicated serial
#    pins inside the GTP Quad, automatically placed by the Xilinx PCIe
#    IP core based on the REFCLK location within the GTP Quad.
#    You MUST NOT use PACKAGE_PIN constraints on these pins in XDC,
#    otherwise it will trigger [Vivado 12-1141] placement conflict error.
#
# ===========================================================================


# ===========================================================================
#  PCIe Reference Clock (100 MHz Differential)
# ===========================================================================
#
#  100 MHz reference clock from PCIe edge connector, routed to GTP Bank 216
#  dedicated MGTREFCLK0 pin pair (F10/E10).
#
#  These are dedicated analog pins inside the MGT Quad; IOSTANDARD is
#  neither required nor allowed. IBUFDS_GTE2 primitive handles the
#  differential input termination internally.
#
#  The PCIe IP core will automatically place GTP transceiver lanes
#  (TX/RX) in the same Quad based on this REFCLK location.

set_property PACKAGE_PIN F10 [get_ports { pcie_clk_p }]
set_property PACKAGE_PIN E10 [get_ports { pcie_clk_n }]


# ===========================================================================
#  PCIe Fundamental Reset Signal (PERST#)
# ===========================================================================
#
#  Active-low reset signal from PCIe connector. On Captain DMA 75T V3.0,
#  this signal is routed to pin C13.
#
#  Internal pull-up resistor ensures the FPGA does not see a false reset
#  during board power-up sequence (before the host asserts PERST#).
#  LVCMOS33 voltage standard.

set_property PACKAGE_PIN C13        [get_ports { pcie_rst_n }]
set_property IOSTANDARD  LVCMOS33   [get_ports { pcie_rst_n }]
set_property PULLUP      true       [get_ports { pcie_rst_n }]


# ===========================================================================
#  PCIe x1 GTP Transceiver Lane (Lane 0, Bank 216)
# ===========================================================================
#
#  NOTE: PACKAGE_PIN constraints are NOT set here!
#
#  GTP transceiver TX/RX differential pairs are internal ports of the
#  GTPE2_CHANNEL primitive, automatically placed by the PCIe IP core
#  during synthesis/implementation into the GTP Quad containing
#  REFCLK (F10/E10).
#
#  Setting PACKAGE_PIN for pcie_tx_p/n or pcie_rx_p/n in XDC will
#  cause [Vivado 12-1141] error because Vivado cannot satisfy both
#  the user-specified LOC and IP-internal relative placement constraints.
#
#  For FGG484 package GTP Quad (REFCLK F10/E10), actual physical pins:
#    MGTPTXP0 = B6,  MGTPTXN0 = A6
#    MGTPRXP0 = B8,  MGTPRXN0 = A8
#  These pins are used automatically by the IP core, listed for reference.


# ===========================================================================
#  Status Indicator LED - Link Connection Status
# ===========================================================================
#
#  Driven by PCIe IP user_lnk_up signal (active low):
#    LED on  = PCIe link training complete, device enumerated by host
#    LED off = Link down, training, or in D3hot power state
#
#  Captain DMA 75T V3.0 user_ld1_n pin G21, active low, LVCMOS33.

set_property PACKAGE_PIN G21        [get_ports { led_status }]
set_property IOSTANDARD  LVCMOS33   [get_ports { led_status }]


# ===========================================================================
#  Timing Constraints
# ===========================================================================

# ---------------------------------------------------------------------------
#  PCIe Reference Clock - 100 MHz (period 10.000 ns)
# ---------------------------------------------------------------------------
#  Defines the GTP transceiver PLL reference clock. Clock name "pcie_sys_clk"
#  matches the name referenced in Xilinx PCIe IP core internal timing
#  constraints. Waveform specifies 50% duty cycle.

create_clock -period 10.000 -name pcie_sys_clk \
    -waveform {0.000 5.000} \
    [get_ports pcie_clk_p]

# ---------------------------------------------------------------------------
#  PERST# False Path
# ---------------------------------------------------------------------------
#  PERST# is an asynchronous external reset signal, synchronized internally
#  by the PCIe IP core. All timing paths from this port are excluded from
#  static timing analysis.

set_false_path -from [get_ports pcie_rst_n]

# ---------------------------------------------------------------------------
#  LED Output - Relaxed Timing
# ---------------------------------------------------------------------------
#  LED output is purely a status indicator with no timing requirements.
#  Set false path to prevent the tool from over-constraining this output
#  and wasting routing resources.

set_false_path -to [get_ports led_status]

# ---------------------------------------------------------------------------
#  Note: I211 design does not use MMCM, no async clock domain constraints
#  All logic runs on PCIe user_clk (62.5 MHz) single clock domain
# ---------------------------------------------------------------------------


# ===========================================================================
#  Bitstream Configuration (Flash Programming Parameters)
# ===========================================================================

# SPI Flash bus width: x4 (Quad-SPI accelerated configuration loading)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4       [current_design]

# Configuration clock frequency: 50 MHz
set_property BITSTREAM.CONFIG.CONFIGRATE    50      [current_design]

# SPI Flash falling edge sampling (improves timing margin and reliability)
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES     [current_design]

# Note: PERSIST removed - in Artix-7 PCIe designs, SPI pins are protected
# by UNUSEDPIN=PULLUP after configuration. PERSIST is not needed (and
# PERSIST requires CONFIG_MODE pin constraints, triggering DRC PRST-1).

# Internal configuration voltage: 3.3V (matches Captain board design)
set_property CONFIG_VOLTAGE                 3.3     [current_design]
set_property CFGBVS                         VCCO    [current_design]

# Enable bitstream compression (reduces .bit file size, speeds up SPI Flash loading)
set_property BITSTREAM.GENERAL.COMPRESS     TRUE    [current_design]

# Pull up unused pins during configuration (prevents floating inputs)
set_property BITSTREAM.CONFIG.UNUSEDPIN     PULLUP  [current_design]


# ===========================================================================
#  End of Constraints File
# ===========================================================================
