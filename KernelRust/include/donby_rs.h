#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Rust Opaque Ring-Buffer Cache Handle
typedef struct DKRSArenaCache DKRSArenaCache;

// Create in-memory sliding ring-buffer cache arena (e.g. 64MB~128MB, zero disk wear, auto-freed on exit)
DKRSArenaCache* dk_rs_cache_create(size_t capacity_bytes, size_t chunk_size);
void dk_rs_cache_destroy(DKRSArenaCache* cache);

// Read from memory cache. Returns bytes read, or 0 if cache miss.
int32_t dk_rs_cache_read(DKRSArenaCache* cache, int64_t offset, uint8_t* dst, int32_t size);

// Store chunk into memory arena
void dk_rs_cache_write(DKRSArenaCache* cache, int64_t offset, const uint8_t* src, int32_t size);

// Clear all chunks on Seek or Line switch
void dk_rs_cache_clear(DKRSArenaCache* cache);

// Return total cached bytes in RAM
size_t dk_rs_cache_get_bytes(DKRSArenaCache* cache);

// Check if Dolby Vision NALU contains Profile 7 FEL and can be mapped to 8.1
bool dk_rs_check_dovi_fel(const uint8_t* nalu_data, size_t nalu_len);

#ifdef __cplusplus
}
#endif
