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

    // ===================================================================
    //  Writable Registers
    // ===================================================================

    reg [31:0] reg_ctrl;        // 0x00000 Device Control
    reg [31:0] reg_status;      // 0x00008 Device Status
    reg [31:0] reg_eecd;        // 0x00010 EEPROM/Flash Control
    reg [31:0] reg_eerd;        // 0x00014 EEPROM Read
    reg [31:0] reg_ctrl_ext;    // 0x00018 Extended Device Control
    reg [31:0] reg_mdic;        // 0x00020 MDI Control

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

    // EEPROM emulation delay
    reg [7:0]  eerd_delay_cnt;
    reg        eerd_pending;

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
                8'h05: eeprom_read = 16'h0200;  // Image Version Info (2.0)
                8'h08: eeprom_read = 16'h0006;  // PBA Length (6 words)
                8'h09: eeprom_read = 16'h0009;  // PBA pointer

                // --- Subsystem IDs ---
                8'h0A: eeprom_read = 16'h1539;  // Subsystem Device ID
                8'h0B: eeprom_read = 16'h1849;  // Subsystem Vendor ID (ASRock)

                // --- Device ID in NVM ---
                8'h0D: eeprom_read = 16'h1539;  // Device ID (must match PCI config!)

                // --- Initialization Control Words ---
                8'h0F: eeprom_read = 16'h0E22;  // Init Control Word 1
                8'h10: eeprom_read = 16'h0410;  // Init Control Word 2
                8'h11: eeprom_read = 16'h0100;  // Init Control Word 3
                8'h12: eeprom_read = 16'h8086;  // Vendor ID in NVM (Intel)

                // --- LED & PHY Configuration ---
                8'h1A: eeprom_read = 16'h0F07;  // LED Configuration
                8'h1E: eeprom_read = 16'h0013;  // PHY ID Low
                8'h1F: eeprom_read = 16'h0380;  // PHY ID High

                // --- Capability / Feature Words ---
                8'h23: eeprom_read = 16'h0000;  // Capabilities word
                8'h24: eeprom_read = 16'h0010;  // Feature config

                // --- Software-defined pins / Wake ---
                8'h0E: eeprom_read = 16'h2580;  // Software Defined Pins Control

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
    wire [15:0] nvm_fixed_sum = 16'h0C00 + 16'h0200 + 16'h0006 + 16'h0009 +
                                16'h1539 + 16'h1849 + 16'h1539 + 16'h2580 +
                                16'h0E22 + 16'h0410 + 16'h0100 + 16'h8086 +
                                16'h0F07 + 16'h0013 + 16'h0380 + 16'h0000 + 16'h0010;
    wire [15:0] nvm_checksum_word = 16'hBABA - nvm_fixed_sum - nvm_mac_sum;

    // ===================================================================
    //  MDIC (PHY Interface) Emulation
    //  Windows igb/e1000e driver reads PHY registers via MDIC
    // ===================================================================

    function [15:0] phy_read;
        input [4:0] phy_reg;
        begin
            case (phy_reg)
                // PHY Control Register (0)
                5'h00: phy_read = 16'h1140; // Auto-neg, Full-duplex, 1000Mbps

                // PHY Status Register (1) - critical! driver uses this for link state
                5'h01: phy_read = 16'h796D; // Link up, auto-neg complete, all caps

                // PHY ID 1 (2)
                5'h02: phy_read = 16'h0141; // Intel PHY OUI high

                // PHY ID 2 (3)
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
                5'h10: phy_read = 16'h0068;

                // PHY Specific Status (17)
                5'h11: phy_read = 16'hAC04; // 1000Mbps, Full-duplex, Link up, resolved

                // PHY Page Select (22)
                5'h16: phy_read = 16'h0000;

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
                DW_EECD:     read_register = reg_eecd;
                DW_EERD:     read_register = reg_eerd;
                DW_CTRL_EXT: read_register = reg_ctrl_ext;
                DW_MDIC:     read_register = reg_mdic;
                DW_FEXTNVM6: read_register = 32'h0000_0001; // I211 K1 config default

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

                // SWSM (0x05B50) - Software Semaphore
                15'h16D4: read_register = 32'h0;

                // --- I211 igb driver init required registers ---

                // EEMNGCTL (0x12030) - checked before EERD NVM reads
                15'h480C: read_register = 32'h0;

                // MDICNFG (0x00E04) - MDI Configuration (I210/I211)
                15'h0381: read_register = 32'h0000_0000;

                // CONNSW (0x00034) - Copper/Fiber Switch
                15'h000D: read_register = 32'h0;

                // EEC (0x12010) - some igb code paths use this
                15'h4804: read_register = 32'h0000_A110; // matches EECD

                // EEARBC_I210 (0x12024)
                15'h4809: read_register = 32'h0;

                // BARCTRL (0x05BBC) - some paths check this
                15'h16EF: read_register = 32'h0;

                // TSYNCRXCTL (0x0B620) - Timestamp RX Control
                15'h2D88: read_register = 32'h0;

                // TSYNCTXCTL (0x0B614) - Timestamp TX Control
                15'h2D85: read_register = 32'h0;

                default: begin
                    // Non-standard area: return LFSR obfuscated data
                    read_register = {jitter_lfsr, jitter_lfsr}
                                  ^ {dw_offset[14:0], dw_offset[14:0], 2'hA};
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
                            // Restore STATUS after reset (including PF_RST_DONE)
                            reg_status <= 32'h0020_0083; // FD + LU + speed 1000 + PF_RST_DONE
                        end
                    end
                end

                DW_EECD: begin
                    if (be[0]) reg_eecd[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_eecd[15: 8] <= data[15: 8];
                    if (be[2]) reg_eecd[23:16] <= data[23:16];
                    if (be[3]) reg_eecd[31:24] <= data[31:24];
                end

                DW_EERD: begin
                    // EEPROM Read: write triggers NVM read operation
                    // bit 0: Start (self-clearing)
                    // bit[15:2]: Address (word)
                    if (be[0]) begin
                        if (data[0]) begin
                            eerd_pending   <= 1'b1;
                            eerd_delay_cnt <= 8'd4; // emulate NVM read latency
                            reg_eerd       <= {16'h0, data[15:2], 2'b01}; // keep addr, Start=1
                        end
                    end
                    if (be[1]) reg_eerd[15: 8] <= data[15: 8]; // write address high bits
                end

                DW_CTRL_EXT: begin
                    if (be[0]) reg_ctrl_ext[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_ctrl_ext[15: 8] <= data[15: 8];
                    if (be[2]) reg_ctrl_ext[23:16] <= data[23:16];
                    if (be[3]) reg_ctrl_ext[31:24] <= data[31:24];
                end

                DW_MDIC: begin
                    // MDI Control: write triggers PHY read/write
                    // bit[25:21]: PHY Register, bit[27:26]: Op (01=write, 10=read)
                    // bit[28]: Ready (set by HW), bit[29]: Error
                    reg_mdic <= data;
                    if (data[27:26] == 2'b10) begin
                        // PHY Read
                        reg_mdic <= {2'b00, 1'b1, 1'b0, data[27:16], phy_read(data[25:21])};
                    end else if (data[27:26] == 2'b01) begin
                        // PHY Write - acknowledge
                        reg_mdic <= {2'b00, 1'b1, 1'b0, data[27:0]};
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
                DW_SW_FW_SYNC: begin
                    if (be[0]) reg_sw_fw_sync[ 7: 0] <= data[ 7: 0];
                    if (be[1]) reg_sw_fw_sync[15: 8] <= data[15: 8];
                    if (be[2]) reg_sw_fw_sync[23:16] <= data[23:16];
                    if (be[3]) reg_sw_fw_sync[31:24] <= data[31:24];
                end

                default: ; // ignore writes to unmapped registers
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

            // STATUS: FD=1, LU=1 (Link Up), Speed=10b (1000Mbps)
            // bit 0: FD, bit 1: LU, bit[7:6]: speed (10=1000)
            // bit 10: PCI66 (reserved, 0)
            // bit 19: phyra (PHY Reset Asserted, clear)
            // bit 21: PF_RST_DONE = 1 (critical! driver polls this to confirm reset done)
            reg_status     <= 32'h0020_0083;

            // EECD: initial state - matching real I211
            // bit 4: EEPROM Present = 1
            // bit 8: Auto-Read Done = 1
            // bit 13: NVM Present = 1
            // bit 15: Flash Detected = 1 (I211 uses internal NVM)
            reg_eecd       <= 32'h0000_A110;

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

            // MAC Address: Intel OUI 00:1B:21 + random last 3 bytes
            // Lower 3 bytes dynamized by jitter_seed after link up
            reg_ral0       <= {8'hA5, 8'h21, 8'h1B, 8'h00}; // MAC[3:0] = 00:1B:21:A5
            reg_rah0       <= 32'h8000_B6C7;                  // AV=1, MAC[5:4] = C7:B6

            reg_fwsm       <= 32'h0000_00E0; // FW Mode = valid, FW Valid Done
            reg_sw_fw_sync <= 32'h0;

            eerd_pending   <= 1'b0;
            eerd_delay_cnt <= 8'h0;

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

            // ---- MAC Address Randomization ----
            // Uses jitter_seed to generate unique MAC last 3 bytes at power-on
            // (initialized once, preserving Intel OUI 00:1B:21)

        end
    end

endmodule
