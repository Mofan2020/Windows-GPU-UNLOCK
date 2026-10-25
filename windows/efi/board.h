// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Runtime board identity for the generic installer.
 *
 * Upstream compiles one machine profile into the EFI image: a fixed PCI
 * address, device ID, subsystem ID, chip ID, BAR0 base and PROM hash. That
 * makes the image usable on exactly one machine and forces a rebuild for
 * every other card. The generic installer instead discovers these values at
 * run time, from the card itself, and only keeps the invariants that hold
 * across every GA10x part.
 *
 * Nothing here is read from a user-editable file. Every value is measured on
 * the running card, so a wrong value cannot be injected; it can only make the
 * transaction refuse to run.
 */
#pragma once

#ifdef GU_HOST_TEST
/* Host stand-ins, so the same source compiles for the host tests. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
typedef uint8_t UINT8;
typedef uint16_t UINT16;
typedef uint32_t UINT32;
typedef uint64_t UINT64;
typedef uint64_t UINTN;
typedef int BOOLEAN;
#define TRUE 1
#define FALSE 0
/* The host build uses plain C types for the string type. */
typedef const char *GU_STRING;
#else
#include <Uefi.h>
/* The firmware build reports through the console. */
typedef CONST CHAR8 *GU_STRING;
#endif

/* Device IDs of the GA102/GA103/GA104/GA106 consumer parts this tool
 * supports. Taken from the upstream Linux module's supported_ids table, minus
 * the professional (GL) parts that already run BF16 at full rate. */
#define GU_NVIDIA_VENDOR 0x10deU

#ifndef GU_HOST_TEST

/* Runtime identity of the card the transaction will run against. Every field
 * is observed, never assumed. */
typedef struct {
  /* PCI location of the endpoint, from EFI_PCI_IO_PROTOCOL.GetLocation. */
  UINTN segment, bus, device, function;
  /* Device and subsystem IDs, read from PCI configuration space. */
  UINT32 device_id, subsystem_id;
  /* BAR0: the register aperture the transaction reads and writes. */
  UINT64 bar_base, bar_size;
  /* Chip ID, read from BAR0 offset 0 (the "chip" register). */
  UINT32 chip;
  /* Framebuffer size in MiB, read from BAR0 offset 0x1183a4. */
  UINT32 memory_mb;
  /* SHA-256 of the first 1 MiB of the board PROM (BAR0 offset 0x300000).
   * Recorded for the report. It is not compared against a pinned value,
   * because a per-card hash cannot be known in advance. */
  CHAR16 prom_sha256[65];
} GU_BOARD;

/* Populate Board from the card on Gu.pci. The caller must have located the
 * endpoint and mapped BAR0 already. Returns FALSE if any required value is
 * missing or implausible. */
BOOLEAN GuBoardIdentify(GU_BOARD *Board);

#endif /* GU_HOST_TEST */

/* TRUE when the device ID is one of the supported GA10x consumer parts. */
BOOLEAN GuBoardIsSupportedDevice(UINT32 DeviceId);

/* TRUE when the chip ID is one of the GA10x silicon revisions. GA102 reads
 * 0xb72000a1 and GA104/GA106 read 0xb74000a1. */
BOOLEAN GuBoardIsSupportedChip(UINT32 Chip);

/* Human readable device name for the report, or "Unknown NVIDIA device". */
GU_STRING GuBoardDeviceName(UINT32 DeviceId);

#ifndef GU_HOST_TEST
/* Log the collected identity to the report file. */
VOID GuBoardLog(const GU_BOARD *Board);
#endif
