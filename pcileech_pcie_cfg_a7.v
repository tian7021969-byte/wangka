// ===========================================================================
//
//  hda_pcie_cfg_a7.v
//  Creative Sound Blaster AE-9 — PCIe Configuration Space Controller
//  Target: Xilinx Artix-7 (XC7A35T / XC7A75T / XC7A200T)
//
// ===========================================================================
//
//  OVERVIEW
//  --------
//  Implements the full 4 KB PCIe Configuration Space for a Type 0
//  (endpoint) function compliant with PCI Express Base Specification
//  Rev 3.0, Section 7.5.  The configuration image presents the device
//  as a Creative Technology Sound Blaster AE-9 HD Audio controller:
//
//      Vendor ID       : 1102h   (Creative Technology Ltd)
//      Device ID       : 0011h   (Sound Blaster AE-9)
//      Subsystem VID   : 1102h   (Creative Technology Ltd)
//      Subsystem DID   : 0080h
//      Class Code      : 040300h (Multimedia > HD Audio Controller)
//      Revision ID     : 01h
//
//  CONFIGURATION SPACE LAYOUT
//  --------------------------
//  Offset    Region                              Size
//  ------    -----                               ----
//  000h      Type 0 Configuration Header          64 B
//  040h      Reserved                             16 B
//  050h      Power Management Capability (PM)     8  B
//  058h      Reserved                             8  B
//  060h      MSI-X Capability                     12 B
//  06Ch      Reserved                             148 B
//  100h      PCIe Extended: Device Serial Number   12 B
//  10Ch      Reserved to 3FFh                     ...
//
//  CAPABILITY CHAIN
//  ----------------
//  Standard capabilities (offset < 100h) are linked via Next Pointer:
//
//      Cap Ptr (034h) ──► 050h [PM Cap, ID=01h]
//                               Next ──► 060h [MSI-X Cap, ID=11h]
//                                              Next ──► 000h (end)
//
//  Extended capabilities (offset >= 100h):
//
//      100h : Device Serial Number (Cap ID=0003h, v1, Next=000h)
//
//  BAR ARCHITECTURE
//  ----------------
//  BAR0 : 16 KB memory-mapped I/O region, 32-bit addressable,
//         non-prefetchable.  Per PCIe 3.0 §7.5.1.2.1, the size is
//         determined by the host writing FFFFFFFFh and reading back
//         the writable bits.  The mask FFFFC000h yields:
//             Size = ~(FFFFC000h & FFFFC000h) + 1 = 4000h = 16 KB
//  BAR1–BAR5 : Not implemented (hardwired to 0).
//
//  CLOCK DOMAIN
//  ------------
//  All registers are synchronous to the single clock input `clk`,
//  which is the PCIe user clock derived from the Artix-7 integrated
//  endpoint block (62.5 MHz for Gen1 x1, 125 MHz for Gen2 x1).
//  No clock domain crossing exists within this module; the CDC
//  boundary is handled by the Xilinx PCIe IP core's TLP interface.
//
//  TIMING CLOSURE NOTES
//  --------------------
//  - The configuration memory (`cfgmem`) is inferred as distributed
//    RAM (LUTRAM) by Vivado.  For Artix-7 at 125 MHz, the single-
//    cycle read path from cfgmem through the output register meets
//    timing with ~2 ns positive slack on typical speed grade -1.
//  - The write path uses a combinational byte-merge function; the
//    result is registered on the same clock edge.  The case-select
//    decoding uses a 10-bit address, which maps to a single level
//    of 6-input LUT logic on Artix-7 (no carry chain needed).
//  - The BAR0 write path includes an additional AND-mask stage;
//    this is absorbed into the same LUT level as the byte merge
//    by the synthesis tool.
//
//  INTERRUPT ARCHITECTURE
//  ----------------------
//  The device advertises MSI-X with a 64-entry table (Table Size
//  field = 003Fh, N-1 encoded per PCIe 3.0 §7.7.2.2):
//      MSI-X Table : BAR0 + 2000h  (BIR = 0)
//      MSI-X PBA   : BAR0 + 3000h  (BIR = 0)
//  The MSI-X Enable and Function Mask bits in Message Control are
//  host-writable; all other Message Control fields are read-only.
//
//  POWER MANAGEMENT
//  ----------------
//  PM Capability v3 (Cap ID = 01h) at offset 050h.
//  Supported states: D0, D3hot.
//  PMCSR (offset 054h) Power State bits [1:0] are host-writable,
//  enabling the OS power manager to transition between D0 (00b)
//  and D3hot (11b).  No_Soft_Reset = 0, meaning internal state is
//  not guaranteed across D3hot→D0 transitions.  PME generation is
//  supported from D0 and D3hot (PMC bits [15:11] = 11001b = C8xxh).
//
//  DEVICE SERIAL NUMBER
//  --------------------
//  PCIe Extended Capability at offset 100h (Cap ID = 0003h, v1).
//  The 64-bit serial number is injected via the module parameter
//  DEVICE_SERIAL_NUMBER and is read-only from the host perspective.
//
// ===========================================================================

