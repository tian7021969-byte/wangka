// ===========================================================================
//
//  bar0_i211_sim.v
//  Intel I211 Gigabit Ethernet Controller - BAR0 MMIO Register Emulation
//
// ===========================================================================
//
//  Overview
//  --------
//  Emulates Intel I211-AT BAR0 MMIO register space (128KB), including:
//    - Device control/status registers (CTRL, STATUS, EECD, CTRL_EXT)
//    - Interrupt registers (ICR, ICS, IMS, IMC)
//    - RX/TX control registers (RCTL, TCTL)
//    - PHY/MDIC interface emulation
//    - EEPROM emulation (EERD - NVM Read)
//    - MAC address registers (RAL0, RAH0)
//    - PCIe related registers
//
//  TLP Handling:
//    - 3DW / 4DW Memory Read  -> CplD response
//    - 3DW / 4DW Memory Write -> Register write
//    - Unknown Non-Posted TLP -> UR Completion
//    - Unknown Posted TLP     -> Silently discard
//
//  Intel I211 Key IDs:
//    Vendor ID  = 0x8086
//    Device ID  = 0x1539
//    Subsystem Vendor ID = 0x1849 (ASRock typical)
//    Subsystem Device ID = 0x1539
//    Rev ID     = 0x03
//    Class Code = 0x020000 (Ethernet Controller)
//
// ===========================================================================

