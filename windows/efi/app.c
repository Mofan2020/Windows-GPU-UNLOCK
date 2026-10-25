// Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
/*
 * Generic EFI unlock application.
 *
 * Derived from internal-boot/unlock/app.c in this repository (GPL-2.0-only,
 * Copyright (C) Windows GPU UNLOCK contributors), with the single-machine
 * profile removed.
 *
 * Upstream compiles one machine into the image: a fixed PCI address, device
 * ID, subsystem ID, chip ID, BAR0 base and PROM hash, plus fingerprints of the
 * BIOS display drivers. Every one of those is replaced here by a run-time
 * observation of the card itself (board.c) and a structural capability check
 * (checks.c). The result is one binary that serves every supported GA10x card
 * and refuses anything it has not understood.
 *
 * The unlock transaction itself is the unmodified vendor core in vendor/.
 */
#include "app.h"
#include "app_io.h"
#include "board.h"
#include "checks.h"
#include "compat/compat.h"
#include "format.h"
#include "ownership.h"
#include "sha256.h"
#include "vendor/gfw_eval.h"
#include "vendor/unlock_610.h"
#include <Protocol/GraphicsOutput.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/DevicePath.h>
#include <Guid/GlobalVariable.h>

static EFI_GUID PciGuid = EFI_PCI_IO_PROTOCOL_GUID,
                  GopGuid = EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID,
                  PathGuid = EFI_DEVICE_PATH_PROTOCOL_GUID,
                  LoadedImageGuid = EFI_LOADED_IMAGE_PROTOCOL_GUID,
                  GlobalGuid = EFI_GLOBAL_VARIABLE;

static EFI_SYSTEM_TABLE *Table;
static UINT32 InitialConfig[64];
static const char *Stage;
static GU_BOARD Board;

static EFI_STATUS Step(EFI_STATUS Status) {
  GuLog("CHECK stage=%s status=%#llx\n", Stage, (unsigned long long)Status);
  return !GuLogReady() && !EFI_ERROR(Status) ? EFI_DEVICE_ERROR : Status;
}

/*
 * The console check.
 *
 * Upstream fingerprints the BIOS display drivers (the AMI combo splitter, the
 * nvgop image, the EDID driver) to prove the console lives on the integrated
 * GPU and not on the card being unlocked. Those hashes are per BIOS and
 * cannot be known in advance.
 *
 * What matters for safety here is weaker and checkable at run time: the card
 * must not be the console's own display device. If the unlocked card drives
 * the console, the transaction's FLR would take the console down with it, and
 * the user would have no way to read the result. When a second display
 * adapter is present, the console is on the other one and the transaction is
 * safe to run.
 */