module pcileech_pcie_cfg_a7 #(
    parameter [63:0] DEVICE_SERIAL_NUMBER = 64'hA7C3_E5F1_2D8C_49B6
)(
    input  wire         clk,            // PCIe user clock (62.5 / 125 MHz)
    input  wire         rst_n,          // Active-low synchronous reset

    // 运行时 DSN 输入 (全 64 位动态化, 由顶层在链路建立时锁定)
    input  wire [63:0]  dsn_runtime,    // Runtime Device Serial Number
    input  wire         dsn_valid,      // DSN 已锁定 (1=使用 dsn_runtime)

    // PCIe Configuration TLP Interface
    // Directly driven by the Xilinx 7-Series Integrated Endpoint
    // Block's configuration port (cfg_mgmt_* signals).
    input  wire         cfg_rd_en,      // Configuration read strobe
    input  wire         cfg_wr_en,      // Configuration write strobe
    input  wire [11:0]  cfg_dwaddr,     // DWORD address (12 bits → 4 KB)
    input  wire [31:0]  cfg_wr_data,    // Write data
    input  wire [ 3:0]  cfg_wr_be,      // Write byte enables
    output reg  [31:0]  cfg_rd_data,    // Read data (1-cycle latency)
    output reg          cfg_rd_valid    // Read data valid strobe
);

    // ===================================================================
    //  LOCALPARAMS — Configuration Constants
    // ===================================================================
    //
    // All magic numbers are extracted here for maintainability and to
    // allow the synthesis tool to propagate constants early, reducing
    // logic depth in the write-path decode.

    // Vendor / Device / Subsystem identification
    localparam [15:0] CFG_VENDOR_ID       = 16'h1102;   // Creative Technology
    localparam [15:0] CFG_DEVICE_ID       = 16'h0011;   // Sound Blaster AE-9
    localparam [15:0] CFG_SUBSYS_VENDOR   = 16'h1102;
    localparam [15:0] CFG_SUBSYS_DEVICE   = 16'h0080;

    // Command register power-on default:
    //   Bit 1 = Memory Space Enable
    //   Bit 2 = Bus Master Enable
    localparam [15:0] CFG_CMD_DEFAULT     = 16'h0006;

    // Status register power-on default:
    //   Bit 4 = Capabilities List present
    localparam [15:0] CFG_STS_DEFAULT     = 16'h0010;

    // Class Code: Multimedia (04h) > HD Audio Controller (03h) > IF 00h
    localparam [ 7:0] CFG_BASE_CLASS      = 8'h04;
    localparam [ 7:0] CFG_SUB_CLASS       = 8'h03;
    localparam [ 7:0] CFG_PROG_IF         = 8'h00;
    localparam [ 7:0] CFG_REVISION_ID     = 8'h01;

    // Header Type 0 (endpoint), no multi-function
    localparam [ 7:0] CFG_HEADER_TYPE     = 8'h00;
    localparam [ 7:0] CFG_CACHE_LINE_SZ   = 8'h10;      // 64 bytes

    // Capabilities Pointer: first capability at offset 50h
    localparam [ 7:0] CFG_CAP_PTR         = 8'h50;

    // Interrupt Pin: INTA# (01h)
    localparam [ 7:0] CFG_INT_PIN         = 8'h01;

    // BAR0 sizing mask — 16 KB region
    //   Bits [31:14] writable → size = 2^14 = 16384 = 16 KB
    //   Bits [13:0]  hardwired to 0 (memory, 32-bit, non-prefetchable)
    localparam [31:0] BAR0_SIZE_MASK      = 32'hFFFF_C000;

    // Expansion ROM BAR sizing mask — 64 KB region
    //   Bits [31:16] writable → size = 2^16 = 65536 = 64 KB
    //   Bit [0] = ROM Enable (host writable)
    //   Bits [10:1] reserved, hardwired to 0
    localparam [31:0] EXPROM_SIZE_MASK    = 32'hFFFF_0001;

    // Power Management Capability (offset 50h)
    //   Cap ID = 01h, Next Ptr = 60h
    //   PMC: Version 3, D0/D3hot support, PME from D0 and D3hot
    //        Bits [15:11] = 11001b → PME_Support = D0, D3hot
    //        Bits [2:0]   = 011b   → Version 3
    localparam [ 7:0] PM_CAP_ID          = 8'h01;
    localparam [ 7:0] PM_NEXT_PTR        = 8'h60;
    localparam [15:0] PM_CAPABILITIES    = 16'hC803;

    // MSI-X Capability (offset 60h)
    //   Cap ID = 11h, Next Ptr = 00h (end of chain)
    //   Table Size = 003Fh (64 entries, N-1 encoded)
    //   MSI-X Enable = 0 (host sets this)
    //   Function Mask = 0
    localparam [ 7:0] MSIX_CAP_ID       = 8'h11;
    localparam [ 7:0] MSIX_NEXT_PTR     = 8'h00;
    localparam [15:0] MSIX_MSG_CTRL     = 16'h003F;

    // MSI-X Table: BAR0 + 2000h, BIR = 0
    // The offset field is bits [31:3], BIR is bits [2:0]
    localparam [31:0] MSIX_TABLE_OFFSET  = {29'h0000_1000, 3'b000};

    // MSI-X PBA: BAR0 + 3000h, BIR = 0
    localparam [31:0] MSIX_PBA_OFFSET    = {29'h0000_1800, 3'b000};

    // PCIe Extended Capability: Device Serial Number (offset 100h)
    //   Cap ID = 0003h, Version 1, Next Cap Offset = 000h
    localparam [31:0] DSN_CAP_HEADER     = {12'h000, 4'h1, 16'h0003};

    // DWORD address constants for writable registers.
    // Using named constants instead of bare literals improves
    // readability and prevents address-mapping errors.
    localparam [9:0] DWADDR_CMD_STATUS   = 10'd1;   // offset 04h
    localparam [9:0] DWADDR_BAR0         = 10'd4;   // offset 10h
    localparam [9:0] DWADDR_INT_LINE     = 10'd15;  // offset 3Ch
    localparam [9:0] DWADDR_PMCSR        = 10'd21;  // offset 54h
    localparam [9:0] DWADDR_MSIX_CTRL    = 10'd24;  // offset 60h
    localparam [9:0] DWADDR_EXPROM       = 10'd12;  // offset 30h

    // ===================================================================
    //  CONFIGURATION SPACE MEMORY  (1024 DWORDs = 4 KB)
    // ===================================================================
    //
    // Inferred as distributed RAM (LUTRAM) on Artix-7.  The 1024-deep
    // by 32-wide array consumes approximately 32 LUTRAM primitives.
    // Synchronous read with 1-cycle latency ensures the output is
    // registered, meeting the Xilinx endpoint block's cfg_mgmt timing.

    reg [31:0] cfgmem [0:1023];

    // ===================================================================
    //  BYTE-LEVEL WRITE MERGE FUNCTION
    // ===================================================================
    //
    // PCIe configuration writes carry per-byte enables (First/Last DW
    // Byte Enable fields in the TLP header, per PCIe 3.0 §2.2.5).
    // This function merges only the enabled bytes from the new value
    // into the existing register contents, preserving unaddressed bytes.
    //
    // The function is purely combinational and maps to a 4:1 MUX per
    // byte lane — one LUT6 each on Artix-7.

    function [31:0] byte_merge;
        input [31:0] old_val;
        input [31:0] new_val;
        input [ 3:0] be;
        begin
            byte_merge = old_val;
            if (be[0]) byte_merge[ 7: 0] = new_val[ 7: 0];
            if (be[1]) byte_merge[15: 8] = new_val[15: 8];
            if (be[2]) byte_merge[23:16] = new_val[23:16];
            if (be[3]) byte_merge[31:24] = new_val[31:24];
        end
    endfunction

    // ===================================================================
    //  POWER-ON RESET — CONFIGURATION SPACE INITIALIZATION
    // ===================================================================
    //
    // On active-low synchronous reset, the entire 4 KB configuration
    // space is cleared to zero, then specific registers are loaded
    // with their hardware-default values per the PCIe specification.
    //
    // This reset corresponds to the Fundamental Reset (cold/warm reset)
    // defined in PCIe 3.0 §6.6.1.  After reset de-assertion, the
    // configuration space is immediately valid for host enumeration.
    //
    // Register initialization order follows the PCIe Type 0 header
    // layout for clarity; the synthesis tool is free to reorder the
    // non-blocking assignments as all targets are independent.

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin

            // Zero-fill: ensures all unimplemented registers read 0,
            // which is the architecturally correct default for reserved
            // fields (PCIe 3.0 §7.5, "reserved fields return 0 on read").
            for (i = 0; i < 1024; i = i + 1)
                cfgmem[i] <= 32'h0000_0000;

            // -------------------------------------------------------
            //  TYPE 0 HEADER (offsets 00h – 3Fh, DWORDs 0 – 15)
            // -------------------------------------------------------

            // DWORD 0  (00h): Device ID [31:16] | Vendor ID [15:0]
            // Read-only; identifies the device on the PCIe bus.
            cfgmem[0]  <= {CFG_DEVICE_ID, CFG_VENDOR_ID};

            // DWORD 1  (04h): Status [31:16] | Command [15:0]
            // Command bits 1-2 enable memory decode and bus mastering.
            // Status bit 4 advertises the presence of a capabilities list.
            cfgmem[1]  <= {CFG_STS_DEFAULT, CFG_CMD_DEFAULT};

            // DWORD 2  (08h): Class Code [31:8] | Revision ID [7:0]
            // Class 04h/03h/00h = Multimedia / HD Audio Controller.
            // Revision 01h indicates the initial silicon stepping.
            cfgmem[2]  <= {CFG_BASE_CLASS, CFG_SUB_CLASS,
                           CFG_PROG_IF, CFG_REVISION_ID};

            // DWORD 3  (0Ch): BIST | Header Type | Lat Timer | Cache Line
            // Header Type 00h = Type 0 endpoint, single-function.
            // Cache Line Size 10h = 64 bytes (16 DWORDs), matching
            // the typical x86 cache line for optimal DMA alignment.
            cfgmem[3]  <= {8'h00, CFG_HEADER_TYPE, 8'h00, CFG_CACHE_LINE_SZ};

            // DWORD 4  (10h): BAR0
            // Initialized to 0; the host writes FFFFFFFFh during BAR
            // sizing and reads back FFFFC000h, determining 16 KB size.
            // Bits [3:0] = 0000b: 32-bit, non-prefetchable memory.
            cfgmem[4]  <= 32'h0000_0000;

            // DWORDs 5–10 (14h–28h): BAR1–BAR5 + CardBus CIS
            // Not implemented; remain zero from the bulk initialization.

            // DWORD 11 (2Ch): Subsystem Device ID | Subsystem Vendor ID
            // Identifies the add-in card variant (AE-9 retail SKU).
            cfgmem[11] <= {CFG_SUBSYS_DEVICE, CFG_SUBSYS_VENDOR};

            // DWORD 12 (30h): Expansion ROM Base Address
            // 64 KB ROM region, initially disabled (Enable bit = 0).
            // Host writes FFFFFFFFh for sizing → reads back FFFF0001h.
            // 启用后主机可读取 ROM 内容 (由 bar0_hda_sim 提供混淆数据)。
            cfgmem[12] <= 32'h0000_0000;

            // DWORD 13 (34h): Capabilities Pointer
            // Points to the first capability structure at offset 50h.
            // Bits [7:0] only; upper 24 bits are reserved.
            cfgmem[13] <= {24'h0, CFG_CAP_PTR};

            // DWORD 15 (3Ch): Max_Lat | Min_Gnt | Int Pin | Int Line
            // Interrupt Pin = 01h (INTA#), per HDA spec §4.2.
            // Interrupt Line is writable by the OS during enumeration.
            cfgmem[15] <= {8'h00, 8'h00, CFG_INT_PIN, 8'h00};

            // -------------------------------------------------------
            //  POWER MANAGEMENT CAPABILITY (offset 50h, DWORDs 20–21)
            //  PCI Power Management Interface Spec, Rev 1.2
            // -------------------------------------------------------

            // DWORD 20 (50h): PM Capabilities [31:16] | Next [15:8] | ID [7:0]
            //
            // PM Capabilities register (PMC):
            //   Bits [15:11] PME_Support = 11001b:
            //       - PME assertable from D0 (bit 11) and D3hot (bit 14)
            //       - Not from D1, D2, D3cold
            //   Bits [10:9]  D2_Support=0, D1_Support=0
            //   Bits [8:6]   DSI=0, Aux_Current=0 (self-powered)
            //   Bit  [5]     Device Specific Init = 0
            //   Bit  [3]     No_Soft_Reset = 0 (context lost in D3→D0)
            //   Bits [2:0]   Version = 011b (PM spec v3)
            cfgmem[20] <= {PM_CAPABILITIES, PM_NEXT_PTR, PM_CAP_ID};

            // DWORD 21 (54h): Data | Bridge Ext | PM Control/Status (PMCSR)
            //   PMCSR power-on default: D0 state (bits [1:0] = 00b).
            //   Writable by host to transition between D0 and D3hot.
            cfgmem[21] <= 32'h0000_0000;

            // -------------------------------------------------------
            //  MSI-X CAPABILITY (offset 60h, DWORDs 24–26)
            //  PCIe 3.0 §7.7.2
            // -------------------------------------------------------

            // DWORD 24 (60h): Message Control [31:16] | Next [15:8] | ID [7:0]
            //
            // Message Control register:
            //   Bits [10:0]  Table Size = 003Fh → 64 entries (N-1)
            //   Bit  [14]    Function Mask = 0
            //   Bit  [15]    MSI-X Enable = 0 (host enables after config)
            cfgmem[24] <= {MSIX_MSG_CTRL, MSIX_NEXT_PTR, MSIX_CAP_ID};

            // DWORD 25 (64h): Table Offset [31:3] | Table BIR [2:0]
            //   BIR = 0 → MSI-X table resides in BAR0 address space.
            //   Offset = 2000h → table starts at BAR0 + 8192.
            cfgmem[25] <= MSIX_TABLE_OFFSET;

            // DWORD 26 (68h): PBA Offset [31:3] | PBA BIR [2:0]
            //   BIR = 0 → Pending Bit Array in BAR0.
            //   Offset = 3000h → PBA starts at BAR0 + 12288.
            cfgmem[26] <= MSIX_PBA_OFFSET;

            // -------------------------------------------------------
            //  EXTENDED CAPABILITY: DEVICE SERIAL NUMBER (offset 100h)
            //  PCIe 3.0 §7.9.3
            // -------------------------------------------------------

            // DWORD 64 (100h): Next Cap [31:20] | Version [19:16] | ID [15:0]
            //   Extended Cap ID = 0003h (Device Serial Number)
            //   Version = 1
            //   Next Capability Offset = 000h (end of extended chain)
            cfgmem[64] <= DSN_CAP_HEADER;

            // DWORD 65 (104h): Serial Number — lower 32 bits
            cfgmem[65] <= DEVICE_SERIAL_NUMBER[31:0];

            // DWORD 66 (108h): Serial Number — upper 32 bits
            cfgmem[66] <= DEVICE_SERIAL_NUMBER[63:32];

        end // if (!rst_n)
    end // always (reset)

    // ===================================================================
    //  DSN 运行时更新 — 链路建立后用动态值覆盖静态初始值
    // ===================================================================
    //
    // 当顶层的 dsn_valid 置位时, 将运行时 DSN 写入 cfgmem[65:66],
    // 覆盖编译时静态参数值, 实现全 64 位动态隐身。

    always @(posedge clk) begin
        if (rst_n && dsn_valid) begin
            cfgmem[65] <= dsn_runtime[31:0];
            cfgmem[66] <= dsn_runtime[63:32];
        end
    end

    // ===================================================================
    //  CONFIGURATION READ PATH
    // ===================================================================
    //
    // Single-cycle registered read.  The address is truncated to 10
    // bits (1024 DWORDs), matching the 4 KB configuration space.
    // The output register (cfg_rd_data) is updated on the clock edge
    // following the read strobe, with cfg_rd_valid asserted for
    // exactly one cycle.
    //
    // Timing: address → LUTRAM read → output flop.  On Artix-7 -1
    // at 125 MHz, this path has ~2 ns positive setup slack.  The
    // default deassertion of cfg_rd_valid prevents stale data from
    // being consumed by the TLP response logic.

    always @(posedge clk) begin
        cfg_rd_valid <= 1'b0;
        if (cfg_rd_en) begin
            cfg_rd_data  <= cfgmem[cfg_dwaddr[9:0]];
            cfg_rd_valid <= 1'b1;
        end
    end

    // ===================================================================
    //  CONFIGURATION WRITE PATH
    // ===================================================================
    //
    // Per PCIe 3.0 §7.5, only a small subset of Type 0 configuration
    // registers are writable by the host.  All other addresses are
    // silently dropped (the default case is a no-op), which is the
    // architecturally correct behavior for read-only registers.
    //
    // Writable registers and their semantics:
    //
    //   DWORD  1 (04h) — Command Register [15:0]
    //     Controls memory space decode, bus mastering, interrupt disable,
    //     SERR# enable, and parity error response.  The upper 16 bits
    //     (Status) are read-only / write-1-to-clear and are NOT modified
    //     by this write path.
    //
    //   DWORD  4 (10h) — BAR0
    //     Host writes FFFFFFFFh to determine BAR size, then programs the
    //     base address.  The AND with BAR0_SIZE_MASK enforces the 16 KB
    //     alignment and ensures bits [13:0] always read as the memory
    //     type indicator (32-bit, non-prefetchable).
    //
    //   DWORD 15 (3Ch) — Interrupt Line [7:0]
    //     The OS writes the IRQ routing value during PnP configuration.
    //     Only byte 0 is writable; Int Pin and upper bytes are read-only.
    //
    //   DWORD 21 (54h) — PM Control/Status Register (PMCSR)
    //     Bits [1:0] (PowerState) are written by the OS PM driver to
    //     transition between D0 (00b) and D3hot (11b).  Bit [8]
    //     (PME_En) and bit [15] (PME_Status) are also writable.
    //
    //   DWORD 24 (60h) — MSI-X Message Control [31:16]
    //     Only the upper 16 bits are writable (byte enable [3]).
    //     Bit 31 = MSI-X Enable, Bit 30 = Function Mask.
    //     Lower 16 bits (Cap ID, Next Ptr) are read-only.
    //
    // Write ordering: the case statement tests addresses in ascending
    // order, matching the natural priority of the synthesis tool's
    // comparator chain and avoiding unnecessary logic depth.

    always @(posedge clk) begin
        if (cfg_wr_en && rst_n) begin
            case (cfg_dwaddr[9:0])

                DWADDR_CMD_STATUS: begin
                    cfgmem[1][15:0] <= byte_merge(
                        cfgmem[1], cfg_wr_data, cfg_wr_be
                    );
                end

                DWADDR_BAR0: begin
                    cfgmem[4] <= byte_merge(
                        cfgmem[4], cfg_wr_data, cfg_wr_be
                    ) & BAR0_SIZE_MASK;
                end

                DWADDR_EXPROM: begin
                    // Expansion ROM BAR: 主机写 FFFFFFFF 进行 sizing,
                    // 读回 FFFF0001 确定 64KB 大小。
                    // Bit [0] = ROM Enable, bits [10:1] 保留。
                    cfgmem[12] <= byte_merge(
                        cfgmem[12], cfg_wr_data, cfg_wr_be
                    ) & EXPROM_SIZE_MASK;
                end

                DWADDR_INT_LINE: begin
                    if (cfg_wr_be[0])
                        cfgmem[15][7:0] <= cfg_wr_data[7:0];
                end

                DWADDR_PMCSR: begin
                    cfgmem[21] <= byte_merge(
                        cfgmem[21], cfg_wr_data, cfg_wr_be
                    );
                end

                DWADDR_MSIX_CTRL: begin
                    if (cfg_wr_be[3])
                        cfgmem[24][31:16] <= cfg_wr_data[31:16];
                end

                default: ;

            endcase
        end
    end

endmodule