module bar0_i211_sim (
    input  wire         clk,
    input  wire         rst_n,

    // Configuration info (from PCIe IP)
    input  wire [15:0]  completer_id,       // Bus/Dev/Func

    // LFSR seed (from top level)
    input  wire [15:0]  jitter_seed,

    // RX AXI4-Stream (from TLP router)
    input  wire [63:0]  m_axis_rx_tdata,
    input  wire [ 7:0]  m_axis_rx_tkeep,
    input  wire         m_axis_rx_tlast,
    input  wire         m_axis_rx_tvalid,
    output reg          m_axis_rx_tready,
    input  wire [21:0]  m_axis_rx_tuser,

    // TX AXI4-Stream (to TX arbiter)
    output reg  [63:0]  s_axis_tx_tdata,
    output reg  [ 7:0]  s_axis_tx_tkeep,
    output reg          s_axis_tx_tlast,
    output reg          s_axis_tx_tvalid,
    input  wire         s_axis_tx_tready,
    output reg  [ 3:0]  s_axis_tx_tuser
);

    // ===================================================================
    //  I211 Register Address Map (BAR0 offset, 128KB = 0x00000 ~ 0x1FFFF)
    // ===================================================================
    //  Using DW offset (byte offset / 4)

    // --- General Control Registers ---
    localparam DW_CTRL       = 15'h0000;  // 0x00000 Device Control
    localparam DW_STATUS     = 15'h0002;  // 0x00008 Device Status
    localparam DW_EECD       = 15'h0004;  // 0x00010 EEPROM/Flash Control
    localparam DW_EERD       = 15'h0005;  // 0x00014 EEPROM Read
    localparam DW_CTRL_EXT   = 15'h0006;  // 0x00018 Extended Device Control
    localparam DW_MDIC       = 15'h0008;  // 0x00020 MDI Control
    localparam DW_FEXTNVM6   = 15'h0028;  // 0x000A0 Future Extended NVM 6
    localparam DW_FCAL       = 15'h000A;  // 0x00028 Flow Control Addr Low
    localparam DW_FCAH       = 15'h000B;  // 0x0002C Flow Control Addr High
    localparam DW_FCT        = 15'h000C;  // 0x00030 Flow Control Type
    localparam DW_FCTTV      = 15'h0044;  // 0x00110 FC Transmit Timer Value

    // --- Interrupt Registers ---
    localparam DW_ICR        = 15'h0030;  // 0x000C0 Interrupt Cause Read
    localparam DW_ITR        = 15'h0031;  // 0x000C4 Interrupt Throttling
    localparam DW_ICS        = 15'h0032;  // 0x000C8 Interrupt Cause Set
    localparam DW_IMS        = 15'h0034;  // 0x000D0 Interrupt Mask Set
    localparam DW_IMC        = 15'h0035;  // 0x000D4 Interrupt Mask Clear

    // --- RX Control ---
    localparam DW_RCTL       = 15'h0040;  // 0x00100 Receive Control
    localparam DW_RDBAL0     = 15'h0B00;  // 0x02C00 RX Desc Base Low (queue 0)
    localparam DW_RDBAH0     = 15'h0B01;  // 0x02C04 RX Desc Base High
    localparam DW_RDLEN0     = 15'h0B02;  // 0x02C08 RX Desc Length
    localparam DW_RDH0       = 15'h0B04;  // 0x02C10 RX Desc Head
    localparam DW_RDT0       = 15'h0B06;  // 0x02C18 RX Desc Tail

    // --- TX Control ---
    localparam DW_TCTL       = 15'h0100;  // 0x00400 Transmit Control
    localparam DW_TDBAL0     = 15'h0E00;  // 0x03800 TX Desc Base Low (queue 0)
    localparam DW_TDBAH0     = 15'h0E01;  // 0x03804 TX Desc Base High
    localparam DW_TDLEN0     = 15'h0E02;  // 0x03808 TX Desc Length
    localparam DW_TDH0       = 15'h0E04;  // 0x03810 TX Desc Head
    localparam DW_TDT0       = 15'h0E06;  // 0x03818 TX Desc Tail

    // --- MAC Address ---
    localparam DW_RAL0       = 15'h1500;  // 0x05400 Receive Address Low
    localparam DW_RAH0       = 15'h1501;  // 0x05404 Receive Address High

    // --- Statistics Registers (partial) ---
    localparam DW_GPRC       = 15'h1013;  // 0x0404C Good Packets Received Count
    localparam DW_GPTC       = 15'h1015;  // 0x04054 Good Packets Transmitted Count
    localparam DW_GORCL      = 15'h1022;  // 0x04088 Good Octets Received Count Low
    localparam DW_GORCH      = 15'h1023;  // 0x0408C Good Octets Received Count High
    localparam DW_GOTCL      = 15'h1024;  // 0x04090 Good Octets Transmitted Count Low
    localparam DW_GOTCH      = 15'h1025;  // 0x04094 Good Octets Transmitted Count High

    // --- Firmware ---
    localparam DW_FWSM       = 15'h1558;  // 0x05560 Firmware Semaphore
    localparam DW_SW_FW_SYNC = 15'h1560;  // 0x05580 SW-FW Synchronization

    // --- I210/I211 Shadow RAM (NVM) Registers ---
    // igb driver on I210/I211 uses SRRD/SRWR, NOT EERD/EEWR!
    localparam DW_SRRD       = 15'h4806;  // 0x12018 Shadow RAM Read
    localparam DW_SRWR       = 15'h4807;  // 0x1201C Shadow RAM Write
    localparam DW_FLSWCTL    = 15'h4812;  // 0x12048 Flash SW Access Control

    // --- MSI-X Table and PBA ---
    // I211 supports 5 MSI-X vectors
    // MSI-X Table at BAR0 offset 0xE000 (DW offset 0x3800)
    // Each entry: 4 DWORDs (Msg Addr Low, Msg Addr High, Msg Data, Vector Control)
    // PBA at BAR0 offset 0xE800 (DW offset 0x3A00)
    localparam DW_MSIX_TABLE_BASE = 15'h3800;  // 0x0E000
    localparam DW_MSIX_PBA_BASE   = 15'h3A00;  // 0x0E800

    // ===================================================================
    //  Writable Registers
    // ===================================================================

    reg [31:0] reg_ctrl;        // 0x00000 Device Control
    reg [31:0] reg_status;      // 0x00008 Device Status
    reg [31:0] reg_eecd;        // 0x00010 EEPROM/Flash Control
    reg [31:0] reg_eerd;        // 0x00014 EEPROM Read
    reg [31:0] reg_ctrl_ext;    // 0x00018 Extended Device Control
    reg [31:0] reg_mdic;        // 0x00020 MDI Control

    // ---------------------------------------------------------------
    //  EECD NVM 操作状态机寄存器
    //  Windows e1r68x64.sys 驱动通过 EECD 执行 bit-bang NVM 读取:
    //    1. 写 EE_REQ(bit6)=1 请求 NVM 访问
    //    2. 轮询 EE_GNT(bit7) 直到=1 (获得授权)
    //    3. 通过 EE_CS/EE_SK/EE_DI/EE_DO 执行 SPI 位操作
    //    4. 完成后写 EE_REQ(bit6)=0 释放 NVM
    //  需要仿真的位域:
    //    [0] EE_SK  - SPI Clock (driver writes)
    //    [1] EE_CS  - SPI Chip Select (driver writes)
    //    [2] EE_DI  - SPI Data In to NVM (driver writes)
    //    [3] EE_DO  - SPI Data Out from NVM (FPGA drives)
    //    [6] EE_REQ - NVM Access Request (driver writes)
    //    [7] EE_GNT - NVM Access Grant (FPGA auto-sets)
    //    [8] EE_PRES - NVM Present (read-only, =1)
    //    [9] AUTO_RD - Auto Read Done (read-only, =1)
    //   [19] FLASH_DETECTED_I210 (read-only, =1)
    // ---------------------------------------------------------------
    reg  [4:0]  eecd_spi_bit_cnt;    // SPI 位计数器 (0~15 for opcode+addr, 0~15 for data)
    reg  [2:0]  eecd_spi_state;      // SPI 状态机
    reg  [15:0] eecd_spi_shift_in;   // 驱动写入的移位寄存器 (opcode + address)
    reg  [15:0] eecd_spi_shift_out;  // NVM 数据输出移位寄存器
    reg         eecd_sk_prev;        // EE_SK 上一拍值 (用于检测上升沿)
    reg         eecd_cs_prev;        // EE_CS 上一拍值 (用于检测下降沿=选中)

    // SPI NVM 状态定义
    localparam SPI_IDLE     = 3'd0;  // 等待 CS 拉低
    localparam SPI_OPCODE   = 3'd1;  // 接收 8-bit opcode
    localparam SPI_ADDR     = 3'd2;  // 接收地址位
    localparam SPI_DATA_OUT = 3'd3;  // 输出 NVM 数据
    localparam SPI_DONE     = 3'd4;  // 传输完成

    reg  [7:0]  eecd_spi_opcode;     // 缓存的 SPI opcode
    reg  [15:0] eecd_spi_addr;       // 缓存的 NVM 地址 (word address)

    reg [31:0] reg_icr;         // 0x000C0 Interrupt Cause Read
    reg [31:0] reg_itr;         // 0x000C4 Interrupt Throttling
    reg [31:0] reg_ims;         // 0x000D0 Interrupt Mask Set/Read
    reg [31:0] reg_imc;         // 0x000D4 (write-only)

    reg [31:0] reg_rctl;        // 0x00100 Receive Control
    reg [31:0] reg_tctl;        // 0x00400 Transmit Control

    // RX descriptor queue 0
    reg [31:0] reg_rdbal0;
    reg [31:0] reg_rdbah0;
    reg [31:0] reg_rdlen0;
    reg [31:0] reg_rdh0;
    reg [31:0] reg_rdt0;

    // TX descriptor queue 0
    reg [31:0] reg_tdbal0;
    reg [31:0] reg_tdbah0;
    reg [31:0] reg_tdlen0;
    reg [31:0] reg_tdh0;
    reg [31:0] reg_tdt0;

    // Flow Control
    reg [31:0] reg_fcal;
    reg [31:0] reg_fcah;
    reg [31:0] reg_fct;
    reg [31:0] reg_fcttv;

    // MAC Address (default randomized, based on Intel OUI 00:1B:21)
    reg [31:0] reg_ral0;        // RAL0: MAC[3:0] (bytes 0-3 of MAC)
    reg [31:0] reg_rah0;        // RAH0: MAC[5:4] + AV bit

    // Firmware
    reg [31:0] reg_fwsm;
    reg [31:0] reg_sw_fw_sync;

    // SWSM (0x05B50) - Software Semaphore
    // igb driver acquires SW semaphore before NVM operations
    // bit 0: SMBI (SW Mailbox Indicator) - write 1 to acquire, read to check
    // bit 1: SWESMBI (SW/FW semaphore) - write 1 to acquire
    reg [31:0] reg_swsm;

    // --- I211 Extended Interrupt Registers ---
    reg [31:0] reg_gpie;         // 0x01514 General Purpose Interrupt Enable
    reg [31:0] reg_eicr;         // 0x01580 Extended Interrupt Cause Read
    reg [31:0] reg_eics;         // 0x01520 Extended Interrupt Cause Set
    reg [31:0] reg_eims;         // 0x01524 Extended Interrupt Mask Set
    reg [31:0] reg_eimc;         // 0x01528 Extended Interrupt Mask Clear
    reg [31:0] reg_eiac;         // 0x0152C Extended Interrupt Auto Clear
    reg [31:0] reg_eiam;         // 0x01530 Extended Interrupt Auto Mask

    // --- IVAR (Interrupt Vector Allocation) ---
    reg [31:0] reg_ivar0;        // 0x01700 IVAR0 (Q0 RX/TX vectors)
    reg [31:0] reg_ivar_misc;    // 0x01740 IVAR_MISC (other/link vectors)

    // --- RX/TX Descriptor Control (Queue 0) ---
    // CRITICAL: igb driver writes ENABLE (bit 25) then polls until readback=1
    reg [31:0] reg_rxdctl0;      // 0x02C28 RX Descriptor Control Q0
    reg [31:0] reg_txdctl0;      // 0x03828 TX Descriptor Control Q0

    // --- Split/Replication RX Control ---
    reg [31:0] reg_srrctl0;      // 0x0C00C Split/Replication RX Control Q0

    // --- RX/TX DMA Control ---
    reg [31:0] reg_rxctl;        // 0x02814 DCA RX Control
    reg [31:0] reg_txctl;        // 0x0E014 DCA TX Control
    reg [31:0] reg_dtxctl;       // 0x03590 DMA TX Control (DTXCTL)

    // --- Wake-Up Registers (writable) ---
    reg [31:0] reg_wuc;          // 0x05800 Wake Up Control
    reg [31:0] reg_wufc;         // 0x05808 Wake Up Filter Control

    // --- Packet Buffer & Flow Control ---
    reg [31:0] reg_pba;          // 0x01000 Packet Buffer Allocation
    reg [31:0] reg_rlpml;        // 0x05004 Receive Long Packet Max Length

    // --- EXTCNF_CTRL ---
    reg [31:0] reg_extcnf_ctrl;  // 0x00F00 Extended Configuration Control

    // --- Timestamp Control ---
    reg [31:0] reg_tsyncrxctl;   // 0x0B620 Timestamp RX Control
    reg [31:0] reg_tsynctxctl;   // 0x0B614 Timestamp TX Control

    // EEPROM emulation delay
    reg [7:0]  eerd_delay_cnt;
    reg        eerd_pending;

    // I210/I211 Shadow RAM Read (SRRD) emulation
    // igb driver uses SRRD register (0x12018) to read NVM on I210/I211
    // Format: bit[0]=Start, bit[1]=Done, bit[15:2]=Address, bit[31:16]=Data
    reg [31:0] reg_srrd;
    reg [7:0]  srrd_delay_cnt;
    reg        srrd_pending;

    // MSI-X Table: 5 entries × 4 DWORDs each = 20 DWORDs
    // Each entry: [0] Msg Addr Low, [1] Msg Addr High, [2] Msg Data, [3] Vector Control
    // Vector Control bit 0: Mask bit (1=masked, 0=unmasked)
    // All vectors initially masked (bit 0 = 1)
    reg [31:0] msix_table [0:19];
    // MSI-X PBA: 1 QWORD for up to 64 vectors (only bit[4:0] used for 5 vectors)
    reg [31:0] msix_pba [0:1];

    // ===================================================================
    //  LFSR (for non-standard area obfuscation + MAC randomization)
    // ===================================================================

    reg [15:0] jitter_lfsr;
    wire jitter_fb = jitter_lfsr[0];

    always @(posedge clk) begin
        if (!rst_n)
            jitter_lfsr <= jitter_seed ^ 16'hA55A;
        else
            jitter_lfsr <= {1'b0, jitter_lfsr[15:1]}
                         ^ (jitter_fb ? 16'hB400 : 16'h0000);
    end

    // ===================================================================
    //  EEPROM (NVM) Content Emulation
    //  I211 internal NVM accessed via EERD register by word address
    // ===================================================================

    // =================================================================
    //  EEPROM (NVM) Full Emulation - first 64 words (0x00~0x3F)
    //  igb driver reads these 64 words during init and verifies:
    //    sum(word[0x00] .. word[0x3F]) == 0xBABA
    //  All undefined words return 0x0000 (not 0xFFFF!) to simplify
    //  checksum calculation
    // =================================================================

    function [15:0] eeprom_read;
        input [13:0] word_addr;
        begin
            case (word_addr[7:0])
                // --- MAC Address (Intel OUI 00:1B:21 + dynamic suffix) ---
                8'h00: eeprom_read = reg_ral0[15:0];        // MAC bytes 1:0
                8'h01: eeprom_read = reg_ral0[31:16];       // MAC bytes 3:2
                8'h02: eeprom_read = reg_rah0[15:0];        // MAC bytes 5:4

                // --- NVM Structure ---
                8'h03: eeprom_read = 16'h0C00;  // Init Control 3 / NVM Structure Version

                // --- Compatibility / Serial Number Word ---
                // Windows e1r68x64.sys reads word 0x04 for compatibility bits
                8'h04: eeprom_read = 16'h0000;  // Compatibility (no special flags)

                8'h05: eeprom_read = 16'h0200;  // Image Version Info (2.0)

                // --- Extended Configuration Words ---
                // Windows driver reads words 0x06-0x07 for additional init config
                8'h06: eeprom_read = 16'h0000;  // Extended Config Word 1
                8'h07: eeprom_read = 16'h0000;  // Extended Config Word 2

                8'h08: eeprom_read = 16'h0006;  // PBA Length (6 words)
                8'h09: eeprom_read = 16'h0009;  // PBA pointer

                // --- Subsystem IDs ---
                8'h0A: eeprom_read = 16'h1539;  // Subsystem Device ID
                8'h0B: eeprom_read = 16'h1849;  // Subsystem Vendor ID (ASRock)

                // --- Device Rev/ID in NVM ---
                // Windows e1r68x64.sys validates NVM Dev ID and Rev ID
                // against PCIe config space - MUST match!
                8'h0C: eeprom_read = 16'h0003;  // Revision ID (0x03 in low byte)
                8'h0D: eeprom_read = 16'h1539;  // Device ID (must match PCI config!)

                // --- Software-defined pins / Wake ---
                8'h0E: eeprom_read = 16'h2580;  // Software Defined Pins Control

                // --- Initialization Control Words ---
                8'h0F: eeprom_read = 16'h0E22;  // Init Control Word 1
                8'h10: eeprom_read = 16'h0410;  // Init Control Word 2
                8'h11: eeprom_read = 16'h0100;  // Init Control Word 3
                8'h12: eeprom_read = 16'h8086;  // Vendor ID in NVM (Intel)

                // --- OEM Configuration Words ---
                // Windows driver may read words 0x13-0x18 for OEM config
                8'h13: eeprom_read = 16'h0000;  // OEM Config Word 1
                8'h14: eeprom_read = 16'h0000;  // OEM Config Word 2
                8'h15: eeprom_read = 16'h0000;  // OEM Config Word 3
                8'h16: eeprom_read = 16'h0000;  // OEM Config Word 4
                8'h17: eeprom_read = 16'h0000;  // OEM Config Word 5
                8'h18: eeprom_read = 16'h0000;  // OEM Config Word 6

                // --- LED & PHY Configuration ---
                8'h1A: eeprom_read = 16'h0F07;  // LED Configuration

                // --- LAN Power Consumption ---
                // Windows driver checks these for power management
                8'h1B: eeprom_read = 16'h0000;  // LAN Power Consumption D0
                8'h1C: eeprom_read = 16'h0000;  // LAN Power Consumption D3

                // --- NVM Compatibility & Config ---
                8'h1D: eeprom_read = 16'h0000;  // NVM Compatibility word

                8'h1E: eeprom_read = 16'h0013;  // PHY ID Low
                8'h1F: eeprom_read = 16'h0380;  // PHY ID High

                // --- Extended Init Control ---
                // Windows driver reads additional init control words
                8'h20: eeprom_read = 16'h0000;  // Extended Init Control 1
                8'h21: eeprom_read = 16'h0000;  // Extended Init Control 2
                8'h22: eeprom_read = 16'h0000;  // Extended Init Control 3

                // --- Capability / Feature Words ---
                8'h23: eeprom_read = 16'h0000;  // Capabilities word
                8'h24: eeprom_read = 16'h0010;  // Feature config

                // --- Additional Config Words ---
                // Fill remaining words 0x25-0x3E with 0x0000
                // to ensure clean checksum calculation

                // --- NVM Checksum (word 0x3F) ---
                // Checksum computed dynamically by EERD completion logic
                // eeprom_read returns 0 as placeholder; real value via nvm_checksum_word
                8'h3F: eeprom_read = 16'h0000;  // placeholder, actual uses nvm_checksum_word

                default: begin
                    if (word_addr[7:0] <= 8'h3F)
                        eeprom_read = 16'h0000;  // first 64 words default 0 (helps checksum)
                    else
                        eeprom_read = 16'hFFFF;  // out of range returns 0xFFFF
                end
            endcase
        end
    endfunction

    // =================================================================
    //  NVM Checksum Runtime Calculation
    //  igb driver requires: sum(word[0x00] .. word[0x3F]) == 0xBABA
    //  word 0x3F = 0xBABA - sum(word[0x00] .. word[0x3E])
    // =================================================================

    // Sum of fixed word constants (excluding word 0x00~0x02 and 0x3F):
    wire [15:0] nvm_mac_sum = reg_ral0[15:0] + reg_ral0[31:16] + reg_rah0[15:0];
    // Sum of all non-zero NVM words (excluding MAC words 0x00-0x02 and checksum 0x3F):
    // word 0x03=0x0C00, 0x05=0x0200, 0x08=0x0006, 0x09=0x0009
    // word 0x0A=0x1539, 0x0B=0x1849, 0x0C=0x0003, 0x0D=0x1539
    // word 0x0E=0x2580, 0x0F=0x0E22, 0x10=0x0410, 0x11=0x0100
    // word 0x12=0x8086, 0x1A=0x0F07, 0x1E=0x0013, 0x1F=0x0380
    // word 0x24=0x0010
    // (all other words 0x04,0x06,0x07,0x13-0x18,0x1B-0x1D,0x20-0x23,0x25-0x3E = 0x0000)
    wire [15:0] nvm_fixed_sum = 16'h0C00 + 16'h0200 + 16'h0006 + 16'h0009 +
                                16'h1539 + 16'h1849 + 16'h0003 + 16'h1539 +
                                16'h2580 + 16'h0E22 + 16'h0410 + 16'h0100 +
                                16'h8086 + 16'h0F07 + 16'h0013 + 16'h0380 +
                                16'h0010;
    wire [15:0] nvm_checksum_word = 16'hBABA - nvm_fixed_sum - nvm_mac_sum;

    // ===================================================================
    //  MDIC (PHY Interface) Emulation
    //  Windows igb/e1000e driver reads PHY registers via MDIC
    //  I211 uses internal I210 PHY (ID = 0x0141:0x0CB1)
    //  igb driver uses page-based PHY register access:
    //    - Write reg 22 (0x16) to select page
    //    - Read/Write reg 0-21 on that page
    // ===================================================================

    reg [15:0] phy_page_reg;  // PHY page select register (reg 22)

    function [15:0] phy_read;
        input [4:0] phy_reg;
        input [15:0] phy_page;
        begin
            case (phy_reg)
                // PHY Control Register (0)
                5'h00: phy_read = 16'h1140; // Auto-neg, Full-duplex, 1000Mbps

                // PHY Status Register (1) - critical! driver uses this for link state
                5'h01: phy_read = 16'h796D; // Link up, auto-neg complete, all caps

                // PHY ID 1 (2) - must match I210/I211 PHY
                5'h02: phy_read = 16'h0141; // Intel PHY OUI high

                // PHY ID 2 (3) - I210/I211 internal PHY model
                5'h03: phy_read = 16'h0CB1; // I211 internal PHY

                // Auto-Neg Advertisement (4)
                5'h04: phy_read = 16'h01E1;

                // Auto-Neg Link Partner Ability (5)
                5'h05: phy_read = 16'hC5E1;

                // Auto-Neg Expansion (6)
                5'h06: phy_read = 16'h000F;

                // 1000BASE-T Control (9)
                5'h09: phy_read = 16'h0300;

                // 1000BASE-T Status (10) - link partner capability
                5'h0A: phy_read = 16'h7C00; // Partner capable 1000Mbps

                // Extended Status (15)
                5'h0F: phy_read = 16'h3000;

                // PHY Specific Control (16) - I211 specific
                // Page-sensitive: igb reads page 0 reg 16 for copper specific control
                5'h10: begin
                    case (phy_page)
                        16'h0000: phy_read = 16'h0068; // Copper Specific Control
                        16'h0769: phy_read = 16'h0000; // EEE advertisement (page 0x769)
                        default:  phy_read = 16'h0000;
                    endcase
                end

                // PHY Specific Status (17)
                5'h11: phy_read = 16'hAC04; // 1000Mbps, Full-duplex, Link up, resolved

                // PHY Page Select (22) - return current page
                5'h16: phy_read = phy_page;

                // I210/I211 extended registers
                // Register 18 (0x12) - interrupt enable
                5'h12: phy_read = 16'h0000;

                // Register 19 (0x13) - interrupt status
                5'h13: phy_read = 16'h0000;

                // Register 20 (0x14) - page-dependent
                5'h14: begin
                    case (phy_page)
                        16'h0000: phy_read = 16'h0000; // Extended PHY Specific Control
                        16'h0BCD: phy_read = 16'h3C40; // K1 config (igb_read_phy_reg_82580)
                        default:  phy_read = 16'h0000;
                    endcase
                end

                // Register 21 (0x15) - page-dependent
                5'h15: begin
                    case (phy_page)
                        16'h0BCD: phy_read = 16'h0004; // K1 config register
                        default:  phy_read = 16'h0000;
                    endcase
                end

                default: phy_read = 16'h0000;
            endcase
        end
    endfunction

    // ===================================================================
    //  Register Read Logic
    // ===================================================================

    function [31:0] read_register;
        input [14:0] dw_offset;  // 128KB = 32K DWORDs, 15-bit offset
        begin
            case (dw_offset)
                // --- General Control ---
                DW_CTRL:     read_register = reg_ctrl;
                DW_STATUS:   read_register = reg_status;
                DW_EECD:     read_register = reg_eecd | 32'h0008_0300;
                    // 强制保持只读位:
                    // bit[8]  EE_PRES = 1 (NVM Present)
                    // bit[9]  AUTO_RD = 1 (Auto Read Done)
                    // bit[19] FLASH_DETECTED_I210 = 1
                DW_EERD:     read_register = reg_eerd;
                DW_CTRL_EXT: read_register = reg_ctrl_ext;
                DW_MDIC:     read_register = reg_mdic;
                DW_FEXTNVM6: read_register = 32'h0000_0001; // I211 K1 config default

                // --- I210/I211 Shadow RAM ---
                DW_SRRD:     read_register = reg_srrd;

                // --- Interrupts ---
                DW_ICR:      read_register = reg_icr;
                DW_ITR:      read_register = reg_itr;
                DW_IMS:      read_register = reg_ims;

                // --- RX/TX Control ---
                DW_RCTL:     read_register = reg_rctl;
                DW_TCTL:     read_register = reg_tctl;

                // --- Flow Control ---
                DW_FCAL:     read_register = reg_fcal;
                DW_FCAH:     read_register = reg_fcah;
                DW_FCT:      read_register = reg_fct;
                DW_FCTTV:    read_register = reg_fcttv;

                // --- RX Desc Queue 0 ---
                DW_RDBAL0:   read_register = reg_rdbal0;
                DW_RDBAH0:   read_register = reg_rdbah0;
                DW_RDLEN0:   read_register = reg_rdlen0;
                DW_RDH0:     read_register = reg_rdh0;
                DW_RDT0:     read_register = reg_rdt0;

                // --- TX Desc Queue 0 ---
                DW_TDBAL0:   read_register = reg_tdbal0;
                DW_TDBAH0:   read_register = reg_tdbah0;
                DW_TDLEN0:   read_register = reg_tdlen0;
                DW_TDH0:     read_register = reg_tdh0;
                DW_TDT0:     read_register = reg_tdt0;

                // --- MAC Address ---
                DW_RAL0:     read_register = reg_ral0;
                DW_RAH0:     read_register = reg_rah0;

                // --- Statistics Registers (Read-Clear, return 0) ---
                DW_GPRC:     read_register = 32'h0;
                DW_GPTC:     read_register = 32'h0;
                DW_GORCL:    read_register = 32'h0;
                DW_GORCH:    read_register = 32'h0;
                DW_GOTCL:    read_register = 32'h0;
                DW_GOTCH:    read_register = 32'h0;

                // --- Firmware ---
                DW_FWSM:       read_register = reg_fwsm;
                DW_SW_FW_SYNC: read_register = reg_sw_fw_sync;

                // --- Other important registers with reasonable defaults ---
                // RXPBS (0x02404) - RX Packet Buffer Size
                15'h0901: read_register = 32'h00000020; // 32KB

                // TXPBS (0x03404) - TX Packet Buffer Size
                15'h0D01: read_register = 32'h00000020; // 32KB

                // MANC (0x05820) - Management Control
                15'h1608: read_register = 32'h0;

                // MANC2H (0x05860) - Management Control to Host
                15'h1618: read_register = 32'h0;

                // SWSM (0x05B50) - Software Semaphore
                // igb driver uses e1000_get_hw_semaphore_82575() which:
                //   1. Writes SWSM.SMBI (bit 0) = 1
                //   2. Reads back SWSM.SMBI - if 1, semaphore acquired
                //   3. Then writes SWSM.SWESMBI (bit 1) = 1
                //   4. Reads back - if 1, FW semaphore acquired
                // If reads back 0 on either, driver retries then fails -> Code 10!
                15'h16D4: read_register = reg_swsm;

                // --- Windows e1r68x64.sys driver additional registers ---

                // CTRL_DUP (0x00004) - Duplicate of CTRL
                // Some Windows drivers read this offset
                15'h0001: read_register = reg_ctrl;

                // WUC (0x05800) - Wake Up Control
                15'h1600: read_register = reg_wuc;

                // WUFC (0x05808) - Wake Up Filter Control
                15'h1602: read_register = reg_wufc;

                // WUS (0x05810) - Wake Up Status (read-clear)
                15'h1604: read_register = 32'h0;

                // EXTCNF_CTRL (0x00F00) - Extended Configuration Control
                // bit 5: MDIO_SW_OWNERSHIP, bit 6: MDIO_HW_OWNERSHIP
                15'h03C0: read_register = reg_extcnf_ctrl;

                // KABGTXD (0x0E004) - needed by some Windows drivers
                15'h3801: read_register = 32'h0;

                // PBA (0x01000) - Packet Buffer Allocation
                15'h0400: read_register = reg_pba;

                // PBECCSTS (0x0100C) - Packet Buffer ECC Status
                15'h0403: read_register = 32'h0;

                // RLPML (0x05004) - Receive Long Packet Maximum Length
                15'h1401: read_register = reg_rlpml;

                // --- I211 igb driver init required registers ---

                // EEMNGCTL (0x12030) - checked before EERD NVM reads
                15'h480C: read_register = 32'h0;

                // MDICNFG (0x00E04) - MDI Configuration (I210/I211)
                15'h0381: read_register = 32'h0000_0000;

                // CONNSW (0x00034) - Copper/Fiber Switch
                15'h000D: read_register = 32'h0;

                // EEC (0x12010) - I210/I211 EEPROM Control
                // Shadow of EECD register - must match EECD value
                // igb driver reads this on I210/I211 path
                // bit 8: EE_PRES = 1, bit 9: Auto-Read Done = 1
                // bit 19: FLASH_DETECTED_I210 = 1 (CRITICAL for NVM path)
                15'h4804: read_register = reg_eecd | 32'h0008_0300;

                // EEARBC_I210 (0x12024)
                15'h4809: read_register = 32'h0;

                // I210_FLSWCTL (0x12048) - Flash SW Access Control
                // igb checks bit[1] (DONE) before NVM operations
                15'h4812: read_register = 32'h0000_0002;

                // I210_FLSWCNT (0x12028) - Flash SW Count
                15'h480A: read_register = 32'h0;

                // BARCTRL (0x05BBC) - some paths check this
                15'h16EF: read_register = 32'h0;

                // TSYNCRXCTL (0x0B620) - Timestamp RX Control
                15'h2D88: read_register = reg_tsyncrxctl;

                // TSYNCTXCTL (0x0B614) - Timestamp TX Control
                15'h2D85: read_register = reg_tsynctxctl;

                // IVAR0 (0x01700) - Interrupt Vector Allocation
                15'h05C0: read_register = reg_ivar0;
                // IVAR_MISC (0x01740) - Misc Interrupt Vector
                15'h05D0: read_register = reg_ivar_misc;
                // GPIE (0x01514) - General Purpose Interrupt Enable
                15'h0545: read_register = reg_gpie;
                // EICR (0x01580) - Extended Interrupt Cause Read
                15'h0560: read_register = reg_eicr;
                // EICS (0x01520) - Extended Interrupt Cause Set
                15'h0548: read_register = reg_eics;
                // EIMS (0x01524) - Extended Interrupt Mask Set/Read
                15'h0549: read_register = reg_eims;
                // EIMC (0x01528) - Extended Interrupt Mask Clear (write-only, reads return EIMS)
                15'h054A: read_register = reg_eims;
                // EIAC (0x0152C) - Extended Interrupt Auto Clear
                15'h054B: read_register = reg_eiac;
                // EIAM (0x01530) - Extended Interrupt Auto Mask
                15'h054C: read_register = reg_eiam;

                // TXDCTL (0x03828) - TX Desc Control Q0
                // CRITICAL: igb driver writes ENABLE (bit25)=1, then polls until readback=1
                15'h0E0A: read_register = reg_txdctl0;
                // RXDCTL (0x02C28) - RX Desc Control Q0
                // CRITICAL: same enable-poll pattern as TXDCTL
                15'h0B0A: read_register = reg_rxdctl0;
                // SRRCTL0 (0x0C00C) - Split/Replication RX Control
                15'h3003: read_register = reg_srrctl0;

                // DTXCTL (0x03590) - DMA TX Control
                15'h0D64: read_register = reg_dtxctl;

                // DCA_RXCTRL (0x02814) - DCA RX Control Q0
                15'h0A05: read_register = reg_rxctl;

                // DCA_TXCTRL (0x0E014) - DCA TX Control Q0
                15'h3805: read_register = reg_txctl;

                // RAH1-RAH15 (0x05408-0x054FC) - Additional MAC filter entries
                // igb driver clears these during init; return 0 for all
                // RCTL (0x00100) alias check already handled
                // MTA (0x05200-0x053FC) - Multicast Table Array (128 entries)
                // Return 0 for all entries

                // VFTA (0x05600-0x057FC) - VLAN Filter Table (128 entries)
                // Return 0 for all

                // UTA (0x0A000-0x0A1FC) - Unicast Table Array (128 entries)
                // Return 0 for all

                default: begin
                    // MSI-X Table region: 0xE000 - 0xE04F (DW 0x3800 - 0x3813)
                    // 5 entries × 4 DW = 20 DWORDs
                    if (dw_offset >= DW_MSIX_TABLE_BASE && 
                        dw_offset < (DW_MSIX_TABLE_BASE + 15'd20)) begin
                        read_register = msix_table[dw_offset - DW_MSIX_TABLE_BASE];
                    end
                    // MSI-X PBA region: 0xE800 - 0xE807 (DW 0x3A00 - 0x3A01)
                    else if (dw_offset >= DW_MSIX_PBA_BASE && 
                             dw_offset < (DW_MSIX_PBA_BASE + 15'd2)) begin
                        read_register = msix_pba[dw_offset - DW_MSIX_PBA_BASE];
                    end
                    // MTA (0x05200-0x053FC) - Multicast Table Array (128 entries)
                    // igb_mta_set() / igb driver clears all 128 DWORDs
                    else if (dw_offset >= 15'h1480 && dw_offset < 15'h1500) begin
                        read_register = 32'h0;
                    end
                    // RAL/RAH (0x05400-0x054FC) - Receive Address array (16 entries × 2 DW)
                    // RAL0/RAH0 handled above; entries 1-15 return 0
                    else if (dw_offset >= 15'h1502 && dw_offset < 15'h1540) begin
                        read_register = 32'h0;
                    end
                    // VFTA (0x05600-0x057FC) - VLAN Filter Table (128 entries)
                    else if (dw_offset >= 15'h1580 && dw_offset < 15'h1600) begin
                        read_register = 32'h0;
                    end
                    // UTA (0x0A000-0x0A1FC) - Unicast Table Array (128 entries)
                    else if (dw_offset >= 15'h2800 && dw_offset < 15'h2880) begin
                        read_register = 32'h0;
                    end
                    // Statistics registers range (0x04000-0x040FC)
                    // igb driver reads many stat counters during init/reset
                    else if (dw_offset >= 15'h1000 && dw_offset < 15'h1040) begin
                        read_register = 32'h0;
                    end
                    // Statistics registers extended range (0x04100-0x041FC)
                    else if (dw_offset >= 15'h1040 && dw_offset < 15'h1080) begin
                        read_register = 32'h0;
                    end
                    else begin
                        // Unknown registers return 0x00000000
                        read_register = 32'h0000_0000;
                    end
                end
            endcase
        end
    endfunction

    // ===================================================================
    //  Register Write Logic
    // ===================================================================

    task write_register;
        input [14:0] dw_offset;
        input [31:0] data;
        input [ 3:0] be;
        begin
            case (dw_offset)
                DW_CTRL: begin
                    // Device Control - bit 26 (RST) needs special handling
                    if (be[0]) reg_ctrl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ctrl[15: 8] <= data[15: 8];
                    if (be[2]) reg_ctrl[23:16] <= data[23:16];
                    if (be[3]) begin
                        reg_ctrl[31:24] <= data[31:24];
                        // bit 26: Device Reset (RST) - self-clearing
                        if (data[26]) begin
                            reg_ctrl[26] <= 1'b0;
                            // Restore STATUS after reset:
                            // bit31=1(LU_ext), FD(bit0)=1, LU(bit1)=1,
                            // SPEED_1000(bit7)=1, GIO_MASTER(bit19)=1, PF_RST_DONE(bit21)=1
                            reg_status <= 32'h8028_0083;
                        end
                    end
                end

                DW_EECD: begin
                    // =========================================================
                    //  EECD 写入 - 完整 SPI bit-bang NVM 仿真
                    //  Windows e1r68x64.sys 驱动通过以下流程读取 NVM:
                    //    1. 写 EE_REQ(bit6)=1 -> 等待 EE_GNT(bit7)=1
                    //    2. 拉低 EE_CS(bit1) 选中 NVM
                    //    3. 通过 EE_SK(bit0) 时钟 + EE_DI(bit2) 数据
                    //       逐位发送 SPI 命令 (opcode + address)
                    //    4. 在 SK 上升沿从 EE_DO(bit3) 读取返回数据
                    //    5. 拉高 EE_CS, 清除 EE_REQ
                    //
                    //  关键: 必须正确响应 EE_REQ->EE_GNT 握手,
                    //        否则驱动超时 -> Code 10 / Code 56!
                    // =========================================================

                    // --- 保留驱动写入的可写位 ---
                    // bit[0] EE_SK, bit[1] EE_CS, bit[2] EE_DI, bit[6] EE_REQ
                    if (be[0]) begin
                        reg_eecd[2:0] <= data[2:0];  // SK, CS, DI
                        reg_eecd[6]   <= data[6];     // EE_REQ
                        // === EE_REQ / EE_GNT 握手 ===
                        // 驱动写 EE_REQ=1 -> 立即给予 EE_GNT=1
                        // 驱动写 EE_REQ=0 -> 撤销 EE_GNT=0
                        if (data[6])
                            reg_eecd[7] <= 1'b1;   // 立即授权 NVM 访问
                        else
                            reg_eecd[7] <= 1'b0;   // 释放授权
                    end
                    // 高位保持驱动写入 (部分位只读,在后续逻辑中强制覆盖)
                    if (be[1]) reg_eecd[15: 8] <= data[15: 8];
                    if (be[2]) reg_eecd[23:16] <= data[23:16];
                    if (be[3]) reg_eecd[31:24] <= data[31:24];

                    // === 强制保持只读位 ===
                    // bit[8]  EE_PRES = 1 (NVM Present)
                    // bit[9]  AUTO_RD = 1 (Auto Read Done)
                    // bit[19] FLASH_DETECTED_I210 = 1
                    reg_eecd[8]  <= 1'b1;
                    reg_eecd[9]  <= 1'b1;
                    reg_eecd[19] <= 1'b1;
                end

                DW_EERD: begin
                    // EEPROM Read: write triggers NVM read operation
                    // I211 EERD format:
                    //   bit[0]    : Start (write 1 to begin, self-clearing)
                    //   bit[1]    : Done (HW sets when read complete)
                    //   bit[15:2] : Address (NVM word address)
                    //   bit[31:16]: Data (NVM read data, valid when Done=1)
                    //
                    // Windows igb driver writes full DWORD (be=4'hF):
                    //   address in [15:2], Start=1 in [0]
                    // Must capture full address before triggering read
                    if (be[1]) reg_eerd[15: 8] <= data[15: 8];
                    if (be[0]) begin
                        reg_eerd[7:0] <= data[7:0];
                        if (data[0]) begin
                            eerd_pending   <= 1'b1;
                            eerd_delay_cnt <= 8'd4; // emulate NVM read latency
                            // Capture full 14-bit address from the write data
                            // (be[1] assignment above provides high byte)
                            reg_eerd[15:0] <= {data[15:2], 2'b01}; // addr + Start
                        end
                    end
                end

                DW_SRRD: begin
                    // I210/I211 Shadow RAM Read Register (0x12018)
                    // This is the PRIMARY NVM access path for I210/I211!
                    // igb driver calls igb_read_nvm_srrd_i210() which uses this
                    // Format same as EERD: bit[0]=Start, bit[1]=Done,
                    //   bit[15:2]=Address, bit[31:16]=Data
                    if (be[1]) reg_srrd[15: 8] <= data[15: 8];
                    if (be[0]) begin
                        reg_srrd[7:0] <= data[7:0];
                        if (data[0]) begin
                            srrd_pending   <= 1'b1;
                            srrd_delay_cnt <= 8'd3; // shadow RAM is slightly faster
                            reg_srrd[15:0] <= {data[15:2], 2'b01}; // addr + Start
                        end
                    end
                end

                DW_CTRL_EXT: begin
                    if (be[0]) reg_ctrl_ext[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ctrl_ext[15: 8] <= data[15: 8];
                    if (be[2]) reg_ctrl_ext[23:16] <= data[23:16];
                    if (be[3]) reg_ctrl_ext[31:24] <= data[31:24];
                end

                DW_MDIC: begin
                    // MDI Control: write triggers PHY read/write
                    // bit[15:0] : Data, bit[20:16]: PHY Address (ignored, single PHY)
                    // bit[25:21]: PHY Register, bit[27:26]: Op (01=write, 10=read)
                    // bit[28]: Ready (set by HW when done), bit[29]: Error
                    if (data[27:26] == 2'b10) begin
                        // PHY Read - immediate response with Ready=1
                        reg_mdic <= {2'b00, 1'b1, 1'b0, data[27:16],
                                     phy_read(data[25:21], phy_page_reg)};
                    end else if (data[27:26] == 2'b01) begin
                        // PHY Write - acknowledge with Ready=1
                        reg_mdic <= {2'b00, 1'b1, 1'b0, data[27:0]};
                        // Track page register writes (PHY reg 22)
                        if (data[25:21] == 5'h16) begin
                            phy_page_reg <= data[15:0];
                        end
                    end else begin
                        reg_mdic <= data;
                    end
                end

                DW_ICR: begin // Read-Clear in normal mode; here handle write
                    if (be[0]) reg_icr[ 7: 0] <= reg_icr[ 7: 0] & ~data[ 7: 0];
                    if (be[1]) reg_icr[15: 8] <= reg_icr[15: 8] & ~data[15: 8];
                    if (be[2]) reg_icr[23:16] <= reg_icr[23:16] & ~data[23:16];
                    if (be[3]) reg_icr[31:24] <= reg_icr[31:24] & ~data[31:24];
                end

                DW_ITR: begin
                    if (be[0]) reg_itr[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_itr[15: 8] <= data[15: 8];
                end

                DW_ICS: begin // Write-only: set interrupt cause bits
                    if (be[0]) reg_icr[ 7: 0] <= reg_icr[ 7: 0] | data[ 7: 0];
                    if (be[1]) reg_icr[15: 8] <= reg_icr[15: 8] | data[15: 8];
                    if (be[2]) reg_icr[23:16] <= reg_icr[23:16] | data[23:16];
                    if (be[3]) reg_icr[31:24] <= reg_icr[31:24] | data[31:24];
                end

                DW_IMS: begin // Write: set mask bits
                    if (be[0]) reg_ims[ 7: 0] <= reg_ims[ 7: 0] | data[ 7: 0];
                    if (be[1]) reg_ims[15: 8] <= reg_ims[15: 8] | data[15: 8];
                    if (be[2]) reg_ims[23:16] <= reg_ims[23:16] | data[23:16];
                    if (be[3]) reg_ims[31:24] <= reg_ims[31:24] | data[31:24];
                end

                DW_IMC: begin // Write: clear mask bits
                    if (be[0]) reg_ims[ 7: 0] <= reg_ims[ 7: 0] & ~data[ 7: 0];
                    if (be[1]) reg_ims[15: 8] <= reg_ims[15: 8] & ~data[15: 8];
                    if (be[2]) reg_ims[23:16] <= reg_ims[23:16] & ~data[23:16];
                    if (be[3]) reg_ims[31:24] <= reg_ims[31:24] & ~data[31:24];
                end

                DW_RCTL: begin
                    if (be[0]) reg_rctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_rctl[23:16] <= data[23:16];
                    if (be[3]) reg_rctl[31:24] <= data[31:24];
                end

                DW_TCTL: begin
                    if (be[0]) reg_tctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_tctl[23:16] <= data[23:16];
                    if (be[3]) reg_tctl[31:24] <= data[31:24];
                end

                // Flow Control
                DW_FCAL: begin
                    if (be[0]) reg_fcal[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_fcal[15: 8] <= data[15: 8];
                    if (be[2]) reg_fcal[23:16] <= data[23:16];
                    if (be[3]) reg_fcal[31:24] <= data[31:24];
                end
                DW_FCAH: begin
                    if (be[0]) reg_fcah[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_fcah[15: 8] <= data[15: 8];
                    if (be[2]) reg_fcah[23:16] <= data[23:16];
                    if (be[3]) reg_fcah[31:24] <= data[31:24];
                end
                DW_FCT: begin
                    if (be[0]) reg_fct[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_fct[15: 8] <= data[15: 8];
                end
                DW_FCTTV: begin
                    if (be[0]) reg_fcttv[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_fcttv[15: 8] <= data[15: 8];
                end

                // RX Descriptor Queue 0
                DW_RDBAL0: begin
                    if (be[0]) reg_rdbal0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rdbal0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rdbal0[23:16] <= data[23:16];
                    if (be[3]) reg_rdbal0[31:24] <= data[31:24];
                end
                DW_RDBAH0: begin
                    if (be[0]) reg_rdbah0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rdbah0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rdbah0[23:16] <= data[23:16];
                    if (be[3]) reg_rdbah0[31:24] <= data[31:24];
                end
                DW_RDLEN0: begin
                    if (be[0]) reg_rdlen0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rdlen0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rdlen0[23:16] <= data[23:16];
                    if (be[3]) reg_rdlen0[31:24] <= data[31:24];
                end
                DW_RDH0: begin
                    if (be[0]) reg_rdh0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rdh0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rdh0[23:16] <= data[23:16];
                    if (be[3]) reg_rdh0[31:24] <= data[31:24];
                end
                DW_RDT0: begin
                    if (be[0]) reg_rdt0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rdt0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rdt0[23:16] <= data[23:16];
                    if (be[3]) reg_rdt0[31:24] <= data[31:24];
                end

                // TX Descriptor Queue 0
                DW_TDBAL0: begin
                    if (be[0]) reg_tdbal0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tdbal0[15: 8] <= data[15: 8];
                    if (be[2]) reg_tdbal0[23:16] <= data[23:16];
                    if (be[3]) reg_tdbal0[31:24] <= data[31:24];
                end
                DW_TDBAH0: begin
                    if (be[0]) reg_tdbah0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tdbah0[15: 8] <= data[15: 8];
                    if (be[2]) reg_tdbah0[23:16] <= data[23:16];
                    if (be[3]) reg_tdbah0[31:24] <= data[31:24];
                end
                DW_TDLEN0: begin
                    if (be[0]) reg_tdlen0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tdlen0[15: 8] <= data[15: 8];
                    if (be[2]) reg_tdlen0[23:16] <= data[23:16];
                    if (be[3]) reg_tdlen0[31:24] <= data[31:24];
                end
                DW_TDH0: begin
                    if (be[0]) reg_tdh0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tdh0[15: 8] <= data[15: 8];
                    if (be[2]) reg_tdh0[23:16] <= data[23:16];
                    if (be[3]) reg_tdh0[31:24] <= data[31:24];
                end
                DW_TDT0: begin
                    if (be[0]) reg_tdt0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tdt0[15: 8] <= data[15: 8];
                    if (be[2]) reg_tdt0[23:16] <= data[23:16];
                    if (be[3]) reg_tdt0[31:24] <= data[31:24];
                end

                // MAC Address
                DW_RAL0: begin
                    if (be[0]) reg_ral0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ral0[15: 8] <= data[15: 8];
                    if (be[2]) reg_ral0[23:16] <= data[23:16];
                    if (be[3]) reg_ral0[31:24] <= data[31:24];
                end
                DW_RAH0: begin
                    if (be[0]) reg_rah0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rah0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rah0[23:16] <= data[23:16];
                    if (be[3]) reg_rah0[31:24] <= data[31:24];
                end

                // Firmware
                DW_FWSM: begin
                    if (be[0]) reg_fwsm[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_fwsm[15: 8] <= data[15: 8];
                    if (be[2]) reg_fwsm[23:16] <= data[23:16];
                    if (be[3]) reg_fwsm[31:24] <= data[31:24];
                end

                // SWSM (0x05B50) - Software Semaphore Write
                // igb driver: e1000_get_hw_semaphore_82575()
                //   - Writes SMBI (bit 0) = 1, reads back, expects 1
                //   - Writes SWESMBI (bit 1) = 1, reads back, expects 1
                // We immediately accept whatever the driver writes, so
                // the read-back will always succeed (semaphore always granted)
                15'h16D4: begin
                    if (be[0]) reg_swsm[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_swsm[15: 8] <= data[15: 8];
                    if (be[2]) reg_swsm[23:16] <= data[23:16];
                    if (be[3]) reg_swsm[31:24] <= data[31:24];
                end

                DW_SW_FW_SYNC: begin
                    if (be[0]) reg_sw_fw_sync[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_sw_fw_sync[15: 8] <= data[15: 8];
                    if (be[2]) reg_sw_fw_sync[23:16] <= data[23:16];
                    if (be[3]) reg_sw_fw_sync[31:24] <= data[31:24];
                end

                // ============================================================
                //  I211 Extended Interrupt Registers (igb driver MSI-X path)
                // ============================================================

                // GPIE (0x01514) - General Purpose Interrupt Enable
                15'h0545: begin
                    if (be[0]) reg_gpie[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_gpie[15: 8] <= data[15: 8];
                    if (be[2]) reg_gpie[23:16] <= data[23:16];
                    if (be[3]) reg_gpie[31:24] <= data[31:24];
                end

                // EICR (0x01580) - Extended Interrupt Cause Read (write-1-to-clear)
                15'h0560: begin
                    if (be[0]) reg_eicr[ 7: 0] <= reg_eicr[ 7: 0] & ~data[ 7: 0];
                    if (be[1]) reg_eicr[15: 8] <= reg_eicr[15: 8] & ~data[15: 8];
                    if (be[2]) reg_eicr[23:16] <= reg_eicr[23:16] & ~data[23:16];
                    if (be[3]) reg_eicr[31:24] <= reg_eicr[31:24] & ~data[31:24];
                end

                // EICS (0x01520) - Extended Interrupt Cause Set (write-only, sets EICR bits)
                15'h0548: begin
                    if (be[0]) reg_eicr[ 7: 0] <= reg_eicr[ 7: 0] | data[ 7: 0];
                    if (be[1]) reg_eicr[15: 8] <= reg_eicr[15: 8] | data[15: 8];
                    if (be[2]) reg_eicr[23:16] <= reg_eicr[23:16] | data[23:16];
                    if (be[3]) reg_eicr[31:24] <= reg_eicr[31:24] | data[31:24];
                end

                // EIMS (0x01524) - Extended Interrupt Mask Set (write-1-to-set)
                15'h0549: begin
                    if (be[0]) reg_eims[ 7: 0] <= reg_eims[ 7: 0] | data[ 7: 0];
                    if (be[1]) reg_eims[15: 8] <= reg_eims[15: 8] | data[15: 8];
                    if (be[2]) reg_eims[23:16] <= reg_eims[23:16] | data[23:16];
                    if (be[3]) reg_eims[31:24] <= reg_eims[31:24] | data[31:24];
                end

                // EIMC (0x01528) - Extended Interrupt Mask Clear (write-1-to-clear)
                15'h054A: begin
                    if (be[0]) reg_eims[ 7: 0] <= reg_eims[ 7: 0] & ~data[ 7: 0];
                    if (be[1]) reg_eims[15: 8] <= reg_eims[15: 8] & ~data[15: 8];
                    if (be[2]) reg_eims[23:16] <= reg_eims[23:16] & ~data[23:16];
                    if (be[3]) reg_eims[31:24] <= reg_eims[31:24] & ~data[31:24];
                end

                // EIAC (0x0152C) - Extended Interrupt Auto Clear
                15'h054B: begin
                    if (be[0]) reg_eiac[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_eiac[15: 8] <= data[15: 8];
                    if (be[2]) reg_eiac[23:16] <= data[23:16];
                    if (be[3]) reg_eiac[31:24] <= data[31:24];
                end

                // EIAM (0x01530) - Extended Interrupt Auto Mask
                15'h054C: begin
                    if (be[0]) reg_eiam[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_eiam[15: 8] <= data[15: 8];
                    if (be[2]) reg_eiam[23:16] <= data[23:16];
                    if (be[3]) reg_eiam[31:24] <= data[31:24];
                end

                // IVAR0 (0x01700) - Interrupt Vector Allocation Q0
                15'h05C0: begin
                    if (be[0]) reg_ivar0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ivar0[15: 8] <= data[15: 8];
                    if (be[2]) reg_ivar0[23:16] <= data[23:16];
                    if (be[3]) reg_ivar0[31:24] <= data[31:24];
                end

                // IVAR_MISC (0x01740) - Misc Interrupt Vector
                15'h05D0: begin
                    if (be[0]) reg_ivar_misc[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ivar_misc[15: 8] <= data[15: 8];
                    if (be[2]) reg_ivar_misc[23:16] <= data[23:16];
                    if (be[3]) reg_ivar_misc[31:24] <= data[31:24];
                end

                // ============================================================
                //  RX/TX Descriptor Control (Queue 0) - CRITICAL for igb!
                //  igb driver writes ENABLE (bit 25) = 1, then polls until
                //  readback shows bit 25 = 1. If never set -> timeout -> fail!
                // ============================================================

                // RXDCTL (0x02C28) - RX Desc Control Q0
                15'h0B0A: begin
                    if (be[0]) reg_rxdctl0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rxdctl0[15: 8] <= data[15: 8];
                    if (be[2]) reg_rxdctl0[23:16] <= data[23:16];
                    if (be[3]) reg_rxdctl0[31:24] <= data[31:24];
                    // ENABLE bit (25) - immediately reflect as enabled
                    // igb_configure_rx_ring() writes ENABLE then polls
                end

                // TXDCTL (0x03828) - TX Desc Control Q0
                15'h0E0A: begin
                    if (be[0]) reg_txdctl0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_txdctl0[15: 8] <= data[15: 8];
                    if (be[2]) reg_txdctl0[23:16] <= data[23:16];
                    if (be[3]) reg_txdctl0[31:24] <= data[31:24];
                    // ENABLE bit (25) - immediately reflect as enabled
                end

                // SRRCTL (0x0C00C) - Split/Replication RX Control Q0
                15'h3003: begin
                    if (be[0]) reg_srrctl0[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_srrctl0[15: 8] <= data[15: 8];
                    if (be[2]) reg_srrctl0[23:16] <= data[23:16];
                    if (be[3]) reg_srrctl0[31:24] <= data[31:24];
                end

                // DTXCTL (0x03590) - DMA TX Control
                15'h0D64: begin
                    if (be[0]) reg_dtxctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_dtxctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_dtxctl[23:16] <= data[23:16];
                    if (be[3]) reg_dtxctl[31:24] <= data[31:24];
                end

                // DCA_RXCTRL (0x02814) - DCA RX Control Q0
                15'h0A05: begin
                    if (be[0]) reg_rxctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rxctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_rxctl[23:16] <= data[23:16];
                    if (be[3]) reg_rxctl[31:24] <= data[31:24];
                end

                // DCA_TXCTRL (0x0E014) - DCA TX Control Q0
                15'h3805: begin
                    if (be[0]) reg_txctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_txctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_txctl[23:16] <= data[23:16];
                    if (be[3]) reg_txctl[31:24] <= data[31:24];
                end

                // ============================================================
                //  Wake-Up, Power, EXTCNF, RLPML, PBA 等可写寄存器
                // ============================================================

                // WUC (0x05800)
                15'h1600: begin
                    if (be[0]) reg_wuc[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_wuc[15: 8] <= data[15: 8];
                    if (be[2]) reg_wuc[23:16] <= data[23:16];
                    if (be[3]) reg_wuc[31:24] <= data[31:24];
                end

                // WUFC (0x05808)
                15'h1602: begin
                    if (be[0]) reg_wufc[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_wufc[15: 8] <= data[15: 8];
                    if (be[2]) reg_wufc[23:16] <= data[23:16];
                    if (be[3]) reg_wufc[31:24] <= data[31:24];
                end

                // EXTCNF_CTRL (0x00F00)
                15'h03C0: begin
                    if (be[0]) reg_extcnf_ctrl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_extcnf_ctrl[15: 8] <= data[15: 8];
                    if (be[2]) reg_extcnf_ctrl[23:16] <= data[23:16];
                    if (be[3]) reg_extcnf_ctrl[31:24] <= data[31:24];
                end

                // PBA (0x01000)
                15'h0400: begin
                    if (be[0]) reg_pba[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_pba[15: 8] <= data[15: 8];
                    if (be[2]) reg_pba[23:16] <= data[23:16];
                    if (be[3]) reg_pba[31:24] <= data[31:24];
                end

                // RLPML (0x05004)
                15'h1401: begin
                    if (be[0]) reg_rlpml[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_rlpml[15: 8] <= data[15: 8];
                    if (be[2]) reg_rlpml[23:16] <= data[23:16];
                    if (be[3]) reg_rlpml[31:24] <= data[31:24];
                end

                // TSYNCRXCTL (0x0B620)
                15'h2D88: begin
                    if (be[0]) reg_tsyncrxctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tsyncrxctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_tsyncrxctl[23:16] <= data[23:16];
                    if (be[3]) reg_tsyncrxctl[31:24] <= data[31:24];
                end

                // TSYNCTXCTL (0x0B614)
                15'h2D85: begin
                    if (be[0]) reg_tsynctxctl[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_tsynctxctl[15: 8] <= data[15: 8];
                    if (be[2]) reg_tsynctxctl[23:16] <= data[23:16];
                    if (be[3]) reg_tsynctxctl[31:24] <= data[31:24];
                end

                // MANC (0x05820) - Management Control (writable, store value)
                15'h1608: begin
                    // Accept writes but don't affect behavior
                end

                default: begin
                    // MSI-X Table writes: 0xE000 - 0xE04F (DW 0x3800 - 0x3813)
                    if (dw_offset >= DW_MSIX_TABLE_BASE && 
                        dw_offset < (DW_MSIX_TABLE_BASE + 15'd20)) begin
                        if (be[0]) msix_table[dw_offset - DW_MSIX_TABLE_BASE][ 7: 0] <= data[ 7: 0];
                        if (be[1]) msix_table[dw_offset - DW_MSIX_TABLE_BASE][15: 8] <= data[15: 8];
                        if (be[2]) msix_table[dw_offset - DW_MSIX_TABLE_BASE][23:16] <= data[23:16];
                        if (be[3]) msix_table[dw_offset - DW_MSIX_TABLE_BASE][31:24] <= data[31:24];
                    end
                    // MSI-X PBA is read-only (HW managed), writes ignored
                end
            endcase
        end
    endtask

    // ===================================================================
    //  TLP Parser State Machine (reuses HDA version framework)
    // ===================================================================

    localparam [4:0] ST_IDLE          = 5'd0,
                     ST_RX_HDR1       = 5'd1,
                     ST_RX_DATA       = 5'd2,
                     ST_TX_CPL0       = 5'd4,
                     ST_RX_DRAIN      = 5'd7,
                     ST_TX_UR0        = 5'd8,
                     ST_RX_MWR4_DATA  = 5'd10,
                     ST_TX_CPL0_W     = 5'd11,
                     ST_TX_CPL1_W     = 5'd12,
                     ST_TX_UR0_W      = 5'd13,
                     ST_TX_UR1_W      = 5'd14,
                     ST_RX_DRAIN_POST = 5'd15,
                     ST_RX_DRAIN_UR   = 5'd16;

    reg [4:0] state;

    // Latched TLP Header fields
    reg [ 1:0] lat_fmt;
    reg [ 4:0] lat_type;
    reg [ 2:0] lat_tc;
    reg [ 9:0] lat_length;
    reg [15:0] lat_requester_id;
    reg [ 7:0] lat_tag;
    reg [ 3:0] lat_first_be;
    reg [ 3:0] lat_last_be;
    reg [31:0] lat_addr;
    reg [31:0] lat_wr_data;

    wire is_mrd_3dw = (lat_fmt == 2'b00) && (lat_type == 5'b00000);
    wire is_mrd_4dw = (lat_fmt == 2'b01) && (lat_type == 5'b00000);
    wire is_mwr_3dw = (lat_fmt == 2'b10) && (lat_type == 5'b00000);
    wire is_mwr_4dw = (lat_fmt == 2'b11) && (lat_type == 5'b00000);

    reg [31:0] reg_rd_data;
    reg        rx_tlast_seen;

    // ===================================================================
    //  CplD TLP Construction
    // ===================================================================

    wire [11:0] byte_count = (lat_length == 10'd1) ? 12'd4 : {lat_length, 2'b00};
    wire [ 6:0] lower_addr = {lat_addr[6:2], 2'b00};

    wire [31:0] cpld_dw0 = {
        1'b0, 2'b10, 5'b01010,
        1'b0, lat_tc, 4'b0000,
        1'b0, 1'b0, 2'b00, 2'b00,
        lat_length
    };

    wire [31:0] cpld_dw1 = {
        completer_id,
        3'b000, 1'b0,
        byte_count
    };

    wire [31:0] cpld_dw2 = {
        lat_requester_id,
        lat_tag,
        1'b0, lower_addr
    };

    // UR Completion
    wire [31:0] ur_dw0 = {
        1'b0, 2'b00, 5'b01010,
        1'b0, lat_tc, 4'b0000,
        1'b0, 1'b0, 2'b00, 2'b00,
        10'd0
    };

    wire [31:0] ur_dw1 = {
        completer_id,
        3'b001, 1'b0,
        12'd0
    };

    wire [31:0] ur_dw2 = {
        lat_requester_id,
        lat_tag,
        8'h00
    };

    // ===================================================================
    //  Main State Machine
    // ===================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            m_axis_rx_tready <= 1'b1;
            s_axis_tx_tdata  <= 64'h0;
            s_axis_tx_tkeep  <= 8'h0;
            s_axis_tx_tlast  <= 1'b0;
            s_axis_tx_tvalid <= 1'b0;
            s_axis_tx_tuser  <= 4'h0;
            reg_rd_data      <= 32'h0;
            rx_tlast_seen    <= 1'b0;

            // I211 Register Initialization
            // CTRL: default - FD (Full Duplex), ASDE, SLU (Set Link Up)
            reg_ctrl       <= 32'h0004_0040;

            // STATUS: I211 Device Status Register (0x0008)
            // === 用户要求 ===
            //   Bit 31 = 1 (Link Up indicator for Windows driver)
            //   Bit  1 = 1 (Full Duplex)
            // === 标准 igb 位域 ===
            //   bit  0: FD (Full Duplex) = 1
            //   bit  1: LU (Link Up) = 1  ** CRITICAL: driver checks this **
            //   bit[7:6]: SPEED = 10b (1000Mbps)
            //     E1000_STATUS_SPEED_1000 = 0x80 (bit 7)
            //   bit 19: GIO_MASTER_ENABLE = 1 (Bus Master active)
            //   bit 21: PF_RST_DONE = 1 (driver polls this to confirm reset done)
            // === 综合值 ===
            //   0x80280083 = bit31 + PF_RST_DONE + GIO_MASTER + SPEED_1000 + LU + FD
            reg_status     <= 32'h8028_0083;

            // EECD: initial state - matching real I211
            // bit 8: EE_PRES (NVM Present) = 1
            // bit 9: Auto-Read Done = 1
            // bit 11: Reserved/size = 1
            // bit 13: Reserved = 1
            // bit 19: FLASH_DETECTED_I210 = 1 (CRITICAL!)
            //   igb driver calls igb_get_flash_presence_i210() which reads
            //   EECD bit 19. If set, driver uses EERD path with NVM checksum.
            //   If clear, driver uses iNVM path (more complex to emulate).
            reg_eecd       <= 32'h0008_2B00;

            // EECD SPI bit-bang 状态机初始化
            eecd_spi_bit_cnt   <= 5'd0;
            eecd_spi_state     <= SPI_IDLE;
            eecd_spi_shift_in  <= 16'h0;
            eecd_spi_shift_out <= 16'h0;
            eecd_sk_prev       <= 1'b0;
            eecd_cs_prev       <= 1'b0;
            eecd_spi_opcode    <= 8'h0;
            eecd_spi_addr      <= 16'h0;

            reg_eerd       <= 32'h0;
            reg_ctrl_ext   <= 32'h0004_0000; // DRV_LOAD

            // MDIC: initial idle, Ready=1
            reg_mdic       <= 32'h1000_0000; // bit 28: Ready

            reg_icr        <= 32'h0;
            reg_itr        <= 32'h0;
            reg_ims        <= 32'h0;
            reg_rctl       <= 32'h0;
            reg_tctl       <= 32'h0;

            reg_rdbal0     <= 32'h0;
            reg_rdbah0     <= 32'h0;
            reg_rdlen0     <= 32'h0;
            reg_rdh0       <= 32'h0;
            reg_rdt0       <= 32'h0;

            reg_tdbal0     <= 32'h0;
            reg_tdbah0     <= 32'h0;
            reg_tdlen0     <= 32'h0;
            reg_tdh0       <= 32'h0;
            reg_tdt0       <= 32'h0;

            reg_fcal       <= 32'h0;
            reg_fcah       <= 32'h0;
            reg_fct        <= 32'h0;
            reg_fcttv      <= 32'h0;

            // MAC Address: fixed valid MAC per user requirement
            // RAL0 = 0xAABBCCDD -> MAC bytes [3:0] = DD:CC:BB:AA
            // RAH0 = 0x8000EEFF -> AV=1, MAC bytes [5:4] = FF:EE
            // Full MAC = DD:CC:BB:AA:FF:EE (as seen by driver)
            reg_ral0       <= 32'hAABB_CCDD;
            reg_rah0       <= 32'h8000_EEFF;  // bit31=AV(Address Valid), MAC[5:4]=EEFF

            reg_fwsm       <= 32'h0000_00E0; // FW Mode = valid, FW Valid Done
            reg_sw_fw_sync <= 32'h0;
            reg_swsm       <= 32'h0;  // Semaphore initially free

            // --- I211 Extended Interrupt Registers init ---
            reg_gpie       <= 32'h0;
            reg_eicr       <= 32'h0;
            reg_eics       <= 32'h0;
            reg_eims       <= 32'h0;
            reg_eimc       <= 32'h0;
            reg_eiac       <= 32'h0;
            reg_eiam       <= 32'h0;
            reg_ivar0      <= 32'h0;
            reg_ivar_misc  <= 32'h0;

            // --- RX/TX Descriptor Control Q0 init ---
            // Default: PTHRESH=0, HTHRESH=0, WTHRESH=1 (conservative)
            // ENABLE (bit 25) = 0 initially
            reg_rxdctl0    <= 32'h0002_0000;  // WTHRESH=1 in reset default
            reg_txdctl0    <= 32'h0002_0000;  // WTHRESH=1 in reset default
            reg_srrctl0    <= 32'h0000_0002;  // BSIZEPACKET default (2KB)
            reg_rxctl      <= 32'h0;
            reg_txctl      <= 32'h0;
            reg_dtxctl     <= 32'h0;

            // --- Wake-Up, Packet Buffer, etc. ---
            reg_wuc        <= 32'h0;
            reg_wufc       <= 32'h0;
            reg_pba        <= 32'h001E_0014;  // 30KB RX, 20KB TX (I211 typical)
            reg_rlpml      <= 32'h0000_0600;  // 1536 bytes
            reg_extcnf_ctrl <= 32'h0000_0020; // SW has MDIO ownership (bit 5)
            reg_tsyncrxctl <= 32'h0;
            reg_tsynctxctl <= 32'h0;

            eerd_pending   <= 1'b0;
            eerd_delay_cnt <= 8'h0;
            phy_page_reg   <= 16'h0000;
            reg_srrd       <= 32'h0;
            srrd_pending   <= 1'b0;
            srrd_delay_cnt <= 8'h0;

            // MSI-X Table init: 5 entries, all masked (Vector Control bit 0 = 1)
            // Each entry: Addr Low=0, Addr High=0, Data=0, VectorCtrl=1(masked)
            msix_table[0]  <= 32'h0; msix_table[1]  <= 32'h0;
            msix_table[2]  <= 32'h0; msix_table[3]  <= 32'h0000_0001;
            msix_table[4]  <= 32'h0; msix_table[5]  <= 32'h0;
            msix_table[6]  <= 32'h0; msix_table[7]  <= 32'h0000_0001;
            msix_table[8]  <= 32'h0; msix_table[9]  <= 32'h0;
            msix_table[10] <= 32'h0; msix_table[11] <= 32'h0000_0001;
            msix_table[12] <= 32'h0; msix_table[13] <= 32'h0;
            msix_table[14] <= 32'h0; msix_table[15] <= 32'h0000_0001;
            msix_table[16] <= 32'h0; msix_table[17] <= 32'h0;
            msix_table[18] <= 32'h0; msix_table[19] <= 32'h0000_0001;
            // MSI-X PBA: no pending interrupts
            msix_pba[0]    <= 32'h0;
            msix_pba[1]    <= 32'h0;

            lat_fmt          <= 2'b0;
            lat_type         <= 5'b0;
            lat_tc           <= 3'b0;
            lat_length       <= 10'b0;
            lat_requester_id <= 16'b0;
            lat_tag          <= 8'b0;
            lat_first_be     <= 4'b0;
            lat_last_be      <= 4'b0;
            lat_addr         <= 32'b0;
            lat_wr_data      <= 32'b0;

        end else begin

            case (state)

                ST_IDLE: begin
                    s_axis_tx_tvalid <= 1'b0;
                    m_axis_rx_tready <= 1'b1;
                    rx_tlast_seen    <= 1'b0;

                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        lat_fmt    <= m_axis_rx_tdata[30:29];
                        lat_type   <= m_axis_rx_tdata[28:24];
                        lat_tc     <= m_axis_rx_tdata[22:20];
                        lat_length <= m_axis_rx_tdata[ 9: 0];
                        lat_requester_id <= m_axis_rx_tdata[63:48];
                        lat_tag          <= m_axis_rx_tdata[47:40];
                        lat_last_be      <= m_axis_rx_tdata[39:36];
                        lat_first_be     <= m_axis_rx_tdata[35:32];
                        rx_tlast_seen    <= m_axis_rx_tlast;
                        state <= ST_RX_HDR1;
                    end
                end

                ST_RX_HDR1: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin

                        if (is_mrd_3dw) begin
                            lat_addr <= {m_axis_rx_tdata[31:2], 2'b00};
                            reg_rd_data <= read_register(m_axis_rx_tdata[16:2]);
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (m_axis_rx_tlast) begin
                                m_axis_rx_tready <= 1'b0;
                                state <= ST_TX_CPL0;
                            end else begin
                                state <= ST_RX_DRAIN;
                            end

                        end else if (is_mrd_4dw) begin
                            lat_addr <= {m_axis_rx_tdata[63:34], 2'b00};
                            reg_rd_data <= read_register(m_axis_rx_tdata[48:34]);
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (m_axis_rx_tlast) begin
                                m_axis_rx_tready <= 1'b0;
                                state <= ST_TX_CPL0;
                            end else begin
                                state <= ST_RX_DRAIN;
                            end

                        end else if (is_mwr_3dw) begin
                            lat_addr    <= {m_axis_rx_tdata[31:2], 2'b00};
                            lat_wr_data <= m_axis_rx_tdata[63:32];
                            rx_tlast_seen <= m_axis_rx_tlast;
                            state <= ST_RX_DATA;

                        end else if (is_mwr_4dw) begin
                            lat_addr <= {m_axis_rx_tdata[63:34], 2'b00};
                            rx_tlast_seen <= m_axis_rx_tlast;
                            state <= ST_RX_MWR4_DATA;

                        end else begin
                            rx_tlast_seen <= m_axis_rx_tlast;
                            if (lat_fmt[1] == 1'b0 && lat_type != 5'b00000) begin
                                if (m_axis_rx_tlast) begin
                                    m_axis_rx_tready <= 1'b0;
                                    state <= ST_TX_UR0;
                                end else begin
                                    state <= ST_RX_DRAIN_UR;
                                end
                            end else begin
                                if (m_axis_rx_tlast)
                                    state <= ST_IDLE;
                                else
                                    state <= ST_RX_DRAIN_POST;
                            end
                        end
                    end
                end

                ST_RX_DATA: begin
                    write_register(lat_addr[16:2], lat_wr_data, lat_first_be);
                    if (rx_tlast_seen)
                        state <= ST_IDLE;
                    else
                        state <= ST_RX_DRAIN_POST;
                end

                ST_RX_MWR4_DATA: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                        lat_wr_data <= m_axis_rx_tdata[31:0];
                        rx_tlast_seen <= m_axis_rx_tlast;
                        state <= ST_RX_DATA;
                    end
                end

                ST_RX_DRAIN: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        m_axis_rx_tready <= 1'b0;
                        state <= ST_TX_CPL0;
                    end
                end

                ST_RX_DRAIN_POST: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        state <= ST_IDLE;
                    end
                end

                ST_RX_DRAIN_UR: begin
                    if (m_axis_rx_tvalid && m_axis_rx_tready && m_axis_rx_tlast) begin
                        m_axis_rx_tready <= 1'b0;
                        state <= ST_TX_UR0;
                    end
                end

                ST_TX_CPL0: begin
                    s_axis_tx_tdata  <= {cpld_dw1, cpld_dw0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;
                    state <= ST_TX_CPL0_W;
                end

                ST_TX_CPL0_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tdata  <= {reg_rd_data, cpld_dw2};
                        s_axis_tx_tkeep  <= 8'hFF;
                        s_axis_tx_tlast  <= 1'b1;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tuser  <= 4'b0000;
                        state <= ST_TX_CPL1_W;
                    end
                end

                ST_TX_CPL1_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                ST_TX_UR0: begin
                    s_axis_tx_tdata  <= {ur_dw1, ur_dw0};
                    s_axis_tx_tkeep  <= 8'hFF;
                    s_axis_tx_tlast  <= 1'b0;
                    s_axis_tx_tvalid <= 1'b1;
                    s_axis_tx_tuser  <= 4'b0000;
                    state <= ST_TX_UR0_W;
                end

                ST_TX_UR0_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tdata  <= {32'h0, ur_dw2};
                        s_axis_tx_tkeep  <= 8'h0F;
                        s_axis_tx_tlast  <= 1'b1;
                        s_axis_tx_tvalid <= 1'b1;
                        s_axis_tx_tuser  <= 4'b0000;
                        state <= ST_TX_UR1_W;
                    end
                end

                ST_TX_UR1_W: begin
                    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
                        s_axis_tx_tvalid <= 1'b0;
                        s_axis_tx_tlast  <= 1'b0;
                        m_axis_rx_tready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            // ---- EEPROM Read Emulation Delay ----
            if (eerd_pending) begin
                if (eerd_delay_cnt > 8'd0) begin
                    eerd_delay_cnt <= eerd_delay_cnt - 8'd1;
                end else begin
                    // Read complete: bit 1 (DONE) = 1, data in [31:16]
                    // For word 0x3F (checksum) use dynamically computed value
                    if (reg_eerd[15:2] == 14'h3F)
                        reg_eerd <= {nvm_checksum_word, reg_eerd[15:2], 1'b1, 1'b0};
                    else
                        reg_eerd <= {eeprom_read(reg_eerd[15:2]), reg_eerd[15:2], 1'b1, 1'b0};
                    eerd_pending <= 1'b0;
                end
            end

            // ---- I210/I211 Shadow RAM Read (SRRD) Emulation Delay ----
            // This is the PRIMARY NVM read path igb driver uses on I210/I211
            if (srrd_pending) begin
                if (srrd_delay_cnt > 8'd0) begin
                    srrd_delay_cnt <= srrd_delay_cnt - 8'd1;
                end else begin
                    // Read complete: bit 1 (DONE) = 1, data in [31:16]
                    if (reg_srrd[15:2] == 14'h3F)
                        reg_srrd <= {nvm_checksum_word, reg_srrd[15:2], 1'b1, 1'b0};
                    else
                        reg_srrd <= {eeprom_read(reg_srrd[15:2]), reg_srrd[15:2], 1'b1, 1'b0};
                    srrd_pending <= 1'b0;
                end
            end

            // ---- EECD SPI Bit-Bang NVM 仿真状态机 ----
            // Windows e1r68x64.sys 驱动可能通过 EECD 的 bit-bang SPI 方式读取 NVM
            // 协议: CS拉低 -> 8bit opcode -> 8/16bit addr -> 16bit data out -> CS拉高
            //
            // SPI NVM Read opcode = 0x03 (READ)
            // SPI NVM Read Status = 0x05 (RDSR)
            // 地址可以是 8-bit 或 16-bit 取决于 NVM 大小
            //
            // 时序: 在 EE_SK 上升沿采样 EE_DI (输入到 NVM)
            //       在 EE_SK 上升沿驱动 EE_DO (输出到驱动)
            begin : eecd_spi_fsm
                reg eecd_sk_rising;
                reg eecd_cs_falling;
                reg eecd_cs_rising;

                eecd_sk_rising  = reg_eecd[0] & ~eecd_sk_prev;
                eecd_cs_falling = ~reg_eecd[1] & eecd_cs_prev;   // CS active low
                eecd_cs_rising  = reg_eecd[1] & ~eecd_cs_prev;   // CS deselect

                eecd_sk_prev <= reg_eecd[0];
                eecd_cs_prev <= reg_eecd[1];

                case (eecd_spi_state)
                    SPI_IDLE: begin
                        reg_eecd[3] <= 1'b1;  // EE_DO default high (no data)
                        eecd_spi_bit_cnt <= 5'd0;
                        if (eecd_cs_falling) begin
                            // CS 拉低 = NVM 选中, 开始接收 opcode
                            eecd_spi_state   <= SPI_OPCODE;
                            eecd_spi_bit_cnt <= 5'd0;
                            eecd_spi_shift_in <= 16'h0;
                        end
                    end

                    SPI_OPCODE: begin
                        if (eecd_cs_rising) begin
                            eecd_spi_state <= SPI_IDLE;
                        end else if (eecd_sk_rising) begin
                            // 在 SK 上升沿采样 DI, MSB first
                            eecd_spi_shift_in <= {eecd_spi_shift_in[14:0], reg_eecd[2]};
                            eecd_spi_bit_cnt  <= eecd_spi_bit_cnt + 5'd1;

                            if (eecd_spi_bit_cnt == 5'd7) begin
                                // 收到完整的 8-bit opcode
                                eecd_spi_opcode <= {eecd_spi_shift_in[6:0], reg_eecd[2]};
                                eecd_spi_bit_cnt <= 5'd0;
                                eecd_spi_shift_in <= 16'h0;

                                // 根据 opcode 决定下一步
                                if ({eecd_spi_shift_in[6:0], reg_eecd[2]} == 8'h03) begin
                                    // READ 命令 -> 接收地址
                                    eecd_spi_state <= SPI_ADDR;
                                end else if ({eecd_spi_shift_in[6:0], reg_eecd[2]} == 8'h05) begin
                                    // RDSR (Read Status Register) -> 返回 status = 0x00 (ready)
                                    eecd_spi_shift_out <= 16'h0000;
                                    eecd_spi_bit_cnt   <= 5'd0;
                                    eecd_spi_state     <= SPI_DATA_OUT;
                                end else begin
                                    // 其他 opcode (WREN=0x06, WRITE=0x02 等) -> 静默忽略
                                    eecd_spi_state <= SPI_DONE;
                                end
                            end
                        end
                    end

                    SPI_ADDR: begin
                        if (eecd_cs_rising) begin
                            eecd_spi_state <= SPI_IDLE;
                        end else if (eecd_sk_rising) begin
                            eecd_spi_shift_in <= {eecd_spi_shift_in[14:0], reg_eecd[2]};
                            eecd_spi_bit_cnt  <= eecd_spi_bit_cnt + 5'd1;

                            // I211 NVM 使用 8-bit 地址 (byte address)
                            // word address = byte_addr[7:1] (右移1位)
                            if (eecd_spi_bit_cnt == 5'd7) begin
                                // 收到完整 8-bit byte address
                                // byte_addr = {shift_in[6:0], current_di_bit}
                                eecd_spi_addr <= {8'h00, eecd_spi_shift_in[6:0], reg_eecd[2]};
                                eecd_spi_bit_cnt <= 5'd0;

                                // 计算 word address = byte_addr[7:1]
                                // byte_addr[7:1] = {shift_in[6:0]} (去掉最低位 reg_eecd[2])
                                // 对 word 0x3F 使用动态校验和
                                if (eecd_spi_shift_in[6:0] == 7'h3F)
                                    eecd_spi_shift_out <= nvm_checksum_word;
                                else
                                    eecd_spi_shift_out <= eeprom_read({7'h0, eecd_spi_shift_in[6:0]});

                                eecd_spi_state <= SPI_DATA_OUT;
                            end
                        end
                    end

                    SPI_DATA_OUT: begin
                        if (eecd_cs_rising) begin
                            eecd_spi_state <= SPI_IDLE;
                        end else if (eecd_sk_rising) begin
                            // 在 SK 上升沿输出数据位, MSB first
                            reg_eecd[3]        <= eecd_spi_shift_out[15];
                            eecd_spi_shift_out <= {eecd_spi_shift_out[14:0], 1'b1};
                            eecd_spi_bit_cnt   <= eecd_spi_bit_cnt + 5'd1;

                            if (eecd_spi_bit_cnt == 5'd15) begin
                                // 16 位数据输出完成
                                eecd_spi_state <= SPI_DONE;
                            end
                        end
                    end

                    SPI_DONE: begin
                        // 等待 CS 拉高释放
                        reg_eecd[3] <= 1'b1;  // EE_DO = high (tri-state emulation)
                        if (reg_eecd[1]) begin
                            // CS 已经是高电平 (deselected), 回到 IDLE
                            eecd_spi_state <= SPI_IDLE;
                        end
                    end

                    default: eecd_spi_state <= SPI_IDLE;
                endcase
            end

            // ---- MAC Address Randomization ----
            // Uses jitter_seed to generate unique MAC last 3 bytes at power-on
            // (initialized once, preserving Intel OUI 00:1B:21)

        end
    end

endmodule