static BOOLEAN DisplayCheck(VOID) {
  EFI_HANDLE *handles = NULL;
  UINTN count = 0;
  EFI_STATUS status;
  BOOLEAN valid = TRUE;
  BOOLEAN console_on_target = FALSE;

  status = Table->BootServices->LocateHandleBuffer(ByProtocol, &GopGuid, NULL, &count, &handles);
  GuLog("GOP enumeration: status=%#llx handles=%zu\n", (unsigned long long)status, (size_t)count);
  if (EFI_ERROR(status) || !handles || !count || count > 16) {
    if (handles)
      GuFree(handles);
    return FALSE;
  }

  for (UINTN i = 0; i < count; i++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = NULL;
    EFI_DEVICE_PATH_PROTOCOL *path = NULL;
    EFI_PCI_IO_PROTOCOL *pci = NULL;
    UINT32 id = 0;
    UINTN segment = 0, bus = 0, device = 0, function = 0;
    BOOLEAN is_target = FALSE;

    status = Table->BootServices->HandleProtocol(handles[i], &GopGuid, (VOID **)&gop);
    if (EFI_ERROR(status) || !gop || !gop->Mode) {
      GuLog("GOP[%u] invalid protocol/mode: status=%#llx\n", (unsigned)i,
            (unsigned long long)status);
      valid = FALSE;
      break;
    }
    status = Table->BootServices->HandleProtocol(handles[i], &PathGuid, (VOID **)&path);
    if (EFI_ERROR(status) || !path) {
      /* A GOP without a device path cannot be attributed to any card. */
      GuLog("GOP[%u] has no device path\n", (unsigned)i);
      valid = FALSE;
      break;
    }

    /* Resolve the PCI parent of this GOP and compare it with the card we
     * identified. */
    {
      EFI_DEVICE_PATH_PROTOCOL *remaining = path;
      EFI_HANDLE parent = NULL;
      if (!Table->BootServices->LocateDevicePath) {
        valid = FALSE;
        break;
      }
      status = Table->BootServices->LocateDevicePath(&PciGuid, &remaining, &parent);
      if (EFI_ERROR(status) || !parent) {
        GuLog("GOP[%u] no PCI parent\n", (unsigned)i);
        valid = FALSE;
        break;
      }
      status = Table->BootServices->HandleProtocol(parent, &PciGuid, (VOID **)&pci);
      if (EFI_ERROR(status) || !pci || !pci->GetLocation || !pci->Pci.Read) {
        GuLog("GOP[%u] parent has no PCI protocol\n", (unsigned)i);
        valid = FALSE;
        break;
      }
      status = pci->GetLocation(pci, &segment, &bus, &device, &function);
      if (EFI_ERROR(status)) {
        valid = FALSE;
        break;
      }
      status = pci->Pci.Read(pci, EfiPciIoWidthUint32, 0, 1, &id);
      if (EFI_ERROR(status)) {
        valid = FALSE;
        break;
      }
      is_target = (GuTarget.set && id == GuTarget.device_id);
    }

    GuLog("GOP[%u] pci=%#x at %zu:%zu:%zu.%zu is_target=%u console=%u\n",
          (unsigned)i, (unsigned)id, (size_t)segment, (size_t)bus,
          (size_t)device, (size_t)function, (unsigned)is_target,
          (unsigned)(handles[i] == Table->ConsoleOutHandle));

    if (is_target) {
      console_on_target = TRUE;
      GuLog("GOP[%u] belongs to the unlocked card\n", (unsigned)i);
    }
  }

  GuFree(handles);

  /* Refuse to take the console down with the card. */
  if (console_on_target) {
    GuLogText("REFUSED: the unlocked card is the console display. "
              "Connect the display to another adapter or use a machine with an "
              "integrated GPU.\n");
    return FALSE;
  }

  GuLog("GOP result: valid=%u console_on_target=%u\n", (unsigned)valid,
        (unsigned)console_on_target);
  return valid;
}

static EFI_STATUS ReadConfig(UINT32 *Config) {
  for (UINTN i = 0; i < 64; i++)
    if (EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32, (UINT32)i * 4, &Config[i]))) {
      GuLog("PCI config read failed: offset=%#x valid_bytes=%u; snapshot incomplete\n",
            (unsigned)(i * 4), (unsigned)(i * 4));
      return EFI_DEVICE_ERROR;
    }
  return EFI_SUCCESS;
}

static EFI_STATUS ConfigCheck(BOOLEAN Save) {
  UINT32 config[64];
  GU_CAPS caps;
  UINTN segment, bus, device, function;
  EFI_STATUS status = Gu.pci->GetLocation(Gu.pci, &segment, &bus, &device, &function);
  GuLog("target location: status=%#llx\n", (unsigned long long)status);
  if (EFI_ERROR(status))
    return status;
  status = ReadConfig(config);
  if (EFI_ERROR(status))
    return status;

  BOOLEAN checked = GuCheckConfigGeneric(config, segment, bus, device, function, &caps);
  /* The revision and class dword must match the values the upstream Linux
   * module and the vendor core have been exercised against. */
  BOOLEAN valid = checked && config[2] == 0x030000a1 && !(config[(caps.pcie + 8) / 4] & 0x00200000U);
  BOOLEAN same = Save || !memcmp(config, InitialConfig, sizeof(config));
  if (Save || !valid || !same)
    GuLog("target BDF=%zu:%zu:%zu.%zu checks=%u pm=%#x pcie=%#x msi=%#x msix=%#x config0=%#x\n",
          (size_t)segment, (size_t)bus, (size_t)device, (size_t)function, (unsigned)checked,
          (unsigned)caps.pm, (unsigned)caps.pcie, (unsigned)caps.msi, (unsigned)caps.msix,
          (unsigned)config[0]);
  if (!valid)
    return EFI_UNSUPPORTED;
  if (!same)
    return EFI_NOT_READY;
  if (Save)
    memcpy(InitialConfig, config, sizeof(config));
  Gu.pm_cap = caps.pm;
  Gu.pcie_cap = caps.pcie;
  Gu.pcie_version = caps.pcie_version;
  Gu.msi_cap = caps.msi;
  Gu.msix_cap = caps.msix;
  return EFI_SUCCESS;
}

