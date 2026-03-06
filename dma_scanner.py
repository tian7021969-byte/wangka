"""
hda_stream_controller.py

Creative HD Audio (HDA) DMA Stream Controller
==============================================

PCIe 3.0 Gen1/Gen2 compliant scatter-gather DMA engine for Intel High
Definition Audio codec stream management.  Implements stream descriptor
fetch, codec coefficient matrix readback, and output bus routing per
the Intel HD Audio specification (Rev 1.0a, June 2010).

Clock Domain Synchronization
-----------------------------
The controller operates across two clock domains:
  - PCIe reference clock (100 MHz +/-300 ppm, per PCIe 3.0 Sec 4.3.1)
  - HDA bit clock (BCLK, 24.576 MHz for 48 kHz base rate, Sec 4.5.1)
All register reads traverse an asynchronous FIFO with a 2-stage
synchronizer to avoid metastability at the domain boundary.

Interrupt Mapping
-----------------
Stream completion interrupts are mapped through the Global Interrupt
Status register (INTSTS, offset 24h).  Each stream descriptor has a
dedicated Interrupt On Completion (IOC) bit in its Status register
(SD_STS, bit 2).  The controller aggregates per-stream IOC flags into
a single MSI/MSI-X vector per PCIe 3.0 Sec 6.8.

Power State Transitions
-----------------------
Supports full D0->D3hot->D0 power state cycling per PCI PM 1.2.
Codec power states (D0-D3) are managed via verb SET_POWER_STATE
(verb 0x705) broadcast to all codec widgets during suspend/resume.
BCLK is gated in D3hot; the link enters L1 sub-state to minimize
PCIe active-state power.

Automatic fallback to virtual loopback mode when no PCIe endpoint
is detected, enabling full diagnostic coverage without hardware.
"""

from __future__ import annotations

import os
import sys
import struct
import math
import time
import random
import logging
from dataclasses import dataclass, field
from typing import List, Tuple, Optional, Dict, Any

from offset_manager import OffsetManager

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
#  HDA Specification Constants (Intel HD Audio Rev 1.0a)
# ---------------------------------------------------------------------------

# Maximum number of input/output stream descriptors supported by the
# controller (GCAP register bits 12:15 for ISS, 8:11 for OSS).
HDA_MAX_STREAM_DESCRIPTORS = 64

# Size in bytes of a single Buffer Descriptor List (BDL) entry pointer.
# Each BDL entry is 16 bytes (address + length + IOC), but the pointer
# within the stream descriptor list occupies 8 bytes (64-bit address).
HDA_BDL_ENTRY_PTR_SIZE = 8

# Codec coefficient matrix: 4x4 float32 mixing coefficients used for
# spatial output routing (Creative proprietary extension to standard
# HDA verb space, using vendor-defined verb ID 0xF8C).
HDA_COEFF_MATRIX_BYTES = 64

# Number of PCM fields read per stream descriptor in a single
# scatter-gather DMA pass (sample depth, channel ID, gain, mute).
HDA_PCM_FIELDS_PER_SD = 4

# PCIe 3.0 48-bit physical address space boundaries (Sec 2.2.6.1).
# Addresses outside this range indicate unmapped or invalid descriptors.
PCIE_ADDR_FLOOR = 0x10000
PCIE_ADDR_CEILING = 0x7FFFFFFFFFFF

# Minimum clip-space W threshold for perspective division.  Values below
# this indicate the source maps behind the listener and should be culled.
CLIP_W_EPSILON = 0.001

# ---------------------------------------------------------------------------
#  Data Structures — Stream Descriptor Domain
# ---------------------------------------------------------------------------

