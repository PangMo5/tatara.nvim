// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

#ifndef TATARA_FFF_H
#define TATARA_FFF_H
#include <stddef.h>
#include <stdint.h>

// Input and output are UTF-8 JSON. Each returned allocation has one owner.
// No filesystem access, global state, timers, or result limits.
uint8_t *tatara_fff_search(const uint8_t *input, size_t input_length, size_t *output_length);
void tatara_fff_free(uint8_t *output, size_t output_length);
#endif