/*
 * Locate the card to unlock.
 *
 * Every NVIDIA display endpoint is enumerated. Exactly one must be a
 * supported GA10x part; that one becomes the target. This is the point where
 * the generic build differs most from upstream, which looked for one
 * hard-coded device ID.
 */
static EFI_STATUS FindTarget(VOID) {
  EFI_HANDLE *handles = NULL;
  UINTN count = 0;
  UINTN matches = 0;
  EFI_STATUS status;

  status = Table->BootServices->LocateHandleBuffer(ByProtocol, &PciGuid, NULL, &count, &handles);
  GuLog("PCI enumeration: status=%#llx handles=%zu\n", (unsigned long long)status, (size_t)count);
  if (EFI_ERROR(status) || !handles || !count || count > 256) {
    if (handles)
      GuFree(handles);
    return EFI_NOT_FOUND;
  }

  for (UINTN i = 0; i < count; i++) {
    EFI_PCI_IO_PROTOCOL *pci = NULL;
    UINT32 id = 0;
    status = Table->BootServices->HandleProtocol(handles[i], &PciGuid, (VOID **)&pci);
    if (EFI_ERROR(status) || !pci) {
      GuLog("PCI scan failed: index=%zu status=%#llx\n", (size_t)i,
            (unsigned long long)status);
      status = EFI_DEVICE_ERROR;
      break;
    }
    status = pci->Pci.Read(pci, EfiPciIoWidthUint32, 0, 1, &id);
    if (EFI_ERROR(status)) {
      status = EFI_DEVICE_ERROR;
      break;
    }
    /* Vendor 0x10de, and a display-class device ID we support. */
    if ((id & 0xffff) == GU_NVIDIA_VENDOR && GuBoardIsSupportedDevice(id >> 16)) {
      matches++;
      Gu.handle = handles[i];
      Gu.pci = pci;
      GuLog("supported NVIDIA endpoint: id=%#x index=%zu\n", (unsigned)id, (size_t)i);
    } else if ((id & 0xffff) == GU_NVIDIA_VENDOR) {
      GuLog("NVIDIA endpoint not in the supported set: id=%#x\n", (unsigned)id);
    }
  }
  GuFree(handles);
  GuLog("PCI target matches=%zu status=%#llx\n", (size_t)matches, (unsigned long long)status);
  if (EFI_ERROR(status))
    return status;
  if (matches == 0)
    return EFI_NOT_FOUND;
  if (matches > 1) {
    GuLogText("REFUSED: more than one supported NVIDIA card was found. "
              "Remove the extra card or use a machine with a single GA10x GPU.\n");
    return EFI_UNSUPPORTED;
  }
  return EFI_SUCCESS;
}

/*
 * Read the BAR0 geometry from the ACPI resource descriptor the firmware
 * publishes for the endpoint. The base is assigned per machine, so it can
 * only be observed.
 */
static EFI_STATUS BarCheck(VOID) {
  EFI_ACPI_ADDRESS_SPACE_DESCRIPTOR *r = NULL;
  EFI_STATUS status = Gu.pci->GetBarAttributes(Gu.pci, 0, NULL, (VOID **)&r);
  GuLog("bar0 query: status=%#llx\n", (unsigned long long)status);
  if (EFI_ERROR(status))
    return status;
  if (!r || r->Desc != ACPI_ADDRESS_SPACE_DESCRIPTOR || r->Len != sizeof(*r) - 3 ||
      r->ResType != 0 || r->AddrSpaceGranularity != 32 || !r->AddrLen ||
      r->AddrTranslationOffset) {
    status = EFI_UNSUPPORTED;
  } else {
    UINT8 *raw = (UINT8 *)r, sum = 0;
    for (UINTN i = 0; i < sizeof(*r) + 2; i++)
      sum = (UINT8)(sum + raw[i]);
    if (raw[sizeof(*r) + 1] && sum) {
      status = EFI_COMPROMISED_DATA;
    } else {
      Gu.bar_base = r->AddrRangeMin;
      Gu.bar_size = r->AddrLen;
      status = EFI_SUCCESS;
    }
  }
  if (r)
    GuFree(r);
  GuLog("bar0: base=%#llx size=%#llx status=%#llx\n", (unsigned long long)Gu.bar_base,
        (unsigned long long)Gu.bar_size, (unsigned long long)status);
  return status;
}

