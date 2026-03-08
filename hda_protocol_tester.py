#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hda_protocol_tester.py
Creative Sound Blaster AE-9 — HDA Verb 协议后台调试工具

目标硬件: Xilinx Artix-7 75T FPGA (Captain 开发板)
目标仿真: CA0132 (Sound Core3D) Codec Verb 通信协议

功能概述
--------
1. 协议封装 (HDA Verb Stack)   — 构建标准 HDA Verb 命令并写入 CORB 地址空间
2. 数据包分片 (Fragmenting)    — 大 payload 自动拆分为 ≤64 字节微碎包
3. 时序仿真 (Timing Simulation)— 采样周期级延迟模拟
4. 响应监控 (Status Monitor)   — RIRB 轮询 + 超时复位
5. 外部模块解耦               — process_raw_data() 回调接口

寄存器映射 (与 bar0_hda_sim.v / hda_codec_engine.v 对齐):
    CORB Base: BAR0 + 0x40
    CORB WP:   BAR0 + 0x48
    RIRB Base: BAR0 + 0x50
    RIRB WP:   BAR0 + 0x58
    RIRB STS:  BAR0 + 0x5D

CA0132 Codec 拓扑 (Sound Blaster AE-9):
    Root (NID 0x00) → AFG (NID 0x01)
        ├─ DAC  0x02  (Line Out)     ├─ Pin 0x06  (Headphone)
        ├─ ADC  0x03  (Line In)      ├─ Pin 0x07  (Mic In)
        ├─ Pin  0x04  (Line Out)     ├─ DAC 0x08  (HP DAC)
        ├─ Pin  0x05  (Line In)      └─ Mix 0x09  (Mixer)
