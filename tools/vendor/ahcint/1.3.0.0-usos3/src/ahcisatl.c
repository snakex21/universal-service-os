#include "ahcint.h"

/* ahcisatl.c - SCSI-to-ATA translation, ATAPI pass-through, command engine */

/* ------------------------------------------------------------------ */
/* 64-bit block number helpers (two ULONGs, no __int64 needed)         */
/* ------------------------------------------------------------------ */

static AHCI_LBA
AhciLbaFromBigEndian(IN PUCHAR Bytes, IN ULONG Count)
{
    AHCI_LBA lba;
    ULONG i;

    lba.Low = 0;
    lba.High = 0;
    for (i = 0; i < Count; i++) {
        lba.High = (lba.High << 8) | (lba.Low >> 24);
        lba.Low = (lba.Low << 8) | Bytes[i];
    }
    return lba;
}

static ULONG
AhciBigEndian32(IN PUCHAR Bytes)
{
    return ((ULONG)Bytes[0] << 24) | ((ULONG)Bytes[1] << 16) |
           ((ULONG)Bytes[2] << 8)  |  (ULONG)Bytes[3];
}

static VOID
AhciPutBigEndian32(OUT PUCHAR Bytes, IN ULONG Value)
{
    Bytes[0] = (UCHAR)(Value >> 24);
    Bytes[1] = (UCHAR)(Value >> 16);
    Bytes[2] = (UCHAR)(Value >> 8);
    Bytes[3] = (UCHAR)Value;
}

/* Last addressable LBA (capacity - 1); 0 for an empty/unknown device. */
static AHCI_LBA
AhciLastLba(IN PAHCI_PORT_INFO Pi)
{
    AHCI_LBA last = Pi->TotalSectors;

    if (last.Low == 0 && last.High == 0) return last;
    if (last.Low == 0) last.High--;
    last.Low--;
    return last;
}

/* Lba + Count <= capacity ? */
static BOOLEAN
AhciLbaRangeValid(IN PAHCI_PORT_INFO Pi, IN AHCI_LBA Lba, IN ULONG Count)
{
    ULONG endLow, endHigh;

    endLow = Lba.Low + Count;
    endHigh = Lba.High;
    if (endLow < Lba.Low) {
        if (endHigh == 0xFFFFFFFF) return FALSE;
        endHigh++;
    }

    if (endHigh != Pi->TotalSectors.High) return (BOOLEAN)(endHigh < Pi->TotalSectors.High);
    return (BOOLEAN)(endLow <= Pi->TotalSectors.Low);
}

/* 28-bit command usable? Same rule as Linux lba_28_ok(): the transfer
   must end below 2^28 and move at most 256 sectors. */
static BOOLEAN
AhciLbaFits28(IN AHCI_LBA Lba, IN ULONG Count)
{
    if (Lba.High != 0 || Lba.Low >= ATA_LBA28_LIMIT) return FALSE;
    if (Count > ATA_LBA28_MAX_SECTORS) return FALSE;
    return (BOOLEAN)((ATA_LBA28_LIMIT - Lba.Low) > Count);
}

/* ------------------------------------------------------------------ */
/* IDENTIFY DEVICE                                                     */
/* ------------------------------------------------------------------ */

/* Called once per port after IDENTIFY. Decides whether the disk takes
   48-bit (EXT) commands and what its capacity is. */
VOID
AhciParseIdentify(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port)
{
    PAHCI_PORT_INFO pi;
    PUSHORT id;
    AHCI_LBA lba48;

    pi = &HwInit->Ports[Port];
    id = (PUSHORT)pi->IdentifyData;

    pi->LbaSupported = FALSE;
    pi->Lba48 = FALSE;
    pi->TotalSectors.Low = 0;
    pi->TotalSectors.High = 0;

    if (!pi->IdentifyValid || pi->IsAtapi) return;

    pi->LbaSupported = (BOOLEAN)((id[IDW_CAPABILITIES] & IDW49_LBA_SUPPORTED) != 0);

    /* LBA48: word 83 valid (15:14 = 01) with bit 10, and words 100-103 != 0 */
    lba48.Low = (ULONG)id[IDW_LBA48_SECTORS] | ((ULONG)id[IDW_LBA48_SECTORS + 1] << 16);
    lba48.High = (ULONG)id[IDW_LBA48_SECTORS + 2] | ((ULONG)id[IDW_LBA48_SECTORS + 3] << 16);

    if (pi->LbaSupported &&
        (id[IDW_CMDSET_SUPPORTED_2] & IDW83_VALID_MASK) == IDW83_VALID &&
        (id[IDW_CMDSET_SUPPORTED_2] & IDW83_LBA48) &&
        (lba48.Low != 0 || lba48.High != 0)) {
        pi->Lba48 = TRUE;
        pi->TotalSectors = lba48;
    } else if (pi->LbaSupported) {
        pi->TotalSectors.Low = (ULONG)id[IDW_LBA28_SECTORS] | ((ULONG)id[IDW_LBA28_SECTORS + 1] << 16);
    }

    AHCI_DBG((AHCI_PFX "Port %lu: LBA=%s LBA48=%s (W83=%04lX W86=%04lX) sectors=%08lX:%08lX\n",
              Port,
              pi->LbaSupported ? "yes" : "no",
              pi->Lba48 ? "yes" : "no",
              (ULONG)id[IDW_CMDSET_SUPPORTED_2], (ULONG)id[IDW_CMDSET_ENABLED_2],
              pi->TotalSectors.High, pi->TotalSectors.Low));

    if (!pi->LbaSupported) {
        /* SATA mandates LBA; a CHS-only device is not addressable here. */
        AHCI_DBG((AHCI_PFX "Port %lu: device has no LBA support, not usable\n", Port));
    }
}

/* ------------------------------------------------------------------ */
/* Sense data                                                          */
/* ------------------------------------------------------------------ */

static VOID
AhciBuildSense(OUT PSENSE_DATA Sense, IN UCHAR Key, IN UCHAR Asc, IN UCHAR Ascq)
{
    ZeroMemoryBytes(Sense, sizeof(SENSE_DATA));
    Sense->ErrorCode = 0x70;
    Sense->Valid = (Key != SCSI_SENSE_NO_SENSE) ? 1 : 0;
    Sense->SenseKey = Key;
    Sense->AdditionalSenseLength = sizeof(SENSE_DATA) - 8;
    Sense->AdditionalSenseCode = Asc;
    Sense->AdditionalSenseCodeQualifier = Ascq;
}

#if AHCI_AUTOSENSE
static BOOLEAN
AhciAutoSenseWanted(IN PSCSI_REQUEST_BLOCK Srb)
{
    return (BOOLEAN)(Srb->SenseInfoBuffer != NULL &&
                     Srb->SenseInfoBufferLength != 0 &&
                     !(Srb->SrbFlags & SRB_FLAGS_DISABLE_AUTOSENSE));
}

static VOID
AhciSetAutoSense(IN PSCSI_REQUEST_BLOCK Srb, IN PVOID Sense, IN ULONG Length)
{
    ULONG n = Length;

    if (n > Srb->SenseInfoBufferLength) n = Srb->SenseInfoBufferLength;
    ZeroMemoryBytes(Srb->SenseInfoBuffer, Srb->SenseInfoBufferLength);
    CopyMemoryBytes(Srb->SenseInfoBuffer, Sense, n);
    Srb->SrbStatus |= SRB_STATUS_AUTOSENSE_VALID;
}
#endif

/* CHECK CONDITION with sense: auto-sense, or kept for the next REQUEST SENSE */
static VOID
AhciFailWithSense(
    IN PHW_DEVICE_EXTENSION HwInit,
    IN ULONG Port,
    IN PSCSI_REQUEST_BLOCK Srb,
    IN UCHAR Key,
    IN UCHAR Asc,
    IN UCHAR Ascq
)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];

    Srb->SrbStatus = SRB_STATUS_ERROR;
    Srb->ScsiStatus = SCSISTAT_CHECK_CONDITION;

    if (Key == SCSI_SENSE_NO_SENSE) return;     /* nothing specific to report */

#if AHCI_AUTOSENSE
    if (AhciAutoSenseWanted(Srb)) {
        SENSE_DATA sense;
        AhciBuildSense(&sense, Key, Asc, Ascq);
        AhciSetAutoSense(Srb, &sense, sizeof(SENSE_DATA));
        return;
    }
#endif

    pi->SensePending = TRUE;
    pi->SenseKey = Key;
    pi->SenseAsc = Asc;
    pi->SenseAscq = Ascq;
}

