/* Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only. */
/*
 * Host tests for the generic board discovery and capability checks.
 *
 * These run on the build machine, not on the target. They cover the parts of
 * the generic build that replaced the compiled-in machine profile: which
 * cards are accepted, which silicon revisions are accepted, and whether the
 * structural capability checks accept a well-formed endpoint and reject
 * malformed ones.
 *
 * The EFI types are replaced with host equivalents, so the logic under test
 * is the same source that ships in the image.
 */
#define GU_HOST_TEST 1

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* --- The code under test. These are the same sources that ship in the EFI
 * image; only the firmware dependencies are replaced by the host shims. --- */
#include "../efi/board.h"
#include "../efi/checks.h"

/* --- Test helpers --- */
static int Failures;

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);            \
      Failures++;                                                              \
    }                                                                          \
  } while (0)

static void SetDword(UINT32 Config[64], UINTN Offset, UINT32 Value) {
  Config[Offset / 4] = Value;
}

static void SetWord(UINT32 Config[64], UINTN Offset, UINT16 Value) {
  UINTN Index = Offset / 4;
  UINTN Shift = (Offset % 4) * 8;
  Config[Index] = (Config[Index] & ~(0xffffu << Shift)) | ((UINT32)Value << Shift);
}

static void SetByte(UINT32 Config[64], UINTN Offset, UINT8 Value) {
  UINTN Index = Offset / 4;
  UINTN Shift = (Offset % 4) * 8;
  Config[Index] = (Config[Index] & ~(0xffu << Shift)) | ((UINT32)Value << Shift);
}

/*
 * Build a configuration space that describes a well-formed GA10x endpoint:
 * display class, type 0, memory decode on, bus mastering off, a PM
 * capability in D0, and a PCIe capability with function level reset.
 */
static void BuildGoodConfig(UINT32 Config[64], UINT32 DeviceId) {
  memset(Config, 0, sizeof(UINT32) * 64);
  SetDword(Config, 0x00, DeviceId | 0x10de0000u);
  /* Revision and class: 0x030000a1 (display, revision a1). */
  SetDword(Config, 0x08, 0x030000a1u);
  /* Command: memory space on, bus mastering off. */
  SetWord(Config, PCI_COMMAND_OFFSET, EFI_PCI_COMMAND_MEMORY_SPACE);
  /* Status: capability list present. */
  SetWord(Config, PCI_PRIMARY_STATUS_OFFSET, EFI_PCI_STATUS_CAPABILITY);
  SetByte(Config, PCI_HEADER_TYPE_OFFSET, HEADER_TYPE_DEVICE);
  /* Capability pointer at 0x40. */
  SetByte(Config, PCI_CAPABILITY_POINTER_OFFSET, 0x40);

  /* PM capability at 0x40: id, next pointer 0x50, version 3. */
  SetByte(Config, 0x40, EFI_PCI_CAPABILITY_ID_PMI);
  SetByte(Config, 0x41, 0x50);
  SetWord(Config, 0x42, 0x0003);
  SetWord(Config, 0x44, 0x0000); /* D0 */

  /* PCIe capability at 0x50: id, next pointer 0 (it ends the chain), version 2. */
  SetByte(Config, 0x50, PCI_EXPRESS_CAPABILITY_ID);
  SetByte(Config, 0x51, 0x00);
  SetWord(Config, 0x52, 0x0002);
  /* Device capabilities: function level reset at bit 28. */
  SetDword(Config, 0x54, 0x10000000u);
  /* Device control: no pending reset. */
  SetWord(Config, 0x58, 0x0000);
}

