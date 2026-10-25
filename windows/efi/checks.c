// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Generic preflight checks. See checks.h.
 */
#include "checks.h"
#ifndef GU_HOST_TEST
#include <IndustryStandard/Pci.h>
#endif

#define GU_CONFIG_BYTES 256U
#define GU_CAP_START 0x40U
#define GU_CAP_LAST 0xfcU
#define GU_CAP_LIMIT ((GU_CONFIG_BYTES - GU_CAP_START) / 4U)
#define GU_MSIX_ID 0x11U

static UINT8 ConfigByte(const UINT32 Config[64], UINTN Offset) {
  return (UINT8)(Config[Offset / 4U] >> ((Offset & 3U) * 8U));
}

static UINT16 ConfigWord(const UINT32 Config[64], UINTN Offset) {
  return (UINT16)(ConfigByte(Config, Offset) |
                  ((UINT16)ConfigByte(Config, Offset + 1U) << 8U));
}

BOOLEAN GuCheckConfigGeneric(const UINT32 Config[64], UINTN Segment, UINTN Bus,
                             UINTN Device, UINTN Function, GU_CAPS *Out) {
  GU_CAPS Caps = {0, 0, 0, 0, 0};
  UINT8 Occupied[GU_CONFIG_BYTES - GU_CAP_START] = {0};
  UINT64 Seen = 0;
  UINTN Pointer, Steps = 0;
  UINT16 Command;

  if (Out == NULL)
    return FALSE;
  *Out = Caps;
  if (Config == NULL)
    return FALSE;

  /* The endpoint's bus, device and function are not pinned: the generic
   * build accepts the card wherever the firmware enumerated it. The
   * parameters stay in the interface so the caller passes the location it
   * actually found, and so a future location check has a home. */
  (void)Bus;
  (void)Device;
  (void)Function;

  /* The transaction only understands segment 0. Any other segment is a
   * topology this code has never been reasoned about. */
  if (Segment != 0)
    return FALSE;

  /* Display class, type-0 header. The rest of the identity is read from the
   * card by the caller. */
  if (ConfigByte(Config, 0x0b) != PCI_CLASS_DISPLAY ||
      (ConfigByte(Config, PCI_HEADER_TYPE_OFFSET) & 0x7fU) != HEADER_TYPE_DEVICE)
    return FALSE;

  Command = ConfigWord(Config, PCI_COMMAND_OFFSET);
  if ((Command & EFI_PCI_COMMAND_MEMORY_SPACE) == 0 ||
      (Command & EFI_PCI_COMMAND_BUS_MASTER) != 0 ||
      (Config[PCI_EXPANSION_ROM_BASE / 4] & 1U) != 0 ||
      (ConfigWord(Config, PCI_PRIMARY_STATUS_OFFSET) & EFI_PCI_STATUS_CAPABILITY) == 0)
    return FALSE;

  /* Walk the capability chain. Every structure must fit, must not overlap an
   * earlier one, and must be one this code understands. */
  Pointer = ConfigByte(Config, PCI_CAPABILITY_POINTER_OFFSET);
  while (Pointer != 0) {
    UINTN Length, I;
    UINT16 Control;
    UINT8 Id, Next;
    UINT64 Bit;
    if (++Steps > GU_CAP_LIMIT || Pointer < GU_CAP_START || Pointer > GU_CAP_LAST ||
        (Pointer & 3U) != 0)
      return FALSE;
    Bit = (UINT64)1U << (Pointer / 4U);
    if ((Seen & Bit) != 0)
      return FALSE;
    Seen |= Bit;

    Id = ConfigByte(Config, Pointer);
    Next = ConfigByte(Config, Pointer + 1U);
    Control = ConfigWord(Config, Pointer + 2U);
    switch (Id) {
      case EFI_PCI_CAPABILITY_ID_PMI:
        if (Caps.pm != 0 || (Control & 7U) == 0 || (Control & 7U) > 3)
          return FALSE;
        Length = 8;
        break;
      case EFI_PCI_CAPABILITY_ID_MSI:
        if (Caps.msi != 0 || (Control & 1U) != 0)
          return FALSE;
        /* Mask-capable layouts include two reserved bytes after Message Data. */
        Length = (Control & 0x80U) != 0 ? 14U : 10U;
        if ((Control & 0x100U) != 0)
          Length += 10U;
        break;
      case PCI_EXPRESS_CAPABILITY_ID:
        if (Caps.pcie != 0 || (Control & 0x0fU) < 1 ||
            (Control & 0x0fU) > 2 || ((Control >> 4U) & 0x0fU) > 1)
          return FALSE;
        /* Endpoint v1 reaches Link Status; reserve the entire v2 layout. */
        Length = (Control & 0x0fU) == 1 ? 0x14U : 0x3cU;
        break;
      case GU_MSIX_ID:
        if (Caps.msix != 0 || (Control & 0x8000U) != 0)
          return FALSE;
        Length = 12;
        break;
      case EFI_PCI_CAPABILITY_ID_VENDOR:
        Length = Control & 0xffU;
        if (Length < 3)
          return FALSE;
        break;
      default:
        /* A format we do not understand cannot be checked for overlap/length. */
        return FALSE;
    }

    if (Length > GU_CONFIG_BYTES - Pointer)
      return FALSE;
    for (I = Pointer; I < Pointer + Length; ++I) {
      if (Occupied[I - GU_CAP_START] != 0)
        return FALSE;
      Occupied[I - GU_CAP_START] = 1;
    }

    switch (Id) {
      case EFI_PCI_CAPABILITY_ID_PMI:
        if ((ConfigWord(Config, Pointer + 4U) & 3U) != PCI_POWER_STATE_D0)
          return FALSE;
        Caps.pm = (UINT16)Pointer;
        break;
      case EFI_PCI_CAPABILITY_ID_MSI:
        Caps.msi = (UINT16)Pointer;
        break;
      case PCI_EXPRESS_CAPABILITY_ID:
        /* Function level reset is mandatory: the transaction ends with one. */
        if ((Config[(Pointer + 4U) / 4U] & (1U << 28U)) == 0 ||
            (ConfigWord(Config, Pointer + 8U) & 0x8000U) != 0)
          return FALSE;
        Caps.pcie = (UINT16)Pointer;
        Caps.pcie_version = (UINT8)(Control & 0x0fU);
        break;
      case GU_MSIX_ID:
        Caps.msix = (UINT16)Pointer;
        break;
      default:
        break;
    }
    Pointer = Next;
  }
  if (Caps.pm == 0 || Caps.pcie == 0)
    return FALSE;
  *Out = Caps;
  return TRUE;
}