/* ATA Error register -> sense (subset of the SAT / libata mapping) */
static VOID
AhciAtaErrorToSense(IN ULONG Tfd, OUT PUCHAR Key, OUT PUCHAR Asc, OUT PUCHAR Ascq)
{
    UCHAR err = (UCHAR)(Tfd >> TFD_ERR_SHIFT);

    *Key = SCSI_SENSE_NO_SENSE;
    *Asc = 0;
    *Ascq = 0;

    if (!(Tfd & TFD_STS_ERR)) return;           /* HBA error / timeout */

    if (err & (IDE_ERROR_MEDIA_CHANGE | IDE_ERROR_MEDIA_CHANGE_REQ)) {
        *Key = SCSI_SENSE_UNIT_ATTENTION;  *Asc = AHCI_ASC_MEDIUM_CHANGED;
    } else if (err & IDE_ERROR_UNCORRECTABLE) {
        *Key = SCSI_SENSE_MEDIUM_ERROR;    *Asc = AHCI_ASC_UNRECOVERED_READ; *Ascq = 0x04;
    } else if (err & IDE_ERROR_ID_NOT_FOUND) {
        *Key = SCSI_SENSE_ABORTED_COMMAND; *Asc = 0x14;
    } else if (err & IDE_ERROR_ABORT) {
        *Key = SCSI_SENSE_ABORTED_COMMAND;
    } else {
        *Key = SCSI_SENSE_HARDWARE_ERROR;
    }
}

/* ------------------------------------------------------------------ */
/* Command engine (Fast Polling)                                       */
/* ------------------------------------------------------------------ */

#define AHCI_CMD_OK             0
#define AHCI_CMD_DEVICE_ERROR   1   /* PxTFD.ERR: device rejected/failed it */
#define AHCI_CMD_HBA_ERROR      2   /* fatal PxIS without ERR, or timeout */
#define AHCI_CMD_BAD_BUFFER     3   /* buffer could not be described */

static BOOLEAN
AhciBuildPrdt(
    IN PHW_DEVICE_EXTENSION HwInit,
    IN PSCSI_REQUEST_BLOCK Srb,
    IN PAHCI_PRDT_ENTRY Prdt,
    IN PVOID Buffer,
    IN ULONG Length,
    OUT PULONG Entries
)
{
    PUCHAR virt = (PUCHAR)Buffer;
    ULONG left = Length;
    ULONG index = 0;
    ULONG segLen;
    ULONG toPage;
    SCSI_PHYSICAL_ADDRESS phys;

    while (left > 0 && index < MAX_PRDT_ENTRIES) {
        phys = ScsiPortGetPhysicalAddress(HwInit, Srb, virt, &segLen);
        if (phys.LowPart == 0 && phys.HighPart == 0) return FALSE;

        if (segLen > left) segLen = left;
        toPage = 4096 - (phys.LowPart & 0xFFF);
        if (segLen > toPage) segLen = toPage;

        Prdt[index].DataBaseAddress = phys.LowPart;
        Prdt[index].DataBaseAddressUpper = (ULONG)phys.HighPart;
        Prdt[index].Reserved = 0;
        Prdt[index].ByteCountInterrupt = (segLen - 1) & 0x003FFFFF;

        virt += segLen;
        left -= segLen;
        index++;
    }

    if (left > 0) return FALSE;
    *Entries = index;
    return TRUE;
}

/* Issue one command on slot 0 and poll it to completion. */
static ULONG
AhciRunCommand(
    IN PHW_DEVICE_EXTENSION HwInit,
    IN ULONG Port,
    IN PSCSI_REQUEST_BLOCK Srb,
    IN PATA_REQUEST Req
)
{
    PAHCI_PORT_INFO pi;
    PUCHAR portBase;
    PAHCI_COMMAND_HEADER cmdHeader;
    PFIS_REG_H2D fis;
    PUCHAR acmd;
    PAHCI_PRDT_ENTRY prdt;
    ULONG prdtEntries;
    ULONG elapsed;
    ULONG ci, portIs, tfd;
    ULONG result;
    ULONG i;

    pi = &HwInit->Ports[Port];
    portBase = AHCI_PORT_BASE(HwInit->AbarMapped, Port);
    cmdHeader = &pi->CommandList[0];
    fis = (PFIS_REG_H2D)pi->CommandTable;
    acmd = pi->CommandTable + AHCI_CMDTBL_ACMD_OFFSET;
    prdt = (PAHCI_PRDT_ENTRY)(pi->CommandTable + AHCI_CMDTBL_PRDT_OFFSET);

    /* MODIFIED (USOS 1.3.0.0-usos2): the port must have a link and a
       running command engine (ST, FRE, CR, FR) before a command is
       issued; restart it once, otherwise fail the command instead of
       writing CI to an engine that never runs it. */
    {
        ULONG cmdReg = AHCI_READ_REG(portBase, AHCI_PORT_CMD);
        ULONG sstsReg = AHCI_READ_REG(portBase, AHCI_PORT_SSTS);
        if ((sstsReg & AHCI_SSTS_DET_MASK) != AHCI_SSTS_DET_PHY ||
            (cmdReg & (AHCI_PORT_CMD_ST | AHCI_PORT_CMD_FRE | AHCI_PORT_CMD_CR | AHCI_PORT_CMD_FR)) !=
                (AHCI_PORT_CMD_ST | AHCI_PORT_CMD_FRE | AHCI_PORT_CMD_CR | AHCI_PORT_CMD_FR)) {
            HwInit->UsosEngineDown++;
            AhciRestartPort(HwInit, portBase);
            ScsiPortStallExecution(1000);
            cmdReg = AHCI_READ_REG(portBase, AHCI_PORT_CMD);
            sstsReg = AHCI_READ_REG(portBase, AHCI_PORT_SSTS);
            if ((sstsReg & AHCI_SSTS_DET_MASK) != AHCI_SSTS_DET_PHY ||
                !(cmdReg & AHCI_PORT_CMD_ST) || !(cmdReg & AHCI_PORT_CMD_FRE)) {
                HwInit->UsosErrors++;
                return AHCI_CMD_HBA_ERROR;
            }
        }
    }

    /* Data */
    prdtEntries = 0;
    if (Req->DataBufferLen > 0) {
        if (Req->UseBounce) {
            prdt[0].DataBaseAddress = pi->BouncePhysical;
            prdt[0].DataBaseAddressUpper = pi->BouncePhysicalUpper;
            prdt[0].Reserved = 0;
            prdt[0].ByteCountInterrupt = Req->DataBufferLen - 1;
            prdtEntries = 1;
        } else if (!AhciBuildPrdt(HwInit, Srb, prdt, Req->DataBuffer, Req->DataBufferLen, &prdtEntries)) {
            AHCI_DBG((AHCI_PFX "Port %lu: cannot build PRDT for %lu bytes\n", Port, Req->DataBufferLen));
            return AHCI_CMD_BAD_BUFFER;
        }
    }

    cmdHeader->Flags = (USHORT)(AHCI_CMDHDR_CFL_H2D |
                                (Req->IsAtapi ? AHCI_CMDHDR_ATAPI : 0) |
                                ((Req->IsWrite && Req->DataBufferLen > 0) ? AHCI_CMDHDR_WRITE : 0));
    cmdHeader->PrdtLength = (USHORT)prdtEntries;
    cmdHeader->PrdByteCount = 0;
    cmdHeader->CommandTableBase = pi->CommandTablePhysical;
    cmdHeader->CommandTableBaseUpper = pi->CommandTablePhysicalUpper;

    /* FIS */
    ZeroMemoryBytes(fis, sizeof(FIS_REG_H2D));
    fis->FisType = FIS_TYPE_REG_H2D;
    fis->PmPortControl = FIS_H2D_COMMAND;

    if (Req->IsAtapi) {
        ULONG byteCount = (Req->DataBufferLen > 0xFFFE) ? 0xFFFE : Req->DataBufferLen;

        ZeroMemoryBytes(acmd, 16);
        for (i = 0; i < Req->CdbLength && i < 16; i++) acmd[i] = Req->Cdb[i];

        fis->Command = IDE_COMMAND_PACKET;
#ifdef AHCI_NT4
        /* NT4/9x: DMA bit on every packet */
        fis->FeaturesLow = 0x01;
#else
        fis->FeaturesLow = (Req->DataBufferLen > 0) ? 0x01 : 0x00;      /* DMA */
#endif
        fis->Lba1 = (UCHAR)(byteCount & 0xFF);
        fis->Lba2 = (UCHAR)((byteCount >> 8) & 0xFF);
    } else {
        fis->Command = Req->Command;
        fis->Lba0 = (UCHAR)(Req->Lba.Low);
        fis->Lba1 = (UCHAR)(Req->Lba.Low >> 8);
        fis->Lba2 = (UCHAR)(Req->Lba.Low >> 16);
        if (Req->Is48Bit) {
            fis->Device = ATA_DEV_LBA;
            fis->Lba3 = (UCHAR)(Req->Lba.Low >> 24);
            fis->Lba4 = (UCHAR)(Req->Lba.High);
            fis->Lba5 = (UCHAR)(Req->Lba.High >> 8);
            /* 65536 sectors is encoded as 0 */
            fis->SectorCountLow = (UCHAR)(Req->SectorCount);
            fis->SectorCountHigh = (UCHAR)(Req->SectorCount >> 8);
        } else {
            fis->Device = (UCHAR)(ATA_DEV_LBA | ((Req->Lba.Low >> 24) & 0x0F));
            /* 256 sectors is encoded as 0 */
            fis->SectorCountLow = (UCHAR)(Req->SectorCount);
        }
    }

    /* Go */
    AHCI_WRITE_REG(portBase, AHCI_PORT_IS, 0xFFFFFFFF);
    AHCI_WRITE_REG(portBase, AHCI_PORT_SERR, 0xFFFFFFFF);
    AHCI_WRITE_REG(portBase, AHCI_PORT_IE, 0);
    AHCI_WRITE_REG(HwInit->AbarMapped, AHCI_GEN_IS, (1UL << Port));

    AHCI_WRITE_REG(portBase, AHCI_PORT_CI, 1);

    result = AHCI_CMD_OK;
    elapsed = 0;
    for (;;) {
        ci = AHCI_READ_REG(portBase, AHCI_PORT_CI);
        portIs = AHCI_READ_REG(portBase, AHCI_PORT_IS);
        tfd = AHCI_READ_REG(portBase, AHCI_PORT_TFD);

        if ((portIs & AHCI_PORT_IS_FATAL) || (tfd & TFD_STS_ERR)) {
            result = (tfd & TFD_STS_ERR) ? AHCI_CMD_DEVICE_ERROR : AHCI_CMD_HBA_ERROR;
            break;
        }
        if (!(ci & 1)) break;
        if (elapsed >= AHCI_POLL_TIMEOUT_USEC) {
            result = AHCI_CMD_HBA_ERROR;
            break;
        }
        ScsiPortStallExecution(AHCI_POLL_INTERVAL_USEC);
        elapsed += AHCI_POLL_INTERVAL_USEC;
    }

    if (portIs != 0) AHCI_WRITE_REG(portBase, AHCI_PORT_IS, portIs);
    if (portIs & AHCI_PORT_IS_FATAL) AHCI_WRITE_REG(portBase, AHCI_PORT_SERR, 0xFFFFFFFF);
    AHCI_WRITE_REG(HwInit->AbarMapped, AHCI_GEN_IS, (1UL << Port));

    pi->LastTfd = tfd;

    /* MODIFIED (USOS 1.3.0.0-usos2): counters, and the HBA's PRD byte
       count must match the request (an HBA that did not move the data
       leaves it short); a mismatch is counted for the trace. */
    if (result == AHCI_CMD_OK && Req->DataBufferLen > 0 && !Req->IsAtapi) {
        if (Req->IsWrite) { HwInit->UsosWrites++; HwInit->UsosWriteSectors += Req->SectorCount; }
        else HwInit->UsosReads++;
        if (cmdHeader->PrdByteCount != Req->DataBufferLen) HwInit->UsosPrdbcBad++;
    }
    if (result != AHCI_CMD_OK && !Req->IsAtapi) {
        /* MODIFIED (USOS 1.3.0.0-usos3): disk (ATA) failures only, the last
           one on the line (a DVD drive without a disc fails TEST UNIT READY
           all the time) */
        HwInit->UsosErrors++;
        HwInit->UsosLastErrLba = Req->Lba.Low;
        HwInit->UsosLastErrTfd = tfd;
        HwInit->UsosLastErrCmd = (ULONG)Req->Command | (portIs & 0xFFFFFF00);
        if (Req->DataBufferLen > 0)
            HwInit->UsosStage |= Req->IsWrite ? USOS_STAGE_WRERR : USOS_STAGE_RDERR;
        AhciUsosShow(HwInit);
    } else if (result == AHCI_CMD_OK && (++HwInit->UsosIos & 0x3F) == 0) {
        AhciUsosShow(HwInit);
    }

    if (result != AHCI_CMD_OK) {
        AHCI_DBG((AHCI_PFX "Port %lu: cmd %02lX %s, TFD=%08lX IS=%08lX CI=%08lX\n",
                  Port,
                  (ULONG)(Req->IsAtapi ? Req->Cdb[0] : Req->Command),
                  (elapsed >= AHCI_POLL_TIMEOUT_USEC) ? "timed out" : "failed",
                  tfd, portIs, ci));
        AhciRestartPort(HwInit, portBase);
    }
    return result;
}