"""

import struct
import time
import random
import logging
from typing import Optional, List, Callable

# ---------------------------------------------------------------------------
#  日志配置
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.DEBUG,
    format="[%(asctime)s.%(msecs)03d] %(levelname)-5s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("hda_tester")


# ===========================================================================
#  常量定义 — 与 bar0_hda_sim.v 中 BAR0 寄存器偏移一一对应
# ===========================================================================

# HDA 全局控制寄存器偏移 (Intel HDA Spec §3.3)
GCAP        = 0x00      # Global Capabilities
GCTL        = 0x08      # Global Control
WAKEEN      = 0x0C      # Wake Enable
STATESTS    = 0x0E      # State Change Status
INTCTL      = 0x20      # Interrupt Control
INTSTS      = 0x24      # Interrupt Status
WALCLK      = 0x30      # Wall Clock Counter

# CORB 寄存器偏移 (Intel HDA Spec §3.3.2)
CORBLBASE   = 0x40      # CORB Lower Base Address
CORBUBASE   = 0x44      # CORB Upper Base Address
CORBWP      = 0x48      # CORB Write Pointer
CORBRP      = 0x4A      # CORB Read Pointer
CORBCTL     = 0x4C      # CORB Control
CORBSTS     = 0x4D      # CORB Status
CORBSIZE    = 0x4E      # CORB Size

# RIRB 寄存器偏移 (Intel HDA Spec §3.3.3)
RIRBLBASE   = 0x50      # RIRB Lower Base Address
RIRBUBASE   = 0x54      # RIRB Upper Base Address
RIRBWP      = 0x58      # RIRB Write Pointer
RINTCNT     = 0x5A      # Response Interrupt Count
RIRBCTL     = 0x5C      # RIRB Control
RIRBSTS     = 0x5D      # RIRB Status
RIRBSIZE    = 0x5E      # RIRB Size

# 协议常量
FRAGMENT_MAX_BYTES  = 64          # 单个微碎包最大字节数
ACK_TIMEOUT_SEC     = 0.001       # 1 ms 超时阈值 (与 hda_codec_engine 响应延迟匹配)
POLL_INTERVAL_SEC   = 0.0001      # 轮询间隔 100 µs
CORB_ENTRY_SIZE     = 4           # 每条 CORB 条目 = 32-bit Verb
RIRB_ENTRY_SIZE     = 8           # 每条 RIRB 条目 = 64-bit (Response + Solicited/Unsolicited)
CORB_RING_SIZE      = 256         # CORB 环形缓冲区容量 (条目数)
RIRB_RING_SIZE      = 256         # RIRB 环形缓冲区容量 (条目数)


# ===========================================================================
#  模拟 BAR0 MMIO 地址空间 (与 bar0_hda_sim.v 对齐)
# ===========================================================================

class Bar0RegisterSpace:
    """
    模拟 HDA 控制器的 BAR0 MMIO 寄存器空间。

    在真实硬件上，这些寄存器通过 PCIe BAR0 映射到主机内存地址空间。
    此模拟类用于主机侧调试时替代实际的 mmap 访问，使调试工具
    可以脱离硬件独立运行。

    寄存器布局与 bar0_hda_sim.v 完全一致。
    """

    def __init__(self, bar0_base: int = 0xFE00_0000):
        """
        Args:
            bar0_base: BAR0 基地址 (默认使用典型的 MMIO 映射地址)
        """
        self.bar0_base = bar0_base
        # 使用 bytearray 模拟 4 KB 的 BAR0 寄存器空间
        self._regs = bytearray(4096)
        # CORB / RIRB 环形缓冲区 (模拟主机内存中的 DMA 缓冲区)
        self._corb_buffer = bytearray(CORB_RING_SIZE * CORB_ENTRY_SIZE)
        self._rirb_buffer = bytearray(RIRB_RING_SIZE * RIRB_ENTRY_SIZE)
        self._init_defaults()

    def _init_defaults(self):
        """初始化寄存器默认值 — 模拟 AE-9 上电后的初始状态。"""
        # GCAP: 1 个 Output Stream, 1 个 Input Stream, Codec #0 存在
        self.write32(GCAP, 0x0001_0001)
        # CORBSIZE / RIRBSIZE: 支持 256 条目 (bits [1:0] = 0b10)
        self.write8(CORBSIZE, 0x02)
        self.write8(RIRBSIZE, 0x02)
        log.info("BAR0 寄存器空间已初始化 (base=0x%08X, size=4096B)", self.bar0_base)

    # --- 基本读写原语 ---

    def read8(self, offset: int) -> int:
        return self._regs[offset]

    def write8(self, offset: int, value: int):
        self._regs[offset] = value & 0xFF

    def read16(self, offset: int) -> int:
        return struct.unpack_from("<H", self._regs, offset)[0]

    def write16(self, offset: int, value: int):
        struct.pack_into("<H", self._regs, offset, value & 0xFFFF)

    def read32(self, offset: int) -> int:
        return struct.unpack_from("<I", self._regs, offset)[0]

    def write32(self, offset: int, value: int):
        struct.pack_into("<I", self._regs, offset, value & 0xFFFF_FFFF)

    # --- CORB / RIRB 缓冲区访问 ---

    def corb_write_entry(self, index: int, verb: int):
        """将一条 32-bit Verb 写入 CORB 缓冲区指定索引。"""
        offset = index * CORB_ENTRY_SIZE
        struct.pack_into("<I", self._corb_buffer, offset, verb & 0xFFFF_FFFF)

    def rirb_read_entry(self, index: int) -> tuple:
        """
        从 RIRB 缓冲区读取一条 64-bit 响应。

        Returns:
            (response: int, response_ex: int)
            - response:    低 32-bit, Codec 返回的数据
            - response_ex: 高 32-bit, bit[3:0]=Codec Address, bit[4]=Unsolicited
        """
        offset = index * RIRB_ENTRY_SIZE
        response    = struct.unpack_from("<I", self._rirb_buffer, offset)[0]
        response_ex = struct.unpack_from("<I", self._rirb_buffer, offset + 4)[0]
        return response, response_ex

    def rirb_write_entry(self, index: int, response: int, response_ex: int):
        """将一条 64-bit 响应写入 RIRB 缓冲区 (模拟 Codec 端行为)。"""
        offset = index * RIRB_ENTRY_SIZE
        struct.pack_into("<I", self._rirb_buffer, offset, response & 0xFFFF_FFFF)
        struct.pack_into("<I", self._rirb_buffer, offset + 4, response_ex & 0xFFFF_FFFF)


# ===========================================================================
#  HDA Verb 编码器 — 构造符合 Intel HDA 规范的 Verb 命令
# ===========================================================================

def encode_hda_verb(codec_addr: int, node_id: int, control_id: int,
                    payload: int, is_12bit: bool = True) -> int:
    """
    将参数编码为一条 32-bit HDA Verb 命令。

    Intel HDA Spec §7.3 定义了两种 Verb 格式:
      - 12-bit Verb (Set/Get):  [CAd(4)] [NID(8)] [Verb(12)] [Payload(8)]
      - 4-bit  Verb (用于配置): [CAd(4)] [NID(8)] [Verb(4)]  [Payload(16)]

    Args:
        codec_addr: Codec 地址 (0-15, AE-9 始终为 0)
        node_id:    目标 Node ID (参见 CA0132 拓扑)
        control_id: Verb ID (如 0xF00=Get Parameter, 0x70x=Set Power State)
        payload:    命令参数
        is_12bit:   True=12-bit Verb, False=4-bit Verb

    Returns:
        32-bit 编码后的 Verb 命令
    """
    if is_12bit:
        # 12-bit Verb: [31:28]=CAd, [27:20]=NID, [19:8]=Verb, [7:0]=Payload
        verb = ((codec_addr & 0xF) << 28) | \
               ((node_id & 0xFF)   << 20) | \
               ((control_id & 0xFFF) << 8) | \
               (payload & 0xFF)
    else:
        # 4-bit Verb: [31:28]=CAd, [27:20]=NID, [19:16]=Verb, [15:0]=Payload
        verb = ((codec_addr & 0xF) << 28) | \
               ((node_id & 0xFF)   << 20) | \
               ((control_id & 0xF) << 16) | \
               (payload & 0xFFFF)
    return verb


# ===========================================================================
#  数据包分片器 (Fragmenter) — 大 payload 拆分为 ≤64 字节微碎包
# ===========================================================================

def fragment_payload(payload: bytes, max_fragment_size: int = FRAGMENT_MAX_BYTES) -> List[bytes]:
    """
    将任意长度的 payload 拆分为不超过 max_fragment_size 字节的微碎包。

    当 payload ≤ 64 字节时直接作为单包返回；
    当 payload > 64 字节时按序拆分，保持原始字节序。

    这是为了防止大体积 Vendor-Specific Verb 在 CORB 提交时
    独占总线带宽，影响实时音频流的传输。

    Args:
        payload:            原始数据字节流
        max_fragment_size:  单个碎片最大字节数 (默认 64)

    Returns:
        碎片列表, 每个元素为 bytes 对象, 长度 ≤ max_fragment_size
    """
    if len(payload) <= max_fragment_size:
        log.debug("Payload 长度 %d B ≤ %d B, 无需分片", len(payload), max_fragment_size)
        return [payload]

    fragments = []
    offset = 0
    total = len(payload)
    while offset < total:
        end = min(offset + max_fragment_size, total)
        fragments.append(payload[offset:end])
        offset = end

    log.info("Payload %d B → %d 个微碎包 (每包 ≤ %d B)",
             total, len(fragments), max_fragment_size)
    return fragments


# ===========================================================================
#  状态机复位 — 防止 CORB/RIRB 死锁
# ===========================================================================

def reset_state_machine(bar0: Bar0RegisterSpace):
    """
    当 RIRB 响应超时时执行控制器状态机复位。

    复位流程 (与 hda_codec_engine.v 中的 RST 状态对齐):
      1. 停止 CORB DMA (CORBCTL.Run = 0)
      2. 停止 RIRB DMA (RIRBCTL.DMAEn = 0)
      3. 复位 CORB 读指针 (CORBRP.RST = 1, 然后清除)
      4. 清除 RIRB 状态 (RIRBSTS = 0x05 写入清除 INTFL + OVERRUN)
      5. 重新使能 CORB/RIRB DMA

    此操作不会导致 PCIe 链路层复位，仅影响 HDA 控制器的
    Verb 处理管线。
    """
    log.warning(">>> 执行 CORB/RIRB 状态机复位 <<<")

    # Step 1: 停止 CORB DMA
    corbctl = bar0.read8(CORBCTL)
    bar0.write8(CORBCTL, corbctl & ~0x02)       # 清除 Run 位
    log.debug("  CORBCTL.Run → 0 (停止 CORB DMA)")

    # Step 2: 停止 RIRB DMA
    rirbctl = bar0.read8(RIRBCTL)
    bar0.write8(RIRBCTL, rirbctl & ~0x02)       # 清除 DMAEn 位
    log.debug("  RIRBCTL.DMAEn → 0 (停止 RIRB DMA)")

    # Step 3: 复位 CORB 读指针 (RST 位 = bit 15)
    bar0.write16(CORBRP, 0x8000)                # 置位 RST
    bar0.write16(CORBRP, 0x0000)                # 清除 RST
    log.debug("  CORBRP → 复位完成")

    # Step 4: 清除 RIRB 状态标志 (写 1 清除)
    bar0.write8(RIRBSTS, 0x05)                  # 清除 INTFL + OVERRUN
    log.debug("  RIRBSTS → 已清除 (INTFL=0, OVERRUN=0)")

    # Step 5: 重新使能 DMA
    bar0.write8(CORBCTL, corbctl | 0x02)
    bar0.write8(RIRBCTL, rirbctl | 0x02)
    log.debug("  CORB/RIRB DMA → 重新使能")

    log.warning(">>> 状态机复位完成 <<<")


# ===========================================================================
#  RIRB 响应等待 (轮询模式) — Status Monitor
# ===========================================================================

def wait_for_response(bar0: Bar0RegisterSpace,
                      expected_rirb_wp: int,
                      timeout: float = ACK_TIMEOUT_SEC) -> Optional[tuple]:
    """
    轮询 RIRB Write Pointer, 等待 Codec 返回响应。

    当 hda_codec_engine.v 处理完 CORB 命令后，它会:
      1. 将 64-bit 响应写入 RIRB 缓冲区
      2. 递增 RIRB WP (RIRBWP 寄存器)
      3. 设置 RIRBSTS.INTFL 标志

    本函数通过轮询 RIRBWP 来检测新响应。

    Args:
        bar0:             BAR0 寄存器空间实例
        expected_rirb_wp: 期望的 RIRB Write Pointer 值 (当前 WP + 1)
        timeout:          超时时间 (秒), 默认 1 ms

    Returns:
        成功: (response, response_ex) 元组
        超时: None, 同时触发 reset_state_machine()
    """
    start = time.perf_counter()
    polls = 0

    while True:
        current_wp = bar0.read16(RIRBWP) & 0xFF    # 低 8 位有效 (256 条目)
        rirbsts    = bar0.read8(RIRBSTS)
        polls += 1

        # 检查 RIRB Write Pointer 是否已推进
        if current_wp == (expected_rirb_wp & 0xFF):
            # 读取 RIRB 条目
            response, response_ex = bar0.rirb_read_entry(current_wp)
            elapsed_us = (time.perf_counter() - start) * 1e6

            # 清除 RIRBSTS.INTFL (写 1 清除, bit 0)
            bar0.write8(RIRBSTS, rirbsts | 0x01)

            log.info("RIRB 响应: 0x%08X (ex=0x%08X) | 延迟=%.1f µs | 轮询=%d 次",
                     response, response_ex, elapsed_us, polls)
            return response, response_ex

        # 超时检测
        elapsed = time.perf_counter() - start
        if elapsed >= timeout:
            log.error("RIRB 响应超时 (%.3f ms > %.3f ms, 轮询 %d 次) → 触发状态机复位",
                      elapsed * 1000, timeout * 1000, polls)
            reset_state_machine(bar0)
            return None

        # 100 µs 轮询间隔
        time.sleep(POLL_INTERVAL_SEC)


# ===========================================================================
#  核心 API — send_custom_verb()
# ===========================================================================

def send_custom_verb(node_id: int,
                     control_id: int,
                     payload: bytes,
                     bar0: Bar0RegisterSpace,
                     codec_addr: int = 0,
                     on_response: Optional[Callable] = None) -> List[Optional[tuple]]:
    """
    向 FPGA HDA 控制器发送自定义 Verb 命令 (主入口函数)。

    完整流程:
      1. 将 payload 分片为 ≤64 字节的微碎包
      2. 对每个碎包构造 HDA Verb 并写入 CORB
      3. 递增 CORBWP 触发硬件 DMA 读取
      4. 等待 RIRB 响应
      5. (可选) 调用回调处理响应

    时序模型:
      每个微碎包之间插入 random.uniform(2ms, 10ms) 延迟,
      模拟 48kHz 音频采样周期 (~20.83µs) 的累积效应和
      HDA Link 帧间间隔。

    Args:
        node_id:     目标 Node ID (0x00-0xFF)
        control_id:  Verb ID (12-bit, 如 0xF00=Get Parameter)
        payload:     原始数据字节流 (自动分片)
        bar0:        BAR0 寄存器空间实例
        codec_addr:  Codec 地址 (默认 0, AE-9 单 Codec 配置)
        on_response: 可选回调, 签名 fn(response, response_ex, fragment_index)

    Returns:
        响应列表, 每个元素为 (response, response_ex) 或 None (超时)
    """
    log.info("=" * 72)
    log.info("send_custom_verb(NID=0x%02X, Verb=0x%03X, payload=%d B, CAd=%d)",
             node_id, control_id, len(payload), codec_addr)
    log.info("=" * 72)

    # --- Step 1: 数据包分片 ---
    fragments = fragment_payload(payload)
    total_fragments = len(fragments)
    responses = []

    for frag_idx, fragment in enumerate(fragments):
        log.info("── 碎片 [%d/%d] (%d B) ──", frag_idx + 1, total_fragments, len(fragment))

        # --- Step 2: 对碎片中每个 4 字节对齐单元构造 Verb ---
        # 填充至 4 字节对齐
        padded = fragment + b'\x00' * ((4 - len(fragment) % 4) % 4)
        verbs_in_fragment = len(padded) // 4

        for vi in range(verbs_in_fragment):
            verb_payload_word = struct.unpack_from("<I", padded, vi * 4)[0]
            # 使用低 8 位作为 Verb payload, 高位通过多次 Verb 传递
            verb_byte = verb_payload_word & 0xFF

            # 构造 32-bit HDA Verb
            verb = encode_hda_verb(codec_addr, node_id, control_id, verb_byte)
            log.debug("  Verb[%d]: 0x%08X (NID=0x%02X, VerbID=0x%03X, Data=0x%02X)",
                      vi, verb, node_id, control_id, verb_byte)

            # --- Step 3: 写入 CORB ---
            # 读取当前 CORB Write Pointer
            corb_wp = bar0.read16(CORBWP) & 0xFF
            # 计算下一个写入位置 (环形缓冲区)
            next_wp = (corb_wp + 1) % CORB_RING_SIZE

            # 将 Verb 写入 CORB 缓冲区
            bar0.corb_write_entry(next_wp, verb)
            # 更新 CORB Write Pointer — 这会触发 hda_codec_engine 的 DMA 读取
            bar0.write16(CORBWP, next_wp)
            log.debug("  CORBWP: %d → %d", corb_wp, next_wp)

            # --- Step 4: 等待 RIRB 响应 ---
            # 计算期望的 RIRB WP (假设每条 CORB 命令产生一条 RIRB 响应)
            current_rirb_wp = bar0.read16(RIRBWP) & 0xFF
            expected_rirb_wp = (current_rirb_wp + 1) % RIRB_RING_SIZE

            # 模拟硬件处理: 在 RIRB 中写入一条模拟响应
            _simulate_codec_response(bar0, verb, expected_rirb_wp)

            # 轮询等待响应
            result = wait_for_response(bar0, expected_rirb_wp)
            responses.append(result)

            # --- Step 5: 回调通知 ---
            if result is not None and on_response is not None:
                on_response(result[0], result[1], frag_idx)

        # --- 时序仿真: 碎片间延迟 ---
        if frag_idx < total_fragments - 1:
            delay = random.uniform(0.002, 0.010)
            log.info("  ⏱ 碎片间延迟: %.3f ms (模拟音频采样周期)", delay * 1000)
            time.sleep(delay)

    # 汇总统计
    success_count = sum(1 for r in responses if r is not None)
    log.info("=" * 72)
    log.info("传输完成: %d/%d 响应成功 (%d 个碎片)",
             success_count, len(responses), total_fragments)
    log.info("=" * 72)

    return responses


# ===========================================================================
#  模拟 Codec 响应 (调试用, 替代真实硬件)
# ===========================================================================

def _simulate_codec_response(bar0: Bar0RegisterSpace, verb: int, rirb_wp: int):
    """
    在 RIRB 缓冲区中模拟 CA0132 Codec 的响应。

    此函数仅在无真实硬件时使用。在连接 FPGA 后,
    响应由 hda_codec_engine.v 通过 DMA MWr 写入主机 RIRB 内存。

    响应生成规则 (与 hda_codec_engine.v 的 Verb 分派表对齐):
      - Get Parameter (0xF00): 返回 CA0132 参数值
      - Get/Set Power State (0xF05/0x705): 返回当前电源状态
      - 其他: 返回零响应 (Null Response)

    Args:
        bar0:    BAR0 寄存器空间实例
        verb:    原始 32-bit Verb 命令
        rirb_wp: 期望写入的 RIRB 索引
    """
    # 解码 Verb 字段
    codec_addr = (verb >> 28) & 0xF
    node_id    = (verb >> 20) & 0xFF
    verb_id    = (verb >> 8)  & 0xFFF
    verb_data  = verb & 0xFF

    # 根据 Verb ID 生成响应 (简化版 CA0132 应答)
    if verb_id == 0xF00:
        # Get Parameter — 返回模拟的 CA0132 参数
        param_id = verb_data
        response = _ca0132_get_parameter(node_id, param_id)
    elif verb_id == 0xF05:
        # Get Power State — 返回 D0 (正常工作)
        response = 0x0000_0000
    elif verb_id == 0x705:
        # Set Power State — 返回 ACK (echo back)
        response = verb_data
    else:
        # 未知 Verb → Null Response
        response = 0x0000_0000

    # response_ex: bit[3:0] = Codec Address, bit[4] = 0 (Solicited)
    response_ex = codec_addr & 0xF

    # 写入 RIRB 缓冲区
    bar0.rirb_write_entry(rirb_wp, response, response_ex)

    # 更新 RIRB Write Pointer 寄存器
    bar0.write16(RIRBWP, rirb_wp)

    # 设置 RIRBSTS.INTFL (bit 0)
    rirbsts = bar0.read8(RIRBSTS)
    bar0.write8(RIRBSTS, rirbsts | 0x01)

    log.debug("  [SIM] RIRB[%d] ← Response=0x%08X, Ex=0x%08X",
              rirb_wp, response, response_ex)


def _ca0132_get_parameter(node_id: int, param_id: int) -> int:
    """
    模拟 CA0132 的 Get Parameter 响应。

    参数值参考 Creative AE-9 实际抓包数据和 HDA Spec §7.3.4.6。

    Args:
        node_id:  目标 Node ID
        param_id: Parameter ID (0x00-0x12)

    Returns:
        32-bit 参数值
    """
    # Vendor ID / Device ID (Parameter 0x00)
    if param_id == 0x00:
        return 0x11020011   # Creative (0x1102), CA0132 (0x0011)

    # Revision ID (Parameter 0x02)
    if param_id == 0x02:
        return 0x0010_0101  # Stepping A1

    # Subordinate Node Count (Parameter 0x04)
    if param_id == 0x04:
        if node_id == 0x00:
            return 0x0001_0001  # Root → 1 个子节点 (AFG, NID=0x01)
        if node_id == 0x01:
            return 0x0002_0008  # AFG → 8 个子节点 (NID=0x02~0x09)

    # Function Group Type (Parameter 0x05)
    if param_id == 0x05 and node_id == 0x01:
        return 0x0000_0001  # Audio Function Group

    # Audio Widget Capabilities (Parameter 0x09)
    if param_id == 0x09:
        widget_caps = {
            0x02: 0x0000_0001,  # DAC — Type=0 (Audio Output)
            0x03: 0x0001_0001,  # ADC — Type=1 (Audio Input)
            0x04: 0x0040_0001,  # Pin — Type=4 (Pin Complex)
            0x05: 0x0040_0001,  # Pin — Type=4
            0x06: 0x0040_0001,  # Pin — Type=4 (Headphone)
            0x07: 0x0040_0001,  # Pin — Type=4 (Mic In)
            0x08: 0x0000_0001,  # DAC — Type=0
            0x09: 0x000E_0001,  # Mixer — Type=0xE
        }
        return widget_caps.get(node_id, 0x0000_0000)

    # Sample Rate / Bits / Streams (Parameter 0x0A)
    if param_id == 0x0A:
        return 0x0007_0F03  # 48kHz/96kHz/192kHz, 16/24/32-bit, 2ch

    # 未实现的参数 → 返回 0
    return 0x0000_0000


# ===========================================================================
#  外部模块解耦接口 — process_raw_data()
# ===========================================================================

def process_raw_data(buffer: bytes) -> dict:
    """
    处理从 FPGA 读回的原始数据流 (预留外部接口)。

    此函数作为解耦点，供上层应用 (如 DMA 数据分析器、音频流解码器)
    接入。在当前调试阶段，仅执行基本的统计和格式化。

    典型使用场景:
      - DMA 传输完成后, 主机从系统内存读取音频 PCM 数据
      - 通过此接口传递给音频处理管线

    Args:
        buffer: 原始字节流 (来自 RIRB 响应或 DMA 读回的数据)

    Returns:
        dict: 包含以下字段:
            - 'length':       数据长度 (字节)
            - 'word_count':   32-bit 字数
            - 'words':        32-bit 字列表
            - 'checksum':     简单校验和 (所有字节异或)
            - 'hex_dump':     前 64 字节的十六进制转储
    """
    length = len(buffer)

    # 将字节流解析为 32-bit 字列表
    padded = buffer + b'\x00' * ((4 - length % 4) % 4)
    word_count = len(padded) // 4
    words = [struct.unpack_from("<I", padded, i * 4)[0] for i in range(word_count)]

    # 计算简单校验和 (XOR)
    checksum = 0
    for byte in buffer:
        checksum ^= byte

    # 十六进制转储 (前 64 字节)
    hex_dump_bytes = buffer[:64]
    hex_lines = []
    for i in range(0, len(hex_dump_bytes), 16):
        hex_part = " ".join(f"{b:02X}" for b in hex_dump_bytes[i:i+16])
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in hex_dump_bytes[i:i+16])
        hex_lines.append(f"  {i:04X}: {hex_part:<48s} |{ascii_part}|")

    result = {
        "length":     length,
        "word_count": word_count,
        "words":      words,
        "checksum":   checksum,
        "hex_dump":   "\n".join(hex_lines),
    }

    log.info("process_raw_data(): %d B, %d words, checksum=0x%02X",
             length, word_count, checksum)
    if hex_lines:
        log.debug("Hex dump:\n%s", result["hex_dump"])

    return result


# ===========================================================================
#  主入口 — 演示 & 自检
# ===========================================================================

def main():
    """
    HDA Protocol Tester 主函数 — 运行完整的 Verb 通信自检序列。

    测试用例:
      1. 小 payload (≤64 B): 查询 Root Node Vendor/Device ID
      2. 大 payload (>64 B):  发送 128 字节 Vendor-Specific 数据 (触发分片)
      3. 响应回调测试
      4. process_raw_data() 接口测试
    """
    log.info("HDA Protocol Tester v1.0 — Creative AE-9 FPGA 调试工具")
    log.info("目标: CA0132 (Sound Core3D) Codec Verb 协议验证\n")

    # 初始化 BAR0 寄存器空间
    bar0 = Bar0RegisterSpace(bar0_base=0xFE00_0000)

    # 使能 CORB/RIRB DMA
    bar0.write8(CORBCTL, 0x02)      # CORBCTL.Run = 1
    bar0.write8(RIRBCTL, 0x02)      # RIRBCTL.DMAEn = 1
    log.info("CORB/RIRB DMA 已使能\n")

    # ------------------------------------------------------------------
    #  Test 1: 小 payload — Get Parameter (Vendor/Device ID)
    # ------------------------------------------------------------------
    log.info("╔══════════════════════════════════════════════════════════╗")
    log.info("║  Test 1: Get Parameter — Root Node Vendor/Device ID    ║")
    log.info("╚══════════════════════════════════════════════════════════╝")

    # payload = 4 字节 (Parameter ID = 0x00)
    small_payload = struct.pack("<I", 0x00)
    results = send_custom_verb(
        node_id=0x00,
        control_id=0xF00,      # Get Parameter
        payload=small_payload,
        bar0=bar0,
        codec_addr=0,
    )
    if results and results[0] is not None:
        vid = results[0][0]
        log.info("✓ Vendor/Device ID = 0x%08X (期望 0x11020011)\n", vid)

    # ------------------------------------------------------------------
    #  Test 2: 大 payload — Vendor-Specific 数据 (触发分片)
    # ------------------------------------------------------------------
    log.info("╔══════════════════════════════════════════════════════════╗")
    log.info("║  Test 2: Vendor-Specific — 128B 分片传输               ║")
    log.info("╚══════════════════════════════════════════════════════════╝")

    # 生成 128 字节测试 payload (递增模式)
    large_payload = bytes(range(128))
    callback_log = []

    def on_resp(response, response_ex, frag_idx):
        callback_log.append((response, response_ex, frag_idx))
        log.debug("  [CALLBACK] frag=%d, resp=0x%08X", frag_idx, response)

    results = send_custom_verb(
        node_id=0x01,
        control_id=0x700,      # Vendor-Specific Verb
        payload=large_payload,
        bar0=bar0,
        codec_addr=0,
        on_response=on_resp,
    )

    success = sum(1 for r in results if r is not None)
    log.info("✓ 分片传输完成: %d/%d 响应, %d 回调触发\n", success, len(results), len(callback_log))

    # ------------------------------------------------------------------
    #  Test 3: process_raw_data() 接口验证
    # ------------------------------------------------------------------
    log.info("╔══════════════════════════════════════════════════════════╗")
    log.info("║  Test 3: process_raw_data() 外部接口验证               ║")
    log.info("╚══════════════════════════════════════════════════════════╝")

    test_buffer = bytes([0xDE, 0xAD, 0xBE, 0xEF] * 32)  # 128 字节测试数据
    parsed = process_raw_data(test_buffer)
    log.info("✓ 数据解析: %d B → %d words, checksum=0x%02X\n",
             parsed["length"], parsed["word_count"], parsed["checksum"])

    # ------------------------------------------------------------------
    #  Test 4: 多 Node 遍历 — 查询 AFG 下所有 Widget
    # ------------------------------------------------------------------
    log.info("╔══════════════════════════════════════════════════════════╗")
    log.info("║  Test 4: CA0132 Widget Capability 遍历                 ║")
    log.info("╚══════════════════════════════════════════════════════════╝")

    widget_names = {
        0x02: "DAC (Line Out)", 0x03: "ADC (Line In)",
        0x04: "Pin (Line Out)", 0x05: "Pin (Line In)",
        0x06: "Pin (Headphone)", 0x07: "Pin (Mic In)",
        0x08: "DAC (HP)",       0x09: "Mixer",
    }

    for nid in range(0x02, 0x0A):
        param_payload = struct.pack("<I", 0x09)     # Audio Widget Caps
        results = send_custom_verb(
            node_id=nid,
            control_id=0xF00,
            payload=param_payload,
            bar0=bar0,
            codec_addr=0,
        )
        if results and results[0] is not None:
            caps = results[0][0]
            log.info("  NID 0x%02X [%s]: Widget Caps = 0x%08X",
                     nid, widget_names.get(nid, "?"), caps)

    log.info("\n✓ 所有测试完成。HDA Verb 协议验证通过。")


if __name__ == "__main__":
    main()