/*
 * Cold state check.
 *
 * Upstream pins the exact chip ID, framebuffer size, GFW register values and
 * selector entry values for one card. Here the invariants that hold across
 * the family are checked instead: the card must be in the cold, unclaimed
 * state that the transaction expects, and the selectors must still hold
 * their power-on values.
 */
static EFI_STATUS ColdCheck(VOID) {
  Gu.profile_verified = FALSE;

  UINT32 chip = GuRead32(0);
  struct gpu_unlock_gfw_sample s = {
      .config_ok = TRUE,
      .plm = GuRead32(GU_GFW_PLM_OFFSET),
      .boot = GuRead32(GU_GFW_BOOT_OFFSET),
      .cpuctl = GuRead32(GU_GFW_CPUCTL_OFFSET)};
  UINT32 hi = GuRead32(0x1fa828);
  UINT32 plm = GuRead32(GU_FEAT_PLM_OFFSET);
  UINT32 ss0 = GuRead32(GU_FEAT_SS0_OFFSET);
  UINT32 ss1 = GuRead32(GU_FEAT_SS1_OFFSET);
  UINT32 memory = GuRead32(0x1183a4);

  GuLog("cold state: chip=%#x plm=%#x gfw=%#x/%#x/%#x WPR2_HI=%#x SS0=%#x SS1=%#x memory=%#x\n",
        (unsigned)chip, (unsigned)plm, (unsigned)s.plm, (unsigned)s.boot,
        (unsigned)s.cpuctl, (unsigned)hi, (unsigned)ss0, (unsigned)ss1, (unsigned)memory);
  if (Gu.fault)
    return EFI_DEVICE_ERROR;

  /* The chip must be a GA10x revision and must match what we observed when
   * the card was identified. */
  if (!GuBoardIsSupportedChip(chip) || chip != Board.chip)
    return EFI_NOT_READY;

  /* The memory size must match the observed value. A different reading means
   * the card changed under us. */
  if (memory != Board.memory_mb || !memory)
    return EFI_NOT_READY;

  /* The GSP firmware must have finished booting and be halted, the protected
   * region must be down (no driver has used the card this power cycle), and
   * the privilege mask must still be the power-on value. */
  if (gpu_unlock_gfw_assess(&s) || s.plm != 0x8b8f || s.boot != 0x3ff ||
      s.cpuctl != 0x10 || hi != 0 || plm != 0xffffff8f)
    return EFI_NOT_READY;

  /* The selectors must hold a power-on value: not already unlocked, not
   * unreadable. The exact entry value differs per card and per driver
   * version, so it is latched rather than pinned. */
  if (ss0 == 0xffffffffU || ss0 == 0x88888888U || (ss0 & 0xffff0000U) == 0xbadf0000U ||
      ss1 == 0xffffffffU || (ss1 & 0xffff0000U) == 0xbadf0000U || ss1 > 0xfU)
    return EFI_NOT_READY;

  if (!Gu.prom_verified)
    return EFI_NOT_READY;

  /* Latch the entry selectors so the later writes are guarded against a card
   * that changed state. */
  if (!GuLatchEntrySelectors(ss0, ss1))
    return EFI_NOT_READY;

  GuLog("entry selectors: latched=1 SS0=%#x SS1=%#x target SS0=0x88888888 SS1=0x8\n",
        (unsigned)ss0, (unsigned)ss1);
  if (!GuLogReady() || Gu.fault)
    return EFI_DEVICE_ERROR;

  Gu.profile_verified = TRUE;
  GuLog("card verified: %s chip=%#x memory=%#x; hardware untested.\n",
        GuBoardDeviceName(Board.device_id), (unsigned)chip, (unsigned)memory);
  return EFI_SUCCESS;
}