/* ATAPI command with data in the port's bounce buffer */
static ULONG
AhciAtapiBounceCommand(
    IN PHW_DEVICE_EXTENSION HwInit,
    IN ULONG Port,
    IN PUCHAR Cdb,
    IN ULONG DataLength
)
{
    ATA_REQUEST req;

    ZeroMemoryBytes(&req, sizeof(req));
    req.IsAtapi = TRUE;
    req.UseBounce = TRUE;
    req.DataBufferLen = DataLength;
    req.Cdb = Cdb;
    req.CdbLength = 12;

    ZeroMemoryBytes(HwInit->Ports[Port].BounceBuffer, AHCI_BOUNCE_SIZE);
    return AhciRunCommand(HwInit, Port, NULL, &req);
}

/* ------------------------------------------------------------------ */
/* Commands answered by the driver itself                              */
/* ------------------------------------------------------------------ */

static VOID
AhciExtractAtaString(
    IN PUSHORT IdentifyWords,
    IN ULONG StartWord,
    IN ULONG NumWords,
    OUT PUCHAR OutBuffer,
    IN ULONG OutBufferMax
)
{
    ULONG i;
    ULONG outIndex = 0;
    USHORT w;

    for (i = 0; i < NumWords && (outIndex + 1) < OutBufferMax; i++) {
        w = IdentifyWords[StartWord + i];
        OutBuffer[outIndex++] = (UCHAR)(w >> 8);
        OutBuffer[outIndex++] = (UCHAR)w;
    }
    while (outIndex > 0 && (OutBuffer[outIndex - 1] == ' ' || OutBuffer[outIndex - 1] == '\0')) {
        outIndex--;
    }
    while (outIndex < OutBufferMax) {
        OutBuffer[outIndex++] = ' ';
    }
}

static VOID
AhciCopyToSrb(IN PSCSI_REQUEST_BLOCK Srb, IN PVOID Data, IN ULONG Length)
{
    ULONG n = Length;

    if (Srb->DataBuffer == NULL) return;
    if (n > Srb->DataTransferLength) n = Srb->DataTransferLength;
    ZeroMemoryBytes(Srb->DataBuffer, Srb->DataTransferLength);
    CopyMemoryBytes(Srb->DataBuffer, Data, n);
}

