type flush
type returnCode
type compressionLevel
type compressionStrategy

module Constants = {
  module Flush = {
    @val @module("zlib") @scope("constants")
    external z_no_flush: flush = "Z_NO_FLUSH"
    @val @module("zlib") @scope("constants")
    external z_partial_flush: flush = "Z_PARTIAL_FLUSH"
    @val @module("zlib") @scope("constants")
    external z_sync_flush: flush = "Z_SYNC_FLUSH"
    @val @module("zlib") @scope("constants")
    external z_full_flush: flush = "Z_FULL_FLUSH"
    @val @module("zlib") @scope("constants")
    external z_finish: flush = "Z_FINISH"
    @val @module("zlib") @scope("constants")
    external z_block: flush = "Z_BLOCK"
    @val @module("zlib") @scope("constants")
    external z_trees: flush = "Z_TREES"
  }

  module ReturnCodes = {
    @val @module("zlib") @scope("constants")
    external z_ok: returnCode = "Z_OK"
    @val @module("zlib") @scope("constants")
    external z_stream_end: returnCode = "Z_STREAM_END"
    @val @module("zlib") @scope("constants")
    external z_need_dict: returnCode = "Z_NEED_DICT"
    @val @module("zlib") @scope("constants")
    external z_errno: returnCode = "Z_ERRNO"
    @val @module("zlib") @scope("constants")
    external z_stream_error: returnCode = "Z_STREAM_ERROR"
    @val @module("zlib") @scope("constants")
    external z_data_error: returnCode = "Z_DATA_ERROR"
    @val @module("zlib") @scope("constants")
    external z_mem_error: returnCode = "Z_MEM_ERROR"
    @val @module("zlib") @scope("constants")
    external z_buf_error: returnCode = "Z_BUF_ERROR"
    @val @module("zlib") @scope("constants")
    external z_version_error: returnCode = "Z_VERSION_ERROR"
  }

  module CompressionLevels = {
    @val @module("zlib") @scope("constants")
    external z_no_compression: compressionLevel = "Z"
    @val @module("zlib") @scope("constants")
    external z_best_speed: compressionLevel = "Z_BEST_SPEED"
    @val @module("zlib") @scope("constants")
    external z_best_compression: compressionLevel = "Z_BEST_COMPRESSION"
    @val @module("zlib") @scope("constants")
    external z_default_compression: compressionLevel = "Z_DEFAULT_COMPRESSION"
  }

  module CompressionStrategy = {
    external z_filtered: compressionStrategy = "Z_FILTERED"
    external z_huffman_only: compressionStrategy = "Z_HUFFMAN_ONLY"
    external z_rle: compressionStrategy = "Z_RLE"
    external z_fixed: compressionStrategy = "Z_FIXED"
    external z_default_strategy: compressionStrategy = "Z_DEFAULT_STRATEGY"
  }
}

// NOTE: props not relevant for decompression have been skipped
type opts = {
  flush?: flush,
  finishFlush?: flush,
  chunkSize?: int, // Default: 16 * 1024
  windowBits?: int,
  info?: bool,
}

@val @module("zlib")
external createUnzip: (~options: opts=?) => NodeStreams.Transform.t = "createUnzip"