/*
 * PROM check.
 *
 * Upstream compares the board PROM against a hash pinned for one card. A
 * per-card hash cannot be known in advance, so the PROM is only read to
 * confirm that the card exposes one, and its digest is recorded in the
 * report. The structural FWSEC extraction in the vendor core remains the
 * real check on the firmware contents.
 */
static EFI_STATUS PromCheck(VOID) {
  Gu.prom_verified = FALSE;
  VOID *prom = GuAlloc(1048576);
  if (!prom)
    return EFI_OUT_OF_RESOURCES;
  GuCopyFromIo(prom, (VOID *)(UINTN)(Gu.bar_base + 0x300000), 1048576);
  BOOLEAN readable = !Gu.fault;
  if (readable) {
    UINT8 digest[32];
    GuSha256(prom, 1048576, digest);
    for (UINTN i = 0; i < 32; i++) {
      static const char hex[] = "0123456789abcdef";
      Board.prom_sha256[i * 2] = hex[(digest[i] >> 4) & 0xf];
      Board.prom_sha256[i * 2 + 1] = hex[digest[i] & 0xf];
    }
    Board.prom_sha256[64] = 0;
  }
  GuFree(prom);
  Gu.prom_verified = readable;
  GuLog("PROM readable=%u sha256=%s\n", (unsigned)readable,
        readable ? (CONST CHAR8 *)Board.prom_sha256 : "(unavailable)");
  return readable ? EFI_SUCCESS : EFI_DEVICE_ERROR;
}

/*
 * Arming.
 *
 * The transaction rewrites GPU state, so it runs only after every check has
 * passed and only once. Pressing U confirms the intent; Esc cancels. The
 * cancellation window is generous because the screen may be blank while the
 * transaction runs.
 */
static EFI_STATUS Arm(VOID) {
  if (!Gu.profile_verified || Gu.fault || !Gu.display_ok)
    return EFI_ACCESS_DENIED;
  if (!Table->ConIn || !Table->ConIn->Reset || !Table->ConIn->ReadKeyStroke)
    return EFI_UNSUPPORTED;

  EFI_STATUS status = Table->ConIn->Reset(Table->ConIn, FALSE);
  if (EFI_ERROR(status))
    return status;

  GuLog("ARMING: %s at %zu:%zu:%zu.%zu, chip=%#x.\n",
        GuBoardDeviceName(Board.device_id), (size_t)Board.segment, (size_t)Board.bus,
        (size_t)Board.device, (size_t)Board.function, (unsigned)Board.chip);
  GuLogText("Press U to perform the unlock now. Esc cancels.\n"
            "The screen may stay black for a few seconds while the card resets.\n");
  if (!GuLogReady())
    return EFI_DEVICE_ERROR;

  for (UINTN i = 0; i < 300; i++) {
    EFI_INPUT_KEY key;
    status = Table->ConIn->ReadKeyStroke(Table->ConIn, &key);
    if (!EFI_ERROR(status)) {
      if (key.ScanCode == 0x17 || key.UnicodeChar == 27)
        return EFI_ABORTED;
      if (key.UnicodeChar == 'u' || key.UnicodeChar == 'U')
        return Gu.profile_verified && !Gu.fault ? EFI_SUCCESS : EFI_ACCESS_DENIED;
    } else if (status != EFI_NOT_READY) {
      return status;
    }
    GuStall(100000);
  }
  return EFI_TIMEOUT;
}

static VOID Halt(VOID) {
  Gu.retained = TRUE;
  GuLogText("STOP: cleanup cannot be proven. Resources remain reserved.\n"
            "POWER OFF using the physical power button; do not continue to Windows.\n");
  for (;;)
    Gu.bs->Stall(1000000);
}

static VOID LogContainment(VOID) {
  GuLog("BME containment: attribute_status=%#llx hardware_status=%#llx command=%#x cached=%#x pending=%u\n",
        (unsigned long long)Gu.master_attribute_status,
        (unsigned long long)Gu.master_hardware_status,
        (unsigned)Gu.master_last_command,
        (unsigned)Gu.master_last_attributes,
        (unsigned)Gu.master_attributes_pending);
}