/* EVPD: supported-pages list and unit serial number (IDENTIFY 10..19) */
static VOID
AhciHandleInquiryVpd(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    UCHAR page[4 + 20];
    ULONG len;

    ZeroMemoryBytes(page, sizeof(page));
    page[0] = pi->IsAtapi ? READ_ONLY_DIRECT_ACCESS_DEVICE : DIRECT_ACCESS_DEVICE;
    page[1] = Srb->Cdb[2];

    switch (Srb->Cdb[2]) {
    case AHCI_VPD_SUPPORTED_PAGES:
        page[3] = 2;
        page[4] = AHCI_VPD_SUPPORTED_PAGES;
        page[5] = AHCI_VPD_SERIAL_NUMBER;
        len = 4 + 2;
        break;

    case AHCI_VPD_SERIAL_NUMBER:
        page[3] = 20;
        if (pi->IdentifyValid) {
            AhciExtractAtaString((PUSHORT)pi->IdentifyData, IDW_SERIAL, 10, &page[4], 20);
        } else {
            ULONG i;
            for (i = 0; i < 20; i++) page[4 + i] = ' ';
        }
        len = 4 + 20;
        break;

    default:
        AhciFailWithSense(HwInit, Port, Srb, SCSI_SENSE_ILLEGAL_REQUEST, AHCI_ASC_INVALID_CDB_FIELD, 0);
        return;
    }

    if (len > Srb->Cdb[4]) len = Srb->Cdb[4];
    AhciCopyToSrb(Srb, page, len);
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

static VOID
AhciHandleInquiry(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    PUSHORT id = (PUSHORT)pi->IdentifyData;
    INQUIRYDATA inq;
    PUCHAR v;
    PUCHAR p;
    ULONG i;

    if (Srb->Cdb[1] & 0x01) {
        AhciHandleInquiryVpd(HwInit, Port, Srb);
        return;
    }
    if (Srb->Cdb[2] != 0) {                     /* page code without EVPD */
        AhciFailWithSense(HwInit, Port, Srb, SCSI_SENSE_ILLEGAL_REQUEST, AHCI_ASC_INVALID_CDB_FIELD, 0);
        return;
    }

    ZeroMemoryBytes(&inq, sizeof(inq));

    inq.DeviceType = pi->IsAtapi ? READ_ONLY_DIRECT_ACCESS_DEVICE : DIRECT_ACCESS_DEVICE;
    inq.RemovableMedia = pi->IsAtapi ? 1 : ((id[IDW_GENERAL_CONFIG] & (1 << 7)) ? 1 : 0);
    /* ATAPI stays unversioned */
    inq.Versions = pi->IsAtapi ? 0 : AHCI_INQUIRY_VERSION_SPC3;
    inq.ResponseDataFormat = 2;
    inq.AdditionalLength = 31;
    inq.CommandQueue = 0;       /* one command at a time */

    if (pi->IdentifyValid) {
        AhciExtractAtaString(id, IDW_MODEL, 4, inq.VendorId, 8);
        AhciExtractAtaString(id, IDW_MODEL + 4, 8, inq.ProductId, 16);
        AhciExtractAtaString(id, IDW_FIRMWARE, 2, inq.ProductRevisionLevel, 4);
    } else {
        v = (PUCHAR)(pi->IsAtapi ? "ATAPI   " : "ATA     ");
        p = (PUCHAR)(pi->IsAtapi ? "SATA CD-ROM     " : "SATA HARDDISK   ");
        for (i = 0; i < 8; i++) inq.VendorId[i] = v[i];
        for (i = 0; i < 16; i++) inq.ProductId[i] = p[i];
        inq.ProductRevisionLevel[0] = '1';
        inq.ProductRevisionLevel[1] = '.';
        inq.ProductRevisionLevel[2] = '0';
        inq.ProductRevisionLevel[3] = '0';
    }

    AhciCopyToSrb(Srb, &inq, sizeof(inq));
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

/* READ CAPACITY(10): last LBA saturates at 0xFFFFFFFF, which tells the
   class driver to use READ CAPACITY(16). */
static VOID
AhciHandleReadCapacity10(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR data[8];
    AHCI_LBA last = AhciLastLba(&HwInit->Ports[Port]);

    AhciPutBigEndian32(&data[0], (last.High != 0) ? 0xFFFFFFFF : last.Low);
    AhciPutBigEndian32(&data[4], AHCI_SECTOR_SIZE);

    AhciCopyToSrb(Srb, data, sizeof(data));
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

/* SERVICE ACTION IN(16) / READ CAPACITY(16): full 64-bit last LBA */
static VOID
AhciHandleReadCapacity16(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR data[AHCI_READ_CAPACITY16_DATA_LEN];
    AHCI_LBA last = AhciLastLba(&HwInit->Ports[Port]);
    ULONG allocLen = AhciBigEndian32(&Srb->Cdb[10]);
    ULONG n;

    ZeroMemoryBytes(data, sizeof(data));
    AhciPutBigEndian32(&data[0], last.High);
    AhciPutBigEndian32(&data[4], last.Low);
    AhciPutBigEndian32(&data[8], AHCI_SECTOR_SIZE);

    n = sizeof(data);
    if (n > allocLen) n = allocLen;
    AhciCopyToSrb(Srb, data, n);
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

static VOID
AhciHandleRequestSenseAta(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    SENSE_DATA sense;

    if (pi->SensePending) {
        AhciBuildSense(&sense, pi->SenseKey, pi->SenseAsc, pi->SenseAscq);
        pi->SensePending = FALSE;
    } else {
        AhciBuildSense(&sense, SCSI_SENSE_NO_SENSE, 0, 0);
    }

    AhciCopyToSrb(Srb, &sense, sizeof(sense));
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

/* ATA MODE SENSE: block descriptor and page 04h; other pages header only */
static VOID
AhciHandleModeSenseAta(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    PUSHORT id = (PUSHORT)pi->IdentifyData;
    BOOLEAN ten = (BOOLEAN)(Srb->Cdb[0] == SCSIOP_MODE_SENSE10);
    BOOLEAN dbd = (BOOLEAN)((Srb->Cdb[1] & 0x08) != 0);
    BOOLEAN llba = (BOOLEAN)(ten && (Srb->Cdb[1] & 0x10) != 0);    /* LLBAA */
    UCHAR pageCode = (UCHAR)(Srb->Cdb[2] & 0x3F);
    ULONG allocLen;
    UCHAR buf[96];      /* MODIFIED (USOS 1.3.0.0-usos1): 64 -> 96, room for page 08h */
    ULONG hdrLen, len, descLen;
    ULONG blocks, cyls, heads, spt;
    PUCHAR p;

    allocLen = ten ? (((ULONG)Srb->Cdb[7] << 8) | Srb->Cdb[8]) : Srb->Cdb[4];

    ZeroMemoryBytes(buf, sizeof(buf));
    hdrLen = ten ? 8 : 4;
    len = hdrLen;

    descLen = 0;
    if (!dbd && llba) {
        /* Long LBA block descriptor (MODE SENSE(10) only): 64-bit count */
        p = &buf[len];
        AhciPutBigEndian32(&p[0], pi->TotalSectors.High);
        AhciPutBigEndian32(&p[4], pi->TotalSectors.Low);
        AhciPutBigEndian32(&p[12], AHCI_SECTOR_SIZE);
        descLen = 16;
        len += 16;
    } else if (!dbd) {
        /* Short block descriptor: 24-bit block count, saturating */
        blocks = (pi->TotalSectors.High != 0 || pi->TotalSectors.Low > 0xFFFFFF)
                     ? 0xFFFFFF : pi->TotalSectors.Low;
        p = &buf[len];
        p[1] = (UCHAR)(blocks >> 16);
        p[2] = (UCHAR)(blocks >> 8);
        p[3] = (UCHAR)blocks;
        p[5] = (UCHAR)(AHCI_SECTOR_SIZE >> 16);
        p[6] = (UCHAR)(AHCI_SECTOR_SIZE >> 8);
        p[7] = (UCHAR)AHCI_SECTOR_SIZE;
        descLen = 8;
        len += 8;
    }

    if (pageCode == 0x04 || pageCode == 0x3F) {
        cyls = heads = spt = 0;
        if (pi->IdentifyValid) {
            cyls = id[IDW_CYLINDERS];
            heads = id[IDW_HEADS];
            spt = id[IDW_SECTORS_PER_TRACK];
        }
        if (cyls == 0 || heads == 0 || spt == 0) {
            ULONG total32 = (pi->TotalSectors.High != 0) ? 0xFFFFFFFF : pi->TotalSectors.Low;
            heads = 255;
            spt = 63;
            cyls = total32 / (heads * spt);
            if (cyls == 0) cyls = 1;
        }
        p = &buf[len];
        p[0] = 0x04;
        p[1] = 0x16;
        p[2] = (UCHAR)(cyls >> 16);
        p[3] = (UCHAR)(cyls >> 8);
        p[4] = (UCHAR)cyls;
        p[5] = (UCHAR)heads;
        p[20] = (UCHAR)(spt >> 8);      /* rotation-rate field */
        p[21] = (UCHAR)spt;
        len += 24;
    }

    /* MODIFIED (USOS 1.3.0.0-usos1): the caching page (08h), WCE from
       IDENTIFY word 85 bit 5, so the class driver knows about the write
       cache and sends SYNCHRONIZE CACHE for flushes. */
    if ((pageCode == 0x08 || pageCode == 0x3F) && len + 20 <= sizeof(buf)) {
        p = &buf[len];
        p[0] = 0x08;
        p[1] = 0x12;
        if (pi->IdentifyValid && (id[IDW_CMDSET_ENABLED_1] & IDW85_WRITE_CACHE)) p[2] = 0x04;  /* WCE */
        len += 20;
    }

    if (ten) {
        buf[0] = (UCHAR)((len - 2) >> 8);
        buf[1] = (UCHAR)(len - 2);
        buf[4] = (UCHAR)((descLen == 16) ? 0x01 : 0x00);    /* LONGLBA */
        buf[7] = (UCHAR)descLen;
    } else {
        buf[0] = (UCHAR)(len - 1);
        buf[3] = (UCHAR)descLen;
    }

    if (len > allocLen) len = allocLen;
    AhciCopyToSrb(Srb, buf, len);
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

/* ------------------------------------------------------------------ */
/* ATA disk read/write                                                 */
/* ------------------------------------------------------------------ */

/* MODIFIED (USOS 1.3.0.0-usos1): FLUSH CACHE (EXT). 1.3.0.0 completed
   SYNCHRONIZE CACHE, SRB_FUNCTION_FLUSH and SRB_FUNCTION_SHUTDOWN without
   telling the drive, so data in the drive's write cache was never forced
   out (lost on power-off after shutdown; FUA writes not honoured). A drive
   that aborts the command (no FLUSH CACHE support) counts as flushed. */
BOOLEAN
AhciFlushPort(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port)
{
    PAHCI_PORT_INFO pi;
    ATA_REQUEST req;
    ULONG result;

    if (Port >= MAX_SUPPORTED_PORTS) return FALSE;
    pi = &HwInit->Ports[Port];
    if (!pi->Present || pi->IsAtapi) return TRUE;

    ZeroMemoryBytes(&req, sizeof(req));
    req.Command = (UCHAR)(pi->Lba48 ? AHCI_ATA_FLUSH_CACHE_EXT : AHCI_ATA_FLUSH_CACHE);
    req.Is48Bit = pi->Lba48;
    result = AhciRunCommand(HwInit, Port, NULL, &req);
    /* MODIFIED (USOS 1.3.0.0-usos2): flushes are counted (the trace is
       written at start, every 2048 writes and at shutdown) */
    HwInit->UsosFlushes++;
    /* MODIFIED (USOS 1.3.0.0-usos3): the first flush is a stage */
    AhciUsosStage(HwInit, USOS_STAGE_FLUSH, "flush1");
    if (result == AHCI_CMD_DEVICE_ERROR && (pi->LastTfd & 0x0400)) {
        /* ERR with ABRT in the error register (TFD bits 15:8): not supported */
        return TRUE;
    }
    return (BOOLEAN)(result == AHCI_CMD_OK);
}

/* MODIFIED (USOS 1.3.0.0-usos2/usos3): the USOS gap, see ahcint.h */
static const UCHAR UsosMagic[12] = { 'U','S','O','S','W','2','K','T','R','A','C','E' };

/* MODIFIED (USOS 1.3.0.0-usos3): ntoskrnl services for the diagnostic build
   (all exported by the Windows 2000 SP4 kernel; miniport.h declares none). */
__declspec(dllimport) PVOID __stdcall MmMapIoSpace(IN PHYSICAL_ADDRESS PhysicalAddress, IN ULONG NumberOfBytes, IN ULONG CacheType);
__declspec(dllimport) BOOLEAN __stdcall KeRegisterBugCheckCallback(IN PVOID CallbackRecord, IN PVOID CallbackRoutine,
                                                                   IN PVOID Buffer, IN ULONG Length, IN PUCHAR Component);
__declspec(dllimport) VOID __stdcall KeBugCheckEx(IN ULONG BugCheckCode, IN ULONG_PTR P1, IN ULONG_PTR P2,
                                                  IN ULONG_PTR P3, IN ULONG_PTR P4);
__declspec(dllimport) extern ULONG KiBugCheckData[5];

static ULONG g_UsosInstances;
static UCHAR g_UsosComponent[] = "AHCINT-USOS";

static ULONG
AhciUsosSectorAt(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN AHCI_LBA Lba, IN BOOLEAN IsWrite)
{
    ATA_REQUEST req;

    ZeroMemoryBytes(&req, sizeof(req));
    req.UseBounce = TRUE;
    req.DataBufferLen = 512;
    req.IsWrite = IsWrite;
    req.Lba = Lba;
    req.SectorCount = 1;
    if (AhciLbaFits28(Lba, 1)) {
        req.Command = IsWrite ? IDE_COMMAND_WRITE_DMA : IDE_COMMAND_READ_DMA;
    } else {
        req.Is48Bit = TRUE;
        req.Command = IsWrite ? IDE_COMMAND_WRITE_DMA_EXT : IDE_COMMAND_READ_DMA_EXT;
    }
    return AhciRunCommand(HwInit, Port, NULL, &req);
}

static ULONG
AhciUsosSector(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN ULONG Lba, IN BOOLEAN IsWrite)
{
    AHCI_LBA lba;

    lba.Low = Lba;
    lba.High = 0;
    return AhciUsosSectorAt(HwInit, Port, lba, IsWrite);
}

static PCHAR
UsosPutStr(PCHAR p, PCHAR end, const char *s)
{
    while (*s && p < end) *p++ = *s++;
    return p;
}

static PCHAR
UsosPutHexN(PCHAR p, PCHAR end, ULONG v, ULONG digits)
{
    static const char hex[] = "0123456789ABCDEF";
    LONG shift;
    for (shift = (LONG)(digits * 4) - 4; shift >= 0 && p < end; shift -= 4) *p++ = hex[(v >> shift) & 0xF];
    return p;
}

static PCHAR
UsosPutHex(PCHAR p, PCHAR end, ULONG v)
{
    return UsosPutHexN(p, end, v, 8);
}

static PCHAR
UsosPutField(PCHAR p, PCHAR end, const char *name, ULONG v)
{
    p = UsosPutStr(p, end, " ");
    p = UsosPutStr(p, end, name);
    p = UsosPutStr(p, end, "=");
    return UsosPutHex(p, end, v);
}

/* The status line: one 80-column row of the VGA text buffer per HBA
   (row = instance). Text-mode Setup draws in VGA text mode, and the screen
   a STOP leaves on these boards is text mode too ("_"), so the line is
   visible in both; in a graphics mode the writes land off-screen.

   AHCINT3 1022:43C8 p2 MK:OK T:OK R:0001A2F3 W:00003F10 E:0000 LW:00A1B2C3 S:0F

   p    port of the USOS disk (else the last ATA port probed, "-" none)
   MK   marker at LBA 2046: OK, NO (read, not there), RE (read error), -- (no disk)
   T    write/read-back test at 2045: OK, XX failed, -- not run
   R/W  completed reads/writes (rising R during the file copy = AHCINT
        serves the disk Setup copies from and to)
   E    failed commands; LW last written LBA; S stages (USOS_STAGE_*) */
VOID
AhciUsosShow(IN PHW_DEVICE_EXTENSION HwInit)
{
    CHAR line[80];
    PCHAR p, end;
    PUSHORT row;
    ULONG i, port;
    USHORT attr;

    if (HwInit->UsosVga == NULL || HwInit->UsosInstance > 1) return;
    for (i = 0; i < 80; i++) line[i] = ' ';
    p = line;
    end = line + 80;
    p = UsosPutStr(p, end, "AHCINT3 ");
    p = UsosPutHexN(p, end, HwInit->UsosPciId & 0xFFFF, 4);
    p = UsosPutStr(p, end, ":");
    p = UsosPutHexN(p, end, HwInit->UsosPciId >> 16, 4);
    p = UsosPutStr(p, end, " p");
    port = HwInit->UsosTracePortPlus1 ? HwInit->UsosTracePortPlus1 : HwInit->UsosProbePortPlus1;
    if (port) p = UsosPutHexN(p, end, port - 1, 1); else p = UsosPutStr(p, end, "-");
    p = UsosPutStr(p, end, " MK:");
    switch (HwInit->UsosMarker) {
    case USOS_MARKER_OK: p = UsosPutStr(p, end, "OK"); break;
    case USOS_MARKER_ABSENT: p = UsosPutStr(p, end, "NO"); break;
    case USOS_MARKER_READ_ERROR: p = UsosPutStr(p, end, "RE"); break;
    default: p = UsosPutStr(p, end, "--"); break;
    }
    p = UsosPutStr(p, end, " T:");
    p = UsosPutStr(p, end, HwInit->UsosVerify == 1 ? "OK" : HwInit->UsosVerify == 2 ? "XX" : "--");
    p = UsosPutStr(p, end, " R:");
    p = UsosPutHex(p, end, HwInit->UsosReads);
    p = UsosPutStr(p, end, " W:");
    p = UsosPutHex(p, end, HwInit->UsosWrites);
    p = UsosPutStr(p, end, " E:");
    p = UsosPutHexN(p, end, HwInit->UsosErrors, 4);
    p = UsosPutStr(p, end, " LW:");
    p = UsosPutHex(p, end, HwInit->UsosLastWriteLba);
    p = UsosPutStr(p, end, " S:");
    p = UsosPutHexN(p, end, HwInit->UsosStage, 2);

    attr = (USHORT)((HwInit->UsosErrors || HwInit->UsosVerify == 2 ||
                     (HwInit->UsosStage & (USOS_STAGE_RBFAIL | USOS_STAGE_BUGCHECK)) ||
                     HwInit->UsosMarker == USOS_MARKER_READ_ERROR) ? 0x4F00 : 0x1F00);
    row = HwInit->UsosVga + HwInit->UsosInstance * 80;
    for (i = 0; i < 80; i++) row[i] = (USHORT)(attr | (UCHAR)line[i]);
}

/* The trace record: one ASCII sector in the ring at USOS_GAP_TRACE_LBA. */
VOID
AhciUsosTrace(IN PHW_DEVICE_EXTENSION HwInit, IN PCHAR Why)
{
    ULONG port, tp, i;
    PUCHAR buf;
    PCHAR p, end;

    if (HwInit->UsosTracePortPlus1 == 0 || HwInit->UsosInTrace) return;
    HwInit->UsosInTrace = 1;
    tp = HwInit->UsosTracePortPlus1 - 1;
    buf = HwInit->Ports[tp].BounceBuffer;
    ZeroMemoryBytes(buf, 512);
    p = (PCHAR)buf;
    end = (PCHAR)buf + 510;
    p = UsosPutStr(p, end, "AHCINT 1.3.0.0-usos3 why=");
    p = UsosPutStr(p, end, Why);
    p = UsosPutField(p, end, "boot", HwInit->UsosBoot);
    p = UsosPutField(p, end, "id", HwInit->UsosPciId);
    p = UsosPutField(p, end, "port", tp);
    p = UsosPutField(p, end, "verify", HwInit->UsosVerify);
    p = UsosPutField(p, end, "stage", HwInit->UsosStage);
    p = UsosPutStr(p, end, "\r\n");
    p = UsosPutField(p, end, "rd", HwInit->UsosReads);
    p = UsosPutField(p, end, "wr", HwInit->UsosWrites);
    p = UsosPutField(p, end, "wrsec", HwInit->UsosWriteSectors);
    p = UsosPutField(p, end, "err", HwInit->UsosErrors);
    p = UsosPutField(p, end, "prdbc", HwInit->UsosPrdbcBad);
    p = UsosPutField(p, end, "eng", HwInit->UsosEngineDown);
    p = UsosPutField(p, end, "flush", HwInit->UsosFlushes);
    p = UsosPutStr(p, end, "\r\n");
    p = UsosPutField(p, end, "lw", HwInit->UsosLastWriteLba);
    p = UsosPutField(p, end, "w0", HwInit->UsosFirstWrites[0]);
    p = UsosPutField(p, end, "w1", HwInit->UsosFirstWrites[1]);
    p = UsosPutField(p, end, "w2", HwInit->UsosFirstWrites[2]);
    p = UsosPutField(p, end, "w3", HwInit->UsosFirstWrites[3]);
    p = UsosPutField(p, end, "rb", HwInit->UsosRbChecks);
    p = UsosPutField(p, end, "rbbad", HwInit->UsosRbBad);
    p = UsosPutStr(p, end, "\r\n");
    p = UsosPutField(p, end, "elba", HwInit->UsosLastErrLba);
    p = UsosPutField(p, end, "etfd", HwInit->UsosLastErrTfd);
    p = UsosPutField(p, end, "ecmd", HwInit->UsosLastErrCmd);
    p = UsosPutField(p, end, "pi", HwInit->PortsImplemented);
    p = UsosPutField(p, end, "cap", HwInit->HbaCapabilities);
    p = UsosPutStr(p, end, "\r\n");
    if (HwInit->UsosStage & USOS_STAGE_BUGCHECK) {
        p = UsosPutField(p, end, "stop", HwInit->UsosBugCheck[0]);
        for (i = 1; i < 5; i++) p = UsosPutField(p, end, "p", HwInit->UsosBugCheck[i]);
        p = UsosPutStr(p, end, "\r\n");
    }
    /* Ports with a device only (an 8-port HBA does not fit one sector) */
    for (port = 0; port < MAX_SUPPORTED_PORTS; port++) {
        PUCHAR pb;
        ULONG ssts;
        if (!(HwInit->PortsImplemented & (1UL << port))) continue;
        pb = AHCI_PORT_BASE(HwInit->AbarMapped, port);
        ssts = AHCI_READ_REG(pb, AHCI_PORT_SSTS);
        if ((ssts & AHCI_SSTS_DET_MASK) == AHCI_SSTS_DET_NONE) continue;
        p = UsosPutField(p, end, "p", port);
        p = UsosPutField(p, end, "ssts", ssts);
        p = UsosPutField(p, end, "cmd", AHCI_READ_REG(pb, AHCI_PORT_CMD));
        p = UsosPutField(p, end, "tfd", AHCI_READ_REG(pb, AHCI_PORT_TFD));
        p = UsosPutField(p, end, "use", (ULONG)HwInit->Ports[port].Present | ((ULONG)HwInit->Ports[port].IsAtapi << 4));
        if (HwInit->Ports[port].IdentifyValid) {
            p = UsosPutStr(p, end, " ");
            for (i = 0; i < 20 && p + 2 <= end; i++) {     /* model, byte-swapped words */
                *p++ = (CHAR)HwInit->Ports[port].IdentifyData[54 + 2 * i + 1];
                *p++ = (CHAR)HwInit->Ports[port].IdentifyData[54 + 2 * i];
            }
        }
        p = UsosPutStr(p, end, "\r\n");
    }
    AhciUsosSector(HwInit, tp, USOS_GAP_TRACE_LBA + (HwInit->UsosBoot % USOS_GAP_TRACE_SLOTS), TRUE);
    HwInit->UsosInTrace = 0;
}

/* A stage seen for the first time: status line and trace. */
VOID
AhciUsosStage(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Stage, IN PCHAR Why)
{
    if (HwInit->UsosStage & Stage) return;
    HwInit->UsosStage |= Stage;
    AhciUsosShow(HwInit);
    AhciUsosTrace(HwInit, Why);
}

/* Bugcheck callback (HIGH_LEVEL): the STOP data on the status line and in
   the trace. Every other CPU is frozen; AHCINT polls, so the trace write
   needs no interrupt. */
static VOID __stdcall
AhciUsosBugCheckCallback(IN PVOID Buffer, IN ULONG Length)
{
    PHW_DEVICE_EXTENSION HwInit = (PHW_DEVICE_EXTENSION)Buffer;
    ULONG i;

    (VOID)Length;
    if (HwInit->UsosStage & USOS_STAGE_BUGCHECK) return;
    for (i = 0; i < 5; i++) HwInit->UsosBugCheck[i] = KiBugCheckData[i];
    HwInit->UsosStage |= USOS_STAGE_BUGCHECK;
    AhciUsosShow(HwInit);
    HwInit->UsosInTrace = 0;
    AhciUsosTrace(HwInit, "BUGCHECK");
}

/* FindAdapter found an HBA: number it, map the text buffer, register the
   bugcheck callback, show the line. */
VOID
AhciUsosAttach(IN PHW_DEVICE_EXTENSION HwInit)
{
    PHYSICAL_ADDRESS vga;

    HwInit->UsosInstance = g_UsosInstances++;
    vga.LowPart = 0xB8000;
    vga.HighPart = 0;
    if (HwInit->UsosVga == NULL) HwInit->UsosVga = (PUSHORT)MmMapIoSpace(vga, 80 * 50 * 2, 0 /* MmNonCached */);
    if (HwInit->UsosBugCheckRecord.CallbackRoutine == NULL) {
        KeRegisterBugCheckCallback(&HwInit->UsosBugCheckRecord, (PVOID)AhciUsosBugCheckCallback,
                                   HwInit, sizeof(HW_DEVICE_EXTENSION), g_UsosComponent);
    }
    AhciUsosShow(HwInit);
}

/* Fail loudly: the line in red, the trace, then STOP 0x55534F53. */
static VOID
AhciUsosFail(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Reason, IN ULONG Port, IN ULONG Detail, IN PCHAR Why)
{
    AhciUsosShow(HwInit);
    AhciUsosTrace(HwInit, Why);
    KeBugCheckEx(USOS_BUGCHECK_CODE, Reason, HwInit->UsosPciId, Port, Detail);
}

/* After a completed write on the USOS disk: count it, record stages and,
   for the first 256 writes and every 32nd after, read the first sector
   back and compare it with what was written. */
static VOID
AhciUsosAfterWrite(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb,
                   IN AHCI_LBA Lba, IN ULONG Count)
{
    PUCHAR buf, data;
    ULONG i, n;

    n = HwInit->UsosWrites;
    HwInit->UsosLastWriteLba = Lba.Low;
    if (n >= 1 && n <= 4) HwInit->UsosFirstWrites[n - 1] = Lba.Low;
    if (Lba.High == 0 && Lba.Low == 0) AhciUsosStage(HwInit, USOS_STAGE_LBA0, "write-lba0");
    if (Lba.High == 0 && Lba.Low <= 2048 && Lba.Low + Count > 2048) AhciUsosStage(HwInit, USOS_STAGE_LBA2048, "write-lba2048");
    if (HwInit->UsosTracePortPlus1 != Port + 1 || Srb == NULL || Srb->DataBuffer == NULL) return;
    if (n > 256 && (n & 0x1F) != 0) return;
    buf = HwInit->Ports[Port].BounceBuffer;
    data = (PUCHAR)Srb->DataBuffer;
    HwInit->UsosRbChecks++;
    if (AhciUsosSectorAt(HwInit, Port, Lba, FALSE) != AHCI_CMD_OK) return;     /* counted as an error */
    for (i = 0; i < 512; i++) {
        if (buf[i] != data[i]) {
            HwInit->UsosRbBad++;
            HwInit->UsosStage |= USOS_STAGE_RBFAIL;
            AhciUsosFail(HwInit, 3, Port, Lba.Low, "RB-FAIL");
            return;
        }
    }
}

/* Called for every ATA port after IDENTIFY. Only the first disk with the
   USOS marker is used; every other disk is only read at LBA 2046. */
VOID
AhciUsosProbe(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    PUCHAR buf = pi->BounceBuffer;
    ULONG i, boot, result, tries;
    UCHAR sig[8];

    if (!pi->Present || pi->IsAtapi || !pi->IdentifyValid || !pi->LbaSupported) return;
    if (HwInit->UsosTracePortPlus1 != 0) return;
    HwInit->UsosProbePortPlus1 = Port + 1;

    /* MODIFIED (USOS 1.3.0.0-usos3): retries, then fail loudly; usos2
       returned silently here and left nothing to see. */
    result = AHCI_CMD_HBA_ERROR;
    for (tries = 0; tries < 3; tries++) {
        result = AhciUsosSector(HwInit, Port, USOS_GAP_MARKER_LBA, FALSE);
        if (result == AHCI_CMD_OK) break;
        for (i = 0; i < 20; i++) ScsiPortStallExecution(10000);
    }
    if (result != AHCI_CMD_OK) {
        HwInit->UsosMarker = USOS_MARKER_READ_ERROR;
        AhciUsosFail(HwInit, 1, Port, pi->LastTfd, "MARKER-READ-FAIL");
        return;
    }
    HwInit->UsosMarkerHead = ((PULONG)buf)[0];
    for (i = 0; i < 12; i++) {
        if (buf[i] != UsosMagic[i]) {
            if (HwInit->UsosMarker == USOS_MARKER_NONE) HwInit->UsosMarker = USOS_MARKER_ABSENT;
            AhciUsosShow(HwInit);
            return;
        }
    }
    HwInit->UsosMarker = USOS_MARKER_OK;
    boot = ((PULONG)buf)[4] + 1;
    for (i = 0; i < 8; i++) sig[i] = buf[32 + i];

    /* Write/read-back test */
    for (i = 0; i < 512; i++) buf[i] = (UCHAR)(i ^ boot ^ 0x5A);
    ((PULONG)buf)[0] = 0x534F5355;     /* "USOS" */
    ((PULONG)buf)[1] = boot;
    HwInit->UsosVerify = 2;
    if (AhciUsosSector(HwInit, Port, USOS_GAP_TEST_LBA, TRUE) == AHCI_CMD_OK) {
        ZeroMemoryBytes(buf, 512);
        if (AhciUsosSector(HwInit, Port, USOS_GAP_TEST_LBA, FALSE) == AHCI_CMD_OK) {
            HwInit->UsosVerify = 1;
            if (((PULONG)buf)[0] != 0x534F5355 || ((PULONG)buf)[1] != boot) HwInit->UsosVerify = 2;
            for (i = 8; i < 512 && HwInit->UsosVerify == 1; i++)
                if (buf[i] != (UCHAR)(i ^ boot ^ 0x5A)) HwInit->UsosVerify = 2;
        }
    }

    /* Marker with the new boot counter */
    ZeroMemoryBytes(buf, 512);
    for (i = 0; i < 12; i++) buf[i] = UsosMagic[i];
    ((PULONG)buf)[4] = boot;
    ((PULONG)buf)[5] = HwInit->UsosVerify;
    for (i = 0; i < 8; i++) buf[32 + i] = sig[i];
    AhciUsosSector(HwInit, Port, USOS_GAP_MARKER_LBA, TRUE);

    HwInit->UsosBoot = boot;
    HwInit->UsosTracePortPlus1 = Port + 1;
    AhciUsosShow(HwInit);
    AhciUsosTrace(HwInit, (HwInit->UsosVerify == 1) ? "init" : "init-VERIFY-FAIL");

    /* Fail loudly: a disk that does not keep what it is given stops the
       machine with the numbers on screen (usos2 hid the port). */
    if (HwInit->UsosVerify != 1) AhciUsosFail(HwInit, 2, Port, pi->LastTfd, "VERIFY-FAIL");
}

static VOID
AhciAtaReadWrite(
    IN PHW_DEVICE_EXTENSION HwInit,
    IN ULONG Port,
    IN PSCSI_REQUEST_BLOCK Srb,
    IN AHCI_LBA Lba,
    IN ULONG Count,
    IN BOOLEAN IsWrite
)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    ATA_REQUEST req;
    ULONG result;
    UCHAR key, asc, ascq;

    /* A zero transfer length in READ/WRITE(10)/(16) moves nothing; ATA
       would read 0 as 256/65536 sectors, so never send it. */
    if (Count == 0) {
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        return;
    }

    if (!pi->LbaSupported || !AhciLbaRangeValid(pi, Lba, Count)) {
        AHCI_DBG((AHCI_PFX "Port %lu: LBA %08lX:%08lX +%lu out of range\n", Port, Lba.High, Lba.Low, Count));
        AhciFailWithSense(HwInit, Port, Srb, SCSI_SENSE_ILLEGAL_REQUEST, AHCI_ASC_LBA_OUT_OF_RANGE, 0);
        return;
    }

    if (Count > (Srb->DataTransferLength / AHCI_SECTOR_SIZE)) {
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        return;
    }

    ZeroMemoryBytes(&req, sizeof(req));
    req.DataBuffer = Srb->DataBuffer;
    req.DataBufferLen = Count * AHCI_SECTOR_SIZE;
    req.IsWrite = IsWrite;
    req.Lba = Lba;
    req.SectorCount = Count;

    /* 28-bit when possible, EXT only on LBA48 devices when needed */
    if (AhciLbaFits28(Lba, Count)) {
        req.Is48Bit = FALSE;
        req.Command = IsWrite ? IDE_COMMAND_WRITE_DMA : IDE_COMMAND_READ_DMA;
    } else if (pi->Lba48 && Count <= ATA_LBA48_MAX_SECTORS) {
        req.Is48Bit = TRUE;
        req.Command = IsWrite ? IDE_COMMAND_WRITE_DMA_EXT : IDE_COMMAND_READ_DMA_EXT;
    } else {
        /* Cannot happen for a valid range on a 28-bit-only device (its
           capacity is < 2^28) unless the count is out of bounds. */
        AhciFailWithSense(HwInit, Port, Srb, SCSI_SENSE_ILLEGAL_REQUEST, AHCI_ASC_INVALID_CDB_FIELD, 0);
        return;
    }

    result = AhciRunCommand(HwInit, Port, Srb, &req);

    /* MODIFIED (USOS 1.3.0.0-usos1): FUA (WRITE(10)/(16) byte 1 bit 3) is
       honoured with a FLUSH CACHE after the write. */
    if (result == AHCI_CMD_OK && IsWrite && Srb->CdbLength >= 10 && (Srb->Cdb[1] & 0x08) &&
        !AhciFlushPort(HwInit, Port)) {
        result = AHCI_CMD_DEVICE_ERROR;
    }

    /* MODIFIED (USOS 1.3.0.0-usos3): stages and sampled read-back */
    if (result == AHCI_CMD_OK && IsWrite) AhciUsosAfterWrite(HwInit, Port, Srb, Lba, Count);

    /* MODIFIED (USOS 1.3.0.0-usos2): a trace every 2048 writes (text-mode
       Setup sends neither flush nor shutdown before its restart) */
    if (result == AHCI_CMD_OK && IsWrite && (HwInit->UsosWrites & 0x7FF) == 0) AhciUsosTrace(HwInit, "periodic");

    switch (result) {
    case AHCI_CMD_OK:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        break;
    case AHCI_CMD_BAD_BUFFER:
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        break;
    default:
        AhciAtaErrorToSense(pi->LastTfd, &key, &asc, &ascq);
        AhciFailWithSense(HwInit, Port, Srb, key, asc, ascq);
        break;
    }
}

static VOID
AhciProcessAtaSrb(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR cdb = Srb->Cdb;
    AHCI_LBA lba;
    ULONG count;

    switch (cdb[0]) {
    case SCSIOP_INQUIRY:
        AhciHandleInquiry(HwInit, Port, Srb);
        return;

    case SCSIOP_REQUEST_SENSE:
        AhciHandleRequestSenseAta(HwInit, Port, Srb);
        return;

    case SCSIOP_SYNCHRONIZE_CACHE:
    case AHCI_SCSIOP_SYNC_CACHE16:
        /* MODIFIED (USOS 1.3.0.0-usos1): a real FLUSH CACHE (EXT) */
        if (AhciFlushPort(HwInit, Port)) {
            Srb->SrbStatus = SRB_STATUS_SUCCESS;
            Srb->ScsiStatus = SCSISTAT_GOOD;
        } else {
            AhciFailWithSense(HwInit, Port, Srb, SCSI_SENSE_HARDWARE_ERROR, 0x44, 0);
        }
        return;

    case SCSIOP_TEST_UNIT_READY:
    case SCSIOP_MEDIUM_REMOVAL:
    case SCSIOP_VERIFY:
    case AHCI_SCSIOP_VERIFY16:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        return;

    case SCSIOP_READ_CAPACITY:
        AhciHandleReadCapacity10(HwInit, Port, Srb);
        return;

    case AHCI_SCSIOP_SERVICE_ACTION_IN16:
        if ((cdb[1] & 0x1F) == AHCI_SA_READ_CAPACITY16) {
            AhciHandleReadCapacity16(HwInit, Port, Srb);
            return;
        }
        break;

    case SCSIOP_MODE_SENSE:
    case SCSIOP_MODE_SENSE10:
        AhciHandleModeSenseAta(HwInit, Port, Srb);
        return;

    case SCSIOP_READ6:
    case SCSIOP_WRITE6:
        lba.High = 0;
        lba.Low = ((ULONG)(cdb[1] & 0x1F) << 16) | ((ULONG)cdb[2] << 8) | cdb[3];
        count = cdb[4] ? cdb[4] : 256;
        AhciAtaReadWrite(HwInit, Port, Srb, lba, count, (BOOLEAN)(cdb[0] == SCSIOP_WRITE6));
        return;

    case SCSIOP_READ:
    case SCSIOP_WRITE:
        lba = AhciLbaFromBigEndian(&cdb[2], 4);
        count = ((ULONG)cdb[7] << 8) | cdb[8];
        AhciAtaReadWrite(HwInit, Port, Srb, lba, count, (BOOLEAN)(cdb[0] == SCSIOP_WRITE));
        return;

    case AHCI_SCSIOP_READ16:
    case AHCI_SCSIOP_WRITE16:
        lba = AhciLbaFromBigEndian(&cdb[2], 8);
        count = AhciBigEndian32(&cdb[10]);
        AhciAtaReadWrite(HwInit, Port, Srb, lba, count, (BOOLEAN)(cdb[0] == AHCI_SCSIOP_WRITE16));
        return;
    }

    Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
}

/* ------------------------------------------------------------------ */
/* ATAPI                                                               */
/* ------------------------------------------------------------------ */

/* REQUEST SENSE sent to the drive; returns the sense length obtained
   (0 on failure). Data is left in the port's bounce buffer. */
static ULONG
AhciAtapiFetchSense(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN ULONG AllocLen)
{
    UCHAR cdb[12];

    if (AllocLen == 0 || AllocLen > 252) AllocLen = sizeof(SENSE_DATA);
    AllocLen = (AllocLen + 1) & ~1UL;           /* PRD byte counts are even */

    ZeroMemoryBytes(cdb, sizeof(cdb));
    cdb[0] = SCSIOP_REQUEST_SENSE;
    cdb[4] = (UCHAR)AllocLen;

    if (AhciAtapiBounceCommand(HwInit, Port, cdb, AllocLen) != AHCI_CMD_OK) return 0;
    return AllocLen;
}

static VOID
AhciAtapiFailed(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    Srb->SrbStatus = SRB_STATUS_ERROR;
    Srb->ScsiStatus = SCSISTAT_CHECK_CONDITION;

#if AHCI_AUTOSENSE
    if (AhciAutoSenseWanted(Srb)) {
        ULONG tfd = HwInit->Ports[Port].LastTfd;
        ULONG n;

        /* Real auto-sense: ask the drive, like a SCSI HBA would */
        n = AhciAtapiFetchSense(HwInit, Port, sizeof(SENSE_DATA));
        if (n != 0) {
            AhciSetAutoSense(Srb, HwInit->Ports[Port].BounceBuffer, n);
        } else if (tfd & TFD_STS_ERR) {
            /* Drive would not answer: at least pass on its sense key */
            SENSE_DATA sense;
            AhciBuildSense(&sense, (UCHAR)ATAPI_ERROR_SENSE_KEY(tfd >> TFD_ERR_SHIFT), 0, 0);
            AhciSetAutoSense(Srb, &sense, sizeof(sense));
        }
    }
#else
    (VOID)HwInit;
    (VOID)Port;
#endif
}

static VOID
AhciAtapiRequestSense(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PAHCI_PORT_INFO pi = &HwInit->Ports[Port];
    ULONG allocLen = Srb->Cdb[4];
    ULONG n;
    SENSE_DATA empty;

    /* Sense the driver itself produced (e.g. unsupported VPD page) */
    if (pi->SensePending) {
        AhciBuildSense(&empty, pi->SenseKey, pi->SenseAsc, pi->SenseAscq);
        pi->SensePending = FALSE;
        AhciCopyToSrb(Srb, &empty, sizeof(empty));
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        return;
    }

    if (allocLen > Srb->DataTransferLength) allocLen = Srb->DataTransferLength;

    n = AhciAtapiFetchSense(HwInit, Port, allocLen);
    if (n != 0) {
        AhciCopyToSrb(Srb, HwInit->Ports[Port].BounceBuffer, n);
    } else {
        /* The drive gave us nothing: an empty NO SENSE is the honest answer */
        AhciBuildSense(&empty, SCSI_SENSE_NO_SENSE, 0, 0);
        AhciCopyToSrb(Srb, &empty, sizeof(empty));
    }
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

/* ATAPI has no MODE SENSE(6): send (10), convert the header like atapi.sys */
static VOID
AhciAtapiModeSense6(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR bounce = HwInit->Ports[Port].BounceBuffer;
    UCHAR cdb[12];
    UCHAR hdr6[4];
    ULONG xferLen, i;

    ZeroMemoryBytes(cdb, sizeof(cdb));
    cdb[0] = SCSIOP_MODE_SENSE10;
    cdb[2] = (UCHAR)(Srb->Cdb[2] & 0x3F);       /* page code */
    cdb[7] = 0;                                 /* ParameterListLengthMsb */
    cdb[8] = Srb->Cdb[4];                       /* SCSI-6 allocation length */

    /* Same data length as the SRB, through the bounce buffer */
    xferLen = Srb->DataTransferLength;
    if (xferLen > AHCI_BOUNCE_SIZE) xferLen = AHCI_BOUNCE_SIZE;
    xferLen = (xferLen + 1) & ~1UL;             /* PRD byte counts are even */

    if (AhciAtapiBounceCommand(HwInit, Port, cdb, xferLen) != AHCI_CMD_OK) {
        AhciAtapiFailed(HwInit, Port, Srb);
        return;
    }

    if (Srb->DataTransferLength >= sizeof(MODE_PARAMETER_HEADER_10)) {
        ULONG payload = Srb->DataTransferLength - sizeof(MODE_PARAMETER_HEADER_10);
        if (payload > AHCI_BOUNCE_SIZE - sizeof(MODE_PARAMETER_HEADER_10)) {
            payload = AHCI_BOUNCE_SIZE - sizeof(MODE_PARAMETER_HEADER_10);
        }

        hdr6[0] = bounce[1];                    /* ModeDataLengthLsb */
        hdr6[1] = bounce[2];                    /* MediumType */
        hdr6[2] = 0;                            /* DeviceSpecificParameter */
        hdr6[3] = 0;                            /* BlockDescriptorLength */
        for (i = 0; i < payload; i++) bounce[4 + i] = bounce[8 + i];
        for (i = 0; i < 4; i++) bounce[i] = hdr6[i];
    }

    AhciCopyToSrb(Srb, bounce, Srb->DataTransferLength);
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
    Srb->ScsiStatus = SCSISTAT_GOOD;
}

static VOID
AhciProcessAtapiSrb(IN PHW_DEVICE_EXTENSION HwInit, IN ULONG Port, IN PSCSI_REQUEST_BLOCK Srb)
{
    ATA_REQUEST req;
    ULONG result;

    switch (Srb->Cdb[0]) {
    case SCSIOP_INQUIRY:
        AhciHandleInquiry(HwInit, Port, Srb);
        return;

    case SCSIOP_REQUEST_SENSE:
        AhciAtapiRequestSense(HwInit, Port, Srb);
        return;

    case SCSIOP_SYNCHRONIZE_CACHE:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
        return;

    case SCSIOP_MODE_SENSE:
        AhciAtapiModeSense6(HwInit, Port, Srb);
        return;
    }

    /* Everything else (TEST UNIT READY, READ(10/12), READ TOC, MODE
       SENSE(10), START STOP UNIT, ...) is a native ATAPI packet. */
    ZeroMemoryBytes(&req, sizeof(req));
    req.IsAtapi = TRUE;
    req.DataBuffer = Srb->DataBuffer;
    req.DataBufferLen = (Srb->DataBuffer != NULL) ? Srb->DataTransferLength : 0;
    req.IsWrite = (BOOLEAN)((Srb->SrbFlags & SRB_FLAGS_DATA_OUT) != 0);
    req.Cdb = Srb->Cdb;
    req.CdbLength = Srb->CdbLength;

    result = AhciRunCommand(HwInit, Port, Srb, &req);
    if (result == AHCI_CMD_OK) {
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->ScsiStatus = SCSISTAT_GOOD;
    } else if (result == AHCI_CMD_BAD_BUFFER) {
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
    } else {
        AhciAtapiFailed(HwInit, Port, Srb);
    }
}

/* ------------------------------------------------------------------ */
/* Entry                                                               */
/* ------------------------------------------------------------------ */

VOID
AhciSatlProcessSrb(IN PHW_DEVICE_EXTENSION HwInit, IN PSCSI_REQUEST_BLOCK Srb)
{
    ULONG port = Srb->TargetId;

    if (Srb->PathId != 0 || port >= MAX_SUPPORTED_PORTS || !HwInit->Ports[port].Present) {
        Srb->SrbStatus = SRB_STATUS_SELECTION_TIMEOUT;
        return;
    }
    if (Srb->Lun != 0) {
        Srb->SrbStatus = SRB_STATUS_NO_DEVICE;
        return;
    }

    /* Sense belongs to the command that failed: any other command
       discards it, so a later REQUEST SENSE never reports a stale error. */
    if (Srb->Cdb[0] != SCSIOP_REQUEST_SENSE) {
        HwInit->Ports[port].SensePending = FALSE;
    }

    if (HwInit->Ports[port].IsAtapi) {
        AhciProcessAtapiSrb(HwInit, port, Srb);
    } else {
        AhciProcessAtaSrb(HwInit, port, Srb);
    }
}