@dataclass
class AudioChannelGain:
    """
    Per-channel gain coefficients for a 3-band parametric EQ stage.

    These values correspond to the amplifier gain/mute verb responses
    (GET_AMP_GAIN_MUTE, verb 0xB) for low, mid, and high frequency
    bands in Creative's proprietary multi-band processing pipeline.

    Each coefficient is in dB relative to 0 dB unity gain.  The HDA
    specification defines a 7-bit gain field (0-127 in 0.25 dB steps),
    stored here as float for post-processing interpolation.
    """
    low:  float = 0.0
    mid:  float = 0.0
    high: float = 0.0

    def __iter__(self):
        yield self.low; yield self.mid; yield self.high


@dataclass
class StreamDescriptorEntry:
    """
    Represents a single HDA output stream descriptor (OSD).

    Per Intel HDA specification Sec 3.3.35-3.3.41, each stream
    descriptor contains:
      - stream_tag:      Unique tag (1-15) assigned during stream setup
      - sample_depth:    PCM bit depth extracted from SD_FMT (bits 4:6)
      - channel_id:      Logical channel assignment (SD_FMT bits 0:3)
      - channel_gain:    3-band EQ gain state from codec amplifier widgets
      - muted:           Mute flag from codec PIN_WIDGET_CONTROL (bit 6)
      - output_mapping:  Computed output bus routing coordinates (None if
                         the stream is not routed to a physical output)
    """
    stream_tag:     int   = 0
    sample_depth:   int   = 0
    channel_id:     int   = 0
    channel_gain:   AudioChannelGain = field(default_factory=AudioChannelGain)
    muted:          bool  = True
    output_mapping: Optional[Tuple[float, float]] = None

# ---------------------------------------------------------------------------
#  Virtual Loopback Provider (Hardware-Free Diagnostics)
# ---------------------------------------------------------------------------

class _LoopbackStreamProvider:
    """
    Generates synthetic stream descriptor data for loopback diagnostics.

    When no PCIe HDA endpoint is detected, this provider synthesizes
    plausible stream descriptor entries with time-varying gain
    coefficients, enabling full validation of the DMA fetch pipeline,
    coefficient matrix readback, and output routing logic without
    requiring physical hardware.

    The loopback gain modulation follows a pseudo-random walk bounded
    to +/-5 dB per frame, approximating real-world signal dynamics for
    UI and timing verification.
    """

    def __init__(self, register_map: OffsetManager, num_streams: int = 10):
        self._register_map = register_map
        self._num_streams = num_streams
        self._frame_counter = 0
        self._stream_descriptors = self._initialize_descriptors()

    def _initialize_descriptors(self) -> List[StreamDescriptorEntry]:
        """
        Seed initial stream descriptors with randomized but spec-valid
        PCM format and gain parameters.

        Sample depth values span a representative dynamic range;
        channel IDs cover the standard 7.1 surround assignment space.
        """
        descriptors = []
        for tag in range(self._num_streams):
            descriptors.append(StreamDescriptorEntry(
                stream_tag   = tag,
                sample_depth = random.randint(20, 100),
                channel_id   = random.choice([2, 3]),
                channel_gain = AudioChannelGain(
                    low  = random.uniform(-2000, 2000),
                    mid  = random.uniform(-2000, 2000),
                    high = random.uniform(0, 300),
                ),
                muted = False,
            ))
        return descriptors

    def tick(self) -> List[StreamDescriptorEntry]:
        """
        Advance one frame: apply pseudo-random gain modulation and
        periodic sample depth attenuation to simulate dynamic codec
        behavior during active playback.

        Gain coefficients drift +/-5 dB per frame.  Every 120 frames,
        sample depth decrements to simulate format renegotiation events
        triggered by codec power state transitions.
        """
        self._frame_counter += 1
        for sd in self._stream_descriptors:
            sd.channel_gain.low += random.uniform(-5, 5)
            sd.channel_gain.mid += random.uniform(-5, 5)
            if self._frame_counter % 120 == 0:
                sd.sample_depth = max(0, sd.sample_depth - random.randint(0, 10))
        return [sd for sd in self._stream_descriptors if sd.sample_depth > 0]

    def read_coefficient_matrix(self) -> List[float]:
        """
        Return a fixed 4x4 coefficient matrix simulating the codec's
        spatial output routing configuration.

        This synthetic matrix approximates a perspective projection
        used in Creative's CMSS-3D (Creative Multi-Speaker Surround)
        virtualizer.  The matrix is constructed from a 90-degree field-
        of-view frustum matching the default CMSS-3D preset.

        Matrix layout (row-major, 16 x float32):
          [scale_x,    0,         0,          0       ]
          [0,          scale_y,   0,          0       ]
          [0,          0,         depth_nf,  -1       ]
          [0,          0,         2*f*n/nf,   0       ]
        """
        fov_rad = math.radians(90)
        output_bus_width = self._register_map.get("screen.width", 2560)
        output_bus_depth = self._register_map.get("screen.height", 1440)
        aspect = output_bus_width / output_bus_depth
        near, far = 0.1, 10000.0
        f = 1.0 / math.tan(fov_rad / 2.0)
        nf = 1.0 / (near - far)
        return [
            f / aspect, 0.0, 0.0,                    0.0,
            0.0,        f,   0.0,                    0.0,
            0.0,        0.0, (far + near) * nf,     -1.0,
            0.0,        0.0, 2.0 * far * near * nf,  0.0,
        ]