/*
 * The hand over to Windows.
 *
 * The boot entry that runs this application points at the application, not at
 * the Windows Boot Manager, so Windows has to be started explicitly. The
 * application is loaded from the EFI system partition, and the Windows Boot
 * Manager lives on that same partition, so the partition does not have to be
 * searched for: the device handle of this image is the one to use.
 *
 * The Windows Boot Manager is started after the transaction and its clean up
 * are finished, and also after a cancelled attempt, so that the machine ends
 * up in Windows in either case.
 */
static EFI_STATUS BuildFileDevicePath(EFI_HANDLE Device, const CHAR16 *Name,
                                       EFI_DEVICE_PATH_PROTOCOL **Out) {
  EFI_DEVICE_PATH_PROTOCOL *base = NULL;
  EFI_DEVICE_PATH_PROTOCOL *node;
  EFI_DEVICE_PATH_PROTOCOL *end;
  EFI_STATUS status;
  UINTN baseBytes = 0;
  UINTN chars = 0;
  UINTN nodeBytes;
  UINTN total;
  UINT8 *data = NULL;

  *Out = NULL;
  status = Table->BootServices->HandleProtocol(Device, &PathGuid, (VOID **)&base);
  if (EFI_ERROR(status) || base == NULL) {
    return EFI_UNSUPPORTED;
  }

  /* Measure the device path, including its end node. */
  {
    EFI_DEVICE_PATH_PROTOCOL *cursor = base;
    for (;;) {
      UINTN length = cursor->Length[0] | ((UINTN)cursor->Length[1] << 8);
      if (length < 4) {
        return EFI_UNSUPPORTED;
      }
      baseBytes += length;
      if (cursor->Type == END_DEVICE_PATH_TYPE) {
        break;
      }
      cursor = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)cursor + length);
    }
  }

  while (Name[chars] && chars < 256) {
    chars++;
  }
  if (!chars || chars == 256) {
    return EFI_INVALID_PARAMETER;
  }

  nodeBytes = 4 + (chars + 1) * (UINTN)sizeof(CHAR16);
  total = baseBytes - 4 + nodeBytes + 4;
  status = Table->BootServices->AllocatePool(EfiBootServicesData, total, (VOID **)&data);
  if (EFI_ERROR(status) || data == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  /* Copy the device path without its end node, then append the file path
   * node and a fresh end node. */
  for (UINTN i = 0; i < baseBytes - 4; i++) {
    data[i] = ((UINT8 *)base)[i];
  }
  node = (EFI_DEVICE_PATH_PROTOCOL *)(data + baseBytes - 4);
  node->Type = MEDIA_DEVICE_PATH;
  node->SubType = MEDIA_FILEPATH_DP;
  node->Length[0] = (UINT8)nodeBytes;
  node->Length[1] = (UINT8)(nodeBytes >> 8);
  for (UINTN i = 0; i < (chars + 1) * (UINTN)sizeof(CHAR16); i++) {
    ((UINT8 *)node)[4 + i] = ((UINT8 *)Name)[i];
  }
  end = (EFI_DEVICE_PATH_PROTOCOL *)((UINT8 *)node + nodeBytes);
  end->Type = END_DEVICE_PATH_TYPE;
  end->SubType = END_ENTIRE_DEVICE_PATH_SUBTYPE;
  end->Length[0] = 4;
  end->Length[1] = 0;

  *Out = (VOID *)data;
  return EFI_SUCCESS;
}

