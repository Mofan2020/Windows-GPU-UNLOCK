// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Runtime board identity for the generic installer. See board.h.
 */
#include "board.h"
#include "board_ids.h"
#ifndef GU_HOST_TEST
#include "port.h"
#endif

typedef struct {
  UINT32 device_id;
  GU_STRING name;
} DEVICE_NAME;

/* GA102 (RTX 3090 / 3080 family), GA103 and GA104 (RTX 3070 / 3080 family)
 * and GA106 (RTX 3060 family). The device IDs are the same set the upstream
 * Linux module accepts in kernel/gpu_unlock/main.c, so both ports cover the
 * same cards. */
static const DEVICE_NAME DeviceNames[] = {
    /* GA102 */
    {GU_DEVICE_GA102_2200, "GA102 (generic)"},
    {GU_DEVICE_GA102_3090TI, "GA102 RTX 3090 Ti"},
    {GU_DEVICE_GA102_3090, "GA102 RTX 3090"},
    {GU_DEVICE_GA102_3080TI, "GA102 RTX 3080 Ti"},
    {GU_DEVICE_GA102_3080, "GA102 RTX 3080"},
    {GU_DEVICE_GA102_3080_12G, "GA102 RTX 3080 12GB"},
    {GU_DEVICE_GA102_3090TI_FE, "GA102 RTX 3090 Ti (Founders Edition)"},
    {GU_DEVICE_GA102_3080_10G_OEM, "GA102 RTX 3080 10GB (OEM)"},
    {GU_DEVICE_GA102_3080_12G_OEM, "GA102 RTX 3080 12GB (OEM)"},
    {GU_DEVICE_GA102_3090TI_OEM, "GA102 RTX 3090 Ti (OEM)"},
    {GU_DEVICE_GA102_3090_OEM, "GA102 RTX 3090 (OEM)"},
    {GU_DEVICE_GA102_3080_OEM, "GA102 RTX 3080 (OEM)"},
    /* GA104 */
    {GU_DEVICE_GA104_3070TI_GEN, "GA104 RTX 3070 Ti (generic)"},
    {GU_DEVICE_GA104_3070TI, "GA104 RTX 3070 Ti"},
    {GU_DEVICE_GA104_3070_GEN, "GA104 RTX 3070 (generic)"},
    {GU_DEVICE_GA104_3070, "GA104 RTX 3070"},
    {GU_DEVICE_GA104_3070TI_OEM, "GA104 RTX 3070 Ti (OEM)"},
    {GU_DEVICE_GA104_3080_GEN, "GA104 RTX 3080 (generic)"},
    {GU_DEVICE_GA104_3070_OEM, "GA104 RTX 3070 (OEM)"},
    {GU_DEVICE_GA104_3060TI_GEN, "GA104 RTX 3060 Ti (generic)"},
    {GU_DEVICE_GA104_3060TI, "GA104 RTX 3060 Ti"},
    {GU_DEVICE_GA104_3060TI_OEM, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3070_GEN2, "GA104 RTX 3070 (generic)"},
    {GU_DEVICE_GA104_3060_OEM, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060TI_OEM2, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3060_GEN, "GA104 RTX 3060 (generic)"},
    {GU_DEVICE_GA104_3060_OEM2, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060TI_OEM3, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3070_OEM2, "GA104 RTX 3070 (OEM)"},
    {GU_DEVICE_GA104_3060_OEM3, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060_OEM4, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3070_OEM3, "GA104 RTX 3070 (OEM)"},
    {GU_DEVICE_GA104_3060_OEM5, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060TI_OEM4, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3060_OEM6, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060TI_OEM5, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3060_OEM7, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060TI_OEM6, "GA104 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA104_3070_OEM4, "GA104 RTX 3070 (OEM)"},
    {GU_DEVICE_GA104_3060_OEM8, "GA104 RTX 3060 (OEM)"},
    {GU_DEVICE_GA104_3060_OEM9, "GA104 RTX 3060 (OEM)"},
    /* GA103 */
    {GU_DEVICE_GA103_3080TI_OEM, "GA103 RTX 3080 Ti (OEM)"},
    /* GA106 */
    {GU_DEVICE_GA106_3060_GEN, "GA106 RTX 3060 (generic)"},
    {GU_DEVICE_GA106_3060_8G, "GA106 RTX 3060 8GB"},
    {GU_DEVICE_GA106_3060_12G, "GA106 RTX 3060 12GB"},
    {GU_DEVICE_GA106_3060TI_OEM, "GA106 RTX 3060 Ti (OEM)"},
    {GU_DEVICE_GA106_3060_OEM, "GA106 RTX 3060 (OEM)"},
    {GU_DEVICE_GA106_3060_12G_OEM, "GA106 RTX 3060 12GB (OEM)"},
    {GU_DEVICE_GA106_3060_OEM2, "GA106 RTX 3060 (OEM)"},
    {GU_DEVICE_GA106_3060_OEM3, "GA106 RTX 3060 (OEM)"},
    {GU_DEVICE_GA106_3060TI_OEM2, "GA106 RTX 3060 Ti (OEM)"},
};

BOOLEAN GuBoardIsSupportedDevice(UINT32 DeviceId) {
  for (UINTN i = 0; i < sizeof(DeviceNames) / sizeof(DeviceNames[0]); i++)
    if (DeviceNames[i].device_id == DeviceId)
      return TRUE;
  return FALSE;
}

GU_STRING GuBoardDeviceName(UINT32 DeviceId) {
  for (UINTN i = 0; i < sizeof(DeviceNames) / sizeof(DeviceNames[0]); i++)
    if (DeviceNames[i].device_id == DeviceId)
      return DeviceNames[i].name;
  return "Unknown NVIDIA device";
}

BOOLEAN GuBoardIsSupportedChip(UINT32 Chip) {
  /* GA102 reads 0xb72000a1; GA104 and GA106 read 0xb74000a1. These are the
   * only silicon revisions the upstream Linux module has exercised. */
  return Chip == GU_CHIP_GA102 || Chip == GU_CHIP_GA104_GA106;
}

#ifdef GU_HOST_TEST
/*
 * The host test exercises only the whitelist logic, which needs no firmware
 * services. The identity collection below is firmware-only.
 */
#else

BOOLEAN GuBoardIdentify(GU_BOARD *Board) {
  if (!Board || !Gu.pci)
    return FALSE;

  Board->segment = 0;
  Board->bus = 0;
  Board->device = 0;
  Board->function = 0;
  if (EFI_ERROR(Gu.pci->GetLocation(Gu.pci, &Board->segment, &Board->bus,
                                     &Board->device, &Board->function)))
    return FALSE;

  if (EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32, 0, &Board->device_id)))
    return FALSE;
  if (EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32, 0x2c, &Board->subsystem_id)))
    return FALSE;

  /* BAR0 is the register aperture. Its base and length were established when
   * the firmware enumerated the card; read them back rather than assuming a
   * fixed address, because the base is assigned per machine. */
  Board->bar_base = Gu.bar_base;
  Board->bar_size = Gu.bar_size;
  if (!Board->bar_base || !Board->bar_size)
    return FALSE;

  /* Chip ID sits at BAR0 offset 0 and the framebuffer size at 0x1183a4.
   * Both are the same registers the upstream Linux module reads. */
  Board->chip = GuRead32(0);
  Board->memory_mb = GuRead32(0x1183a4);
  if (Gu.fault || Board->chip == 0xffffffffU)
    return FALSE;

  /* The PROM digest is recorded in the report. It identifies the card in the
   * log; it is never compared against a pinned value. */
  Board->prom_sha256[0] = 0;
  return TRUE;
}

VOID GuBoardLog(const GU_BOARD *Board) {
  if (!Board)
    return;
  GuLog("board: name=%s device=%#x subsystem=%#x\n", GuBoardDeviceName(Board->device_id),
        (unsigned)Board->device_id, (unsigned)Board->subsystem_id);
  GuLog("board: location=%zu:%zu:%zu.%zu bar0=%#llx size=%#llx\n",
        (size_t)Board->segment, (size_t)Board->bus, (size_t)Board->device,
        (size_t)Board->function, (unsigned long long)Board->bar_base,
        (unsigned long long)Board->bar_size);
  GuLog("board: chip=%#x memory_mb=%#x supported_device=%u supported_chip=%u\n",
        (unsigned)Board->chip, (unsigned)Board->memory_mb,
        (unsigned)GuBoardIsSupportedDevice(Board->device_id),
        (unsigned)GuBoardIsSupportedChip(Board->chip));
}

#endif /* GU_HOST_TEST */