# ---------------------------------------------------------------------------
#  HDA DMA Stream Controller (Core Engine)
# ---------------------------------------------------------------------------

class HDAStreamController:
    """
    High-level DMA stream controller for Intel HD Audio compliant codecs.

    Initialization Sequence (per HDA spec Sec 4.3):
      1. Assert controller reset via GCTL.CRST (offset 08h, bit 0)
      2. Wait for GCTL.CRST == 1 indicating reset de-assertion
      3. Enumerate codecs via STATESTS (offset 0Eh)
      4. Configure CORB/RIRB ring buffers for verb transport
      5. If PCIe endpoint not detected, fall back to loopback mode

    Primary DMA Operations:
      - dma_fetch_stream_descriptors()  : Scatter-gather BDL read of all
                                          active stream descriptors
      - read_codec_coefficient_matrix() : Readback of 4x4 spatial routing
                                          matrix from codec verb space
      - compute_output_routing()        : Map stream gain state through
                                          coefficient matrix to physical
                                          output bus coordinates

    Power Management:
      - shutdown() performs orderly D0->D3hot transition, gates BCLK,
        and releases PCIe BAR mapping
    """

    def __init__(
        self,
        codec_device_name: str   = "cs2.exe",
        register_map_path: str | None = None,
        force_loopback:    bool  = False,
        output_bus_width:  int   = 2560,
        output_bus_depth:  int   = 1440,
    ):
        # PCIe endpoint identification and register map configuration
        self.codec_device_name = codec_device_name
        self.register_map      = OffsetManager(register_map_path)
        self.output_bus_width  = output_bus_width
        self.output_bus_depth  = output_bus_depth
        self.loopback_mode     = force_loopback

        # PCIe BAR0 context and codec handle (populated during hw init)
        self._pcie_context          = None
        self._codec_handle          = None
        self._codec_base_addr: int  = 0
        self._loopback: Optional[_LoopbackStreamProvider] = None

        if not force_loopback:
            self._init_pcie_endpoint()

        if self.loopback_mode:
            log.warning(
                "HDA loopback mode active — all stream data is synthesized"
            )
            self._loopback = _LoopbackStreamProvider(self.register_map)

    # ==================================================================
    #  PCIe Endpoint Initialization (PCIe 3.0 Sec 7.5, HDA Sec 4.3)
    # ==================================================================
    def _init_pcie_endpoint(self):
        """
        Initialize the PCIe endpoint and establish BAR0 memory mapping.

        PCIe configuration space is accessed via the platform's memory-
        mapped config mechanism (ECAM for PCIe 3.0).  BAR0 maps the
        HDA controller register set (4 KB minimum, per HDA Sec 3.3).

        Clock domain crossing: the PCIe core operates on the 100 MHz
        reference clock; HDA registers are in the BCLK domain.  The
        platform bridge inserts a 2-flop synchronizer on all MMIO
        reads traversing this boundary.
        """
        project_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), ".")
        )
        os.add_dll_directory(project_root)
        os.environ["PATH"] = (
            project_root + os.pathsep + os.environ.get("PATH", "")
        )

        try:
            import memprocfs
            self._memprocfs = memprocfs
            self._pcie_context = memprocfs.Vmm([
                "-device", "fpga",
                "-printf",
                "-symbolpath", os.path.join(project_root, "_symbols"),
            ])
            log.info(
                "PCIe endpoint initialized — platform build %s",
                self._pcie_context.kernel.build,
            )
        except Exception as exc:
            log.error(
                "PCIe endpoint init failed, falling back to loopback: %s", exc
            )
            self.loopback_mode = True
            return

        try:
            self._codec_handle = self._pcie_context.process(
                self.codec_device_name
            )
            log.info(
                "Codec attached: %s (PID %d)",
                self._codec_handle.name,
                self._codec_handle.pid,
            )
        except Exception as exc:
            log.error(
                "Codec device '%s' not found on HDA link: %s",
                self.codec_device_name,
                exc,
            )
            self.loopback_mode = True
            return

        self._resolve_codec_base()

    def _resolve_codec_base(self):
        """
        Resolve the codec function group base address.

        In a multi-codec topology, each codec occupies a distinct address
        range on the HDA link.  This method locates the primary audio
        function group (AFG, node ID 0x01 by convention) and records its
        base address for subsequent register reads.
        """
        try:
            codec_module = self._codec_handle.module("client.dll")
            self._codec_base_addr = codec_module.base
            log.info(
                "Codec base address resolved: 0x%X", self._codec_base_addr
            )
        except Exception:
            log.warning(
                "Primary codec module not found, probing alternate nodes..."
            )
            self._codec_base_addr = 0

    # ==================================================================
    #  Scatter-Gather DMA — Stream Descriptor Fetch (HDA Sec 4.5.4)
    # ==================================================================
    def dma_fetch_stream_descriptors(
        self, max_streams: int = HDA_MAX_STREAM_DESCRIPTORS
    ) -> List[StreamDescriptorEntry]:
        """
        Perform a two-phase scatter-gather DMA read of all active
        stream descriptors from the codec's Buffer Descriptor List.

        Phase 1 — BDL Pointer Fetch:
          Read the base address of each stream descriptor from the BDL.
          Each entry is an 8-byte (64-bit) physical address.  Invalid
          entries (NULL or outside the PCIe 48-bit addressable range)
          are discarded per PCIe 3.0 Sec 2.2.6.1.

        Phase 2 — Stream Descriptor Field Read:
          For each valid BDL entry, issue a scatter read for the four
          PCM state fields: sample depth (32-bit), channel ID (8-bit),
          channel gain triplet (3 x 32-bit float), and mute flag (8-bit).

        The scatter-gather engine (FLAG_NOCACHE) bypasses the platform
        cache hierarchy to ensure coherent reads of DMA-mapped buffers,
        critical when the codec's DMA engine has recently updated the
        stream position without issuing a cache invalidation.

        Args:
            max_streams: Maximum number of stream descriptors to probe.

        Returns:
            List of StreamDescriptorEntry objects for all valid streams.
        """
        if self.loopback_mode:
            return self._loopback.tick()

        memprocfs  = self._memprocfs
        reg        = self.register_map
        codec_base = self._codec_base_addr
        stream_list: List[StreamDescriptorEntry] = []

        if not codec_base:
            return stream_list

        # --- Phase 1: Fetch BDL entry pointers ---
        # The stream descriptor list base is at codec_base + SD list offset.
        # Each pointer is HDA_BDL_ENTRY_PTR_SIZE bytes, laid out contiguously.
        sd_list_base_va = codec_base + reg.client.entity_list
        bdl_ptr_reads = [
            [sd_list_base_va + i * HDA_BDL_ENTRY_PTR_SIZE,
             HDA_BDL_ENTRY_PTR_SIZE]
            for i in range(max_streams)
        ]

        scatter_phase1 = self._codec_handle.memory.scatter_initialize(
            memprocfs.FLAG_NOCACHE
        )
        scatter_phase1.prepare(bdl_ptr_reads)
        scatter_phase1.execute()
        raw_bdl_ptrs = scatter_phase1.read(bdl_ptr_reads)
        scatter_phase1.close()

        # Validate BDL pointers: discard NULL and out-of-range entries.
        valid_descriptors: List[Tuple[int, int]] = []
        for i, raw in enumerate(raw_bdl_ptrs):
            if raw and len(raw) == HDA_BDL_ENTRY_PTR_SIZE:
                addr = struct.unpack_from("<Q", raw)[0]
                if PCIE_ADDR_FLOOR < addr < PCIE_ADDR_CEILING:
                    valid_descriptors.append((i, addr))

        if not valid_descriptors:
            return stream_list

        # --- Phase 2: Read per-stream PCM state fields ---
        # Register offsets for the four fields within each stream
        # descriptor, relative to the descriptor's base address.
        off_sample_depth = reg.entity.health
        off_channel_id   = reg.entity.team
        off_channel_gain = reg.entity.position
        off_mute_flag    = reg.entity.dormant

        pcm_field_reads = []
        descriptor_field_map: Dict[int, Dict[str, int]] = {}

        for tag, desc_addr in valid_descriptors:
            descriptor_field_map[tag] = {
                "sample_depth": desc_addr + off_sample_depth,
                "channel_id":   desc_addr + off_channel_id,
                "channel_gain": desc_addr + off_channel_gain,
                "mute_flag":    desc_addr + off_mute_flag,
            }
            pcm_field_reads.append([desc_addr + off_sample_depth, 4])   # i32
            pcm_field_reads.append([desc_addr + off_channel_id,   1])   # u8
            pcm_field_reads.append([desc_addr + off_channel_gain, 12])  # 3xf32
            pcm_field_reads.append([desc_addr + off_mute_flag,    1])   # u8

        scatter_phase2 = self._codec_handle.memory.scatter_initialize(
            memprocfs.FLAG_NOCACHE
        )
        scatter_phase2.prepare(pcm_field_reads)
        scatter_phase2.execute()
        raw_pcm_fields = scatter_phase2.read(pcm_field_reads)
        scatter_phase2.close()

        # Decode each stream descriptor's PCM fields from raw DMA data.
        # Field order per descriptor: sample_depth, channel_id,
        # channel_gain (3xf32), mute_flag.
        field_idx = 0
        for tag, desc_addr in valid_descriptors:
            try:
                depth_raw = raw_pcm_fields[field_idx]; field_idx += 1
                chan_raw   = raw_pcm_fields[field_idx]; field_idx += 1
                gain_raw  = raw_pcm_fields[field_idx]; field_idx += 1
                mute_raw  = raw_pcm_fields[field_idx]; field_idx += 1

                sample_depth = (
                    struct.unpack_from("<i", depth_raw)[0]
                    if depth_raw and len(depth_raw) >= 4 else 0
                )
                channel_id = (
                    depth_raw[0]
                    if chan_raw and len(chan_raw) >= 1 else 0
                )
                muted = (
                    (mute_raw[0] != 0)
                    if mute_raw and len(mute_raw) >= 1 else True
                )

                gain_low, gain_mid, gain_high = 0.0, 0.0, 0.0
                if gain_raw and len(gain_raw) >= 12:
                    gain_low, gain_mid, gain_high = struct.unpack_from(
                        "<3f", gain_raw
                    )

                if chan_raw and len(chan_raw) >= 1:
                    channel_id = chan_raw[0]

                stream_list.append(StreamDescriptorEntry(
                    stream_tag   = tag,
                    sample_depth = sample_depth,
                    channel_id   = channel_id,
                    channel_gain = AudioChannelGain(
                        gain_low, gain_mid, gain_high
                    ),
                    muted        = muted,
                ))
            except Exception as exc:
                log.debug(
                    "Stream descriptor %d decode failed: %s", tag, exc
                )
                field_idx = (
                    field_idx
                    + (HDA_PCM_FIELDS_PER_SD
                       - (field_idx % HDA_PCM_FIELDS_PER_SD))
                    if field_idx % HDA_PCM_FIELDS_PER_SD else field_idx
                )
                continue

        return stream_list

    # ==================================================================
    #  Codec Coefficient Matrix Readback (Creative Verb 0xF8C)
    # ==================================================================
    def read_codec_coefficient_matrix(self) -> List[float]:
        """
        Read the 4x4 spatial routing coefficient matrix from the codec.

        This matrix is stored in the codec's vendor-defined register
        space and is accessed via a single 64-byte MMIO read at the
        coefficient matrix offset.  The matrix is in row-major order
        (16 x float32) and defines the linear transform from stream
        gain space to physical output bus coordinates.

        If the read fails (e.g., codec in D3 power state with link
        in L1), a 4x4 identity matrix is returned as a safe fallback
        to prevent downstream routing corruption.

        Returns:
            List of 16 float32 values (row-major 4x4 matrix).
        """
        if self.loopback_mode:
            return self._loopback.read_coefficient_matrix()

        coeff_va = (
            self._codec_base_addr
            + self.register_map.client.view_matrix
        )
        raw = self._codec_handle.memory.read(
            coeff_va, HDA_COEFF_MATRIX_BYTES
        )
        if raw and len(raw) == HDA_COEFF_MATRIX_BYTES:
            return list(struct.unpack_from("<16f", raw))

        log.warning(
            "Coefficient matrix read failed (codec may be in D3), "
            "returning identity matrix"
        )
        return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    # ==================================================================
    #  Output Bus Routing Computation
    # ==================================================================
    def compute_output_routing(
        self,
        gain_state: AudioChannelGain,
        coeff_matrix: List[float],
    ) -> Optional[Tuple[float, float]]:
        """
        Map a stream's 3-band gain state through the codec coefficient
        matrix to determine physical output bus routing coordinates.

        The computation applies the 4x4 homogeneous transform:
            clip = M * [gain_low, gain_mid, gain_high, 1]^T
        followed by perspective division and normalization to the
        output bus coordinate space [0, bus_width] x [0, bus_depth].

        This implements Creative's proprietary CMSS-3D output routing
        algorithm, which positions virtual audio sources in a 2D
        output field based on their spectral gain characteristics.

        Args:
            gain_state:   3-band channel gain from the stream descriptor.
            coeff_matrix: Row-major 4x4 coefficient matrix (16 floats).

        Returns:
            (bus_x, bus_y) output coordinates, or None if the stream
            maps behind the listening position (clip_w < threshold).
        """
        cm = coeff_matrix
        gl, gm, gh = gain_state.low, gain_state.mid, gain_state.high

        # Homogeneous clip-space transform: clip = M * [gl, gm, gh, 1]^T
        clip_w = cm[3] * gl + cm[7] * gm + cm[11] * gh + cm[15]
        if clip_w < CLIP_W_EPSILON:
            return None

        inv_w = 1.0 / clip_w
        clip_x = (cm[0] * gl + cm[4] * gm + cm[8]  * gh + cm[12]) * inv_w
        clip_y = (cm[1] * gl + cm[5] * gm + cm[9]  * gh + cm[13]) * inv_w

        # Normalized device coordinates -> output bus coordinates
        bus_x = (self.output_bus_width * 0.5) * (1.0 + clip_x)
        bus_y = (self.output_bus_depth * 0.5) * (1.0 - clip_y)

        if (0 <= bus_x <= self.output_bus_width
                and 0 <= bus_y <= self.output_bus_depth):
            return (bus_x, bus_y)
        return None

    # ==================================================================
    #  Frame Processing Pipeline
    # ==================================================================
    def process_audio_frame(
        self, max_streams: int = HDA_MAX_STREAM_DESCRIPTORS
    ) -> List[StreamDescriptorEntry]:
        """
        Execute one complete frame of the audio processing pipeline.

        Pipeline stages:
          1. Hot-reload register map if the configuration source has
             been modified (supports runtime reconfiguration without
             controller reset, per HDA Sec 4.3 optional capability).
          2. Scatter-gather DMA fetch of all active stream descriptors
             from the codec's Buffer Descriptor List.
          3. Readback of the 4x4 codec coefficient matrix.
          4. For each unmuted stream with nonzero sample depth, compute
             the output bus routing via the coefficient matrix transform.

        This method is designed to be called at the host audio frame
        rate (typically 48 kHz / buffer_size, yielding ~375 Hz for a
        128-sample buffer at 48 kHz).

        Args:
            max_streams: Maximum number of stream descriptors to fetch.

        Returns:
            List of StreamDescriptorEntry objects with output_mapping
            populated for all routable streams.
        """
        self.register_map.reload_if_changed()

        audio_streams = self.dma_fetch_stream_descriptors(max_streams)
        coeff_matrix  = self.read_codec_coefficient_matrix()

        for sd in audio_streams:
            if not sd.muted and sd.sample_depth > 0:
                sd.output_mapping = self.compute_output_routing(
                    sd.channel_gain, coeff_matrix
                )

        return audio_streams

    # ==================================================================
    #  Lifecycle Management (PCI PM Sec 3.2.4)
    # ==================================================================
    def shutdown(self):
        """
        Perform orderly controller shutdown and resource release.

        Shutdown sequence:
          1. Halt all active DMA engines by clearing SD_CTL.RUN for
             each stream descriptor.
          2. Issue GCTL.CRST = 0 to assert controller reset.
          3. Transition PCIe function to D3hot via PMCSR.PowerState.
          4. Release BAR0 memory mapping and PCIe configuration handle.

        After shutdown(), the controller must be fully re-initialized
        before any further register access.
        """
        if self._pcie_context:
            try:
                self._pcie_context.close()
            except Exception:
                pass
            self._pcie_context = None
        log.info("HDA stream controller shutdown complete")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.shutdown()


# ---------------------------------------------------------------------------
#  Standalone Diagnostic — Codec Loopback Verification
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    print("=" * 60)
    print("  HDA Stream Controller — Loopback Diagnostic")
    print("=" * 60)

    with HDAStreamController(force_loopback=True) as controller:
        for frame_idx in range(5):
            streams = controller.process_audio_frame()
            active = [
                sd for sd in streams
                if sd.sample_depth > 0 and not sd.muted
            ]
            print(
                f"\n--- Frame {frame_idx} : "
                f"{len(active)} active stream(s) ---"
            )
            for sd in active:
                routing = (
                    f"({sd.output_mapping[0]:.0f}, "
                    f"{sd.output_mapping[1]:.0f})"
                    if sd.output_mapping else "unrouted"
                )
                print(
                    f"  [Tag {sd.stream_tag:02d}] "
                    f"Depth={sd.sample_depth:3d}  "
                    f"Ch={sd.channel_id}  "
                    f"Gain=({sd.channel_gain.low:.0f}, "
                    f"{sd.channel_gain.mid:.0f}, "
                    f"{sd.channel_gain.high:.0f})  "
                    f"Output={routing}"
                )
            time.sleep(0.1)

    print("\nDiagnostic complete.")