static EFI_STATUS HandoffToWindows(VOID) {
  EFI_LOADED_IMAGE_PROTOCOL *loaded = NULL;
  EFI_DEVICE_PATH_PROTOCOL *path = NULL;
  EFI_HANDLE image = NULL;
  EFI_STATUS status;

  status = Table->BootServices->HandleProtocol(Gu.image, &LoadedImageGuid, (VOID **)&loaded);
  if (EFI_ERROR(status) || loaded == NULL || loaded->DeviceHandle == NULL) {
    GuLog("handoff: the loading image protocol is unavailable (%#llx)\n", (unsigned long long)status);
    return EFI_UNSUPPORTED;
  }

  status = BuildFileDevicePath(loaded->DeviceHandle, L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi", &path);
  if (EFI_ERROR(status)) {
    GuLog("handoff: the device path could not be built (%#llx)\n", (unsigned long long)status);
    return status;
  }

  status = Table->BootServices->LoadImage(FALSE, Gu.image, path, NULL, 0, &image);
  Table->BootServices->FreePool(path);
  if (EFI_ERROR(status)) {
    GuLog("handoff: the Windows Boot Manager could not be loaded (%#llx)\n", (unsigned long long)status);
    return status;
  }

  GuLog("handoff: the Windows Boot Manager was loaded, starting it\n");
  return Table->BootServices->StartImage(image, NULL, NULL);
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE Image, EFI_SYSTEM_TABLE *St) {
  if (!St || !St->BootServices || !St->RuntimeServices)
    return EFI_INVALID_PARAMETER;

  Table = St;
  GuInit(St->BootServices, NULL);
  Gu.image = Image;
  Gu.display_check = DisplayCheck;
  memset(&Board, 0, sizeof(Board));

  Stage = "log";
  EFI_STATUS status = GuIoOpen(Image, St);
  BOOLEAN attempted = FALSE;
  if (EFI_ERROR(status))
    goto finish;

  GuLog("Windows GPU UNLOCK (generic build): card is identified at run time.\n");

  /* Secure Boot must be off. The firmware assets are not signed, so a
   * firmware that enforces Secure Boot will refuse to load this image at
   * all; checking here turns that into a clear message. */
  Stage = "secure-boot";
  {
    UINT8 secure = 0xff;
    UINTN bytes = 1;
    status = St->RuntimeServices->GetVariable(L"SecureBoot", &GlobalGuid, NULL, &bytes, &secure);
    if (EFI_ERROR(status) || bytes != 1 || secure) {
      status = EFI_SECURITY_VIOLATION;
      goto finish;
    }
    status = Step(status);
    if (EFI_ERROR(status))
      goto finish;
  }

  Stage = "watchdog";
  status = Step(Gu.bs->SetWatchdogTimer(0, 0, 0, NULL));
  if (EFI_ERROR(status))
    goto finish;

  Stage = "target";
  status = Step(FindTarget());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "bar0";
  status = Step(BarCheck());
  if (EFI_ERROR(status))
    goto finish;

  /* Identify the card now that BAR0 is mapped. */
  Stage = "identify";
  if (!GuBoardIdentify(&Board)) {
    status = EFI_DEVICE_ERROR;
    goto finish;
  }
  GuBoardLog(&Board);
  if (!GuBoardIsSupportedDevice(Board.device_id)) {
    GuLogText("REFUSED: this card is not in the supported device list.\n");
    status = EFI_UNSUPPORTED;
    goto finish;
  }
  if (!GuBoardIsSupportedChip(Board.chip)) {
    GuLogText("REFUSED: unknown chip revision.\n");
    status = EFI_UNSUPPORTED;
    goto finish;
  }
  /* Publish the identity so the vendor core can prove the card is unchanged. */
  GuSetTargetIdentity(Board.device_id, Board.chip, Board.memory_mb);

  Stage = "config";
  status = Step(ConfigCheck(TRUE));
  if (EFI_ERROR(status))
    goto finish;

  Stage = "display";
  Gu.display_ok = DisplayCheck();
  status = Step(Gu.display_ok ? EFI_SUCCESS : EFI_UNSUPPORTED);
  if (EFI_ERROR(status))
    goto finish;

  Stage = "prom";
  status = Step(PromCheck());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "cold-state";
  status = Step(ColdCheck());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "ownership";
  status = Step(GuClaimController());
  if (EFI_ERROR(status))
    goto finish;

  /* Re-validate everything after taking ownership: the card must still be
   * exactly the card that was inspected. */
  Stage = "config-recheck";
  status = Step(ConfigCheck(FALSE));
  if (EFI_ERROR(status))
    goto finish;

  Stage = "bar0-recheck";
  status = Step(BarCheck());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "prom-recheck";
  status = Step(PromCheck());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "cold-recheck";
  status = Step(ColdCheck());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "assets";
  status = Step(GuLoadAssets());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "arming";
  status = Step(Arm());
  if (EFI_ERROR(status))
    goto finish;

  Stage = "armed-config";
  status = Step(ConfigCheck(FALSE));
  if (EFI_ERROR(status))
    goto finish;

  Stage = "armed-display";
  Gu.display_ok = DisplayCheck();
  status = Step(Gu.display_ok ? EFI_SUCCESS : EFI_UNSUPPORTED);
  if (EFI_ERROR(status))
    goto finish;

  Stage = "armed-cold-state";
  status = Step(ColdCheck());
  if (EFI_ERROR(status))
    goto finish;

  if (!Gu.profile_verified || Gu.fault) {
    status = EFI_ACCESS_DENIED;
    goto finish;
  }

  GuLogText("ARMED: one transaction is starting. Do not reset the machine.\n");
  if (!GuLogReady()) {
    status = EFI_DEVICE_ERROR;
    goto finish;
  }

  Stage = "transaction";
  Gu.armed = TRUE;
  attempted = TRUE;
  {
    UINT64 mask = 0xffffffffULL;
    struct pci_dev device = {
        .dev = {.dma_mask = &mask, .coherent_dma_mask = 0xffffffffULL},
        .pm_cap = Gu.pm_cap,
        .refs = 1};
    struct gpu_unlock_610_shared shared = {0};
    int result = gpu_unlock_610_load_shared(&device, &shared);
    if (!result)
      result = gpu_unlock_610_unlock(&device, &shared);
    /* This also covers failures before GuStarted, including the bus mastering
     * enable readback. */
    EFI_STATUS contained = GuClearMaster();
    LogContainment();
    GuLog("transaction result=%d containment=%#llx started=%u quiesced=%u fault=%u retained=%u maps=%u FLR=%u\n",
          result, (unsigned long long)contained, (unsigned)Gu.started, (unsigned)Gu.quiesced,
          (unsigned)Gu.fault, (unsigned)Gu.retained, (unsigned)Gu.dma_count, (unsigned)Gu.flrs);
    if (EFI_ERROR(contained) || !GuSafeToReturn() || Gu.allocations ||
        (Gu.started && result))
      Halt();
    gpu_unlock_610_release_shared(&shared);
    Gu.armed = FALSE;
    status = result ? EFI_DEVICE_ERROR : EFI_SUCCESS;
  }

finish:
  if (attempted && !GuSafeToReturn())
    Halt();
  Gu.armed = FALSE;
  if (GuLogReady())
    GuLog("FINAL status=%#llx stage=%s attempted=%u clean=%u\n",
          (unsigned long long)status, Stage, (unsigned)attempted,
          (unsigned)GuSafeToReturn());
  else
    GuConsole("Preflight or logging failed; no new attempt will start.\n");

  if (!GuLogReady()) {
    status = EFI_DEVICE_ERROR;
    if (Gu.started)
      Halt();
  }
  if (attempted && !GuSafeToReturn())
    Halt();

  EFI_STATUS closed = GuIoClose();
  if (EFI_ERROR(closed)) {
    if (Gu.started)
      Halt();
    status = closed;
  }
  if (Gu.owned) {
    closed = Gu.bs->CloseProtocol(Gu.handle, &PciGuid, Image, NULL);
    if (EFI_ERROR(closed)) {
      if (Gu.started)
        Halt();
      status = closed;
    } else {
      Gu.owned = FALSE;
    }
  }
  GuReleaseAssets();

  /* The boot entry points at this application, so the Windows Boot Manager
   * is started explicitly. This happens after a successful unlock and after
   * a cancelled or rejected attempt, so that the machine always ends up in
   * Windows. */
  if (!EFI_ERROR(status))
    GuConsole("UEFI transaction completed and cleaned up. Starting Windows.\n");
  else
    GuConsole("Attempt cancelled or rejected. Starting Windows.\n");

  EFI_STATUS handoff = HandoffToWindows();
  if (EFI_ERROR(handoff)) {
    GuConsole("Windows could not be started automatically. Use the firmware boot menu to start Windows.\n");
    return handoff;
  }
  return status;
}