int main(void) {
  printf("generic board discovery and capability checks\n");

  /* --- Supported device IDs --- */
  printf("device whitelist\n");
  CHECK(GuBoardIsSupportedDevice(0x2204)); /* RTX 3090 */
  CHECK(GuBoardIsSupportedDevice(0x2203)); /* RTX 3090 Ti */
  CHECK(GuBoardIsSupportedDevice(0x2206)); /* RTX 3080 */
  CHECK(GuBoardIsSupportedDevice(0x2484)); /* RTX 3070 */
  CHECK(GuBoardIsSupportedDevice(0x2482)); /* RTX 3070 Ti */
  CHECK(GuBoardIsSupportedDevice(0x2504)); /* RTX 3060 12GB, GA106 */
  CHECK(GuBoardIsSupportedDevice(0x2503)); /* RTX 3060 8GB, GA106 */
  CHECK(GuBoardIsSupportedDevice(0x2414)); /* GA103 */
  /* Cards that are out of scope. */
  CHECK(!GuBoardIsSupportedDevice(0x2506)); /* not in the upstream table */
  CHECK(!GuBoardIsSupportedDevice(0x2205 + 100));
  CHECK(!GuBoardIsSupportedDevice(0x1b80)); /* GA100 */
  CHECK(!GuBoardIsSupportedDevice(0x2684)); /* AD102 */
  CHECK(!GuBoardIsSupportedDevice(0x0000));

  /* --- Chip revisions --- */
  printf("chip whitelist\n");
  CHECK(GuBoardIsSupportedChip(0xb72000a1u)); /* GA102 */
  CHECK(GuBoardIsSupportedChip(0xb74000a1u)); /* GA104 and GA106 */
  CHECK(!GuBoardIsSupportedChip(0xb73000a1u));
  CHECK(!GuBoardIsSupportedChip(0x00000000u));
  CHECK(!GuBoardIsSupportedChip(0xffffffffu));

  /* --- Device names --- */
  printf("device names\n");
  CHECK(strstr(GuBoardDeviceName(0x2504), "3060") != NULL);
  CHECK(strstr(GuBoardDeviceName(0x2204), "3090") != NULL);
  CHECK(strcmp(GuBoardDeviceName(0xffff), "Unknown NVIDIA device") == 0);

  /* --- Capability checks --- */
  printf("capability checks\n");
  {
    UINT32 Config[64];
    GU_CAPS Caps;

    BuildGoodConfig(Config, 0x2504);
    CHECK(GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));
    CHECK(Caps.pm == 0x40);
    CHECK(Caps.pcie == 0x50);
    CHECK(Caps.pcie_version == 2);

    /* A different bus or device number must still pass: the generic build
     * does not pin the endpoint's location. */
    BuildGoodConfig(Config, 0x2204);
    CHECK(GuCheckConfigGeneric(Config, 0, 3, 2, 0, &Caps));
    BuildGoodConfig(Config, 0x2204);
    CHECK(GuCheckConfigGeneric(Config, 0, 12, 7, 1, &Caps));

    /* A non-zero segment is out of scope. */
    BuildGoodConfig(Config, 0x2204);
    CHECK(!GuCheckConfigGeneric(Config, 1, 1, 0, 0, &Caps));

    /* Bus mastering already on: the transaction requires it off. */
    BuildGoodConfig(Config, 0x2204);
    SetWord(Config, PCI_COMMAND_OFFSET,
            EFI_PCI_COMMAND_MEMORY_SPACE | EFI_PCI_COMMAND_BUS_MASTER);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* Memory decode off. */
    BuildGoodConfig(Config, 0x2204);
    SetWord(Config, PCI_COMMAND_OFFSET, 0);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* Not a display device. */
    BuildGoodConfig(Config, 0x2204);
    SetDword(Config, 0x08, 0x02000000u);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* Expansion ROM decoding on. */
    BuildGoodConfig(Config, 0x2204);
    SetDword(Config, PCI_EXPANSION_ROM_BASE, 0x00000001u);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* Function level reset missing: the transaction ends with one. */
    BuildGoodConfig(Config, 0x2204);
    SetDword(Config, 0x54, 0x00000000u);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* A reset already pending. */
    BuildGoodConfig(Config, 0x2204);
    SetWord(Config, 0x58, 0x8000);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* The power state is not D0. */
    BuildGoodConfig(Config, 0x2204);
    SetWord(Config, 0x44, 0x0003);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* A capability pointer that loops back on itself. */
    BuildGoodConfig(Config, 0x2204);
    SetByte(Config, 0x41, 0x40);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* Overlapping capabilities. */
    BuildGoodConfig(Config, 0x2204);
    SetByte(Config, 0x51, 0x40);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* A capability this code does not understand. */
    BuildGoodConfig(Config, 0x2204);
    SetByte(Config, 0x50, 0x77);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* No capability list at all. */
    BuildGoodConfig(Config, 0x2204);
    SetByte(Config, PCI_CAPABILITY_POINTER_OFFSET, 0x00);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, &Caps));

    /* A NULL output pointer is refused. */
    BuildGoodConfig(Config, 0x2204);
    CHECK(!GuCheckConfigGeneric(Config, 0, 1, 0, 0, NULL));
  }

  if (Failures) {
    printf("\n%d check(s) failed\n", Failures);
    return 1;
  }
  printf("\nall checks passed\n");
  return 0;
}
