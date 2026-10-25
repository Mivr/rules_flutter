/// Mach-O, Fat-binary and code-signature constants.
///
/// Magic numbers, CPU types and subtypes, Mach-O header flags, load-command
/// identifiers, `LC_BUILD_VERSION` platforms and big-endian code-signature
/// magic values shared by the Mach-O tools.

// Mach-O 32-bit, 64-bit, and Universal (Fat) constants.
const int mhMagic32 = 0xfeedface;
const int mhCigam32 = 0xcefaedfe;
const int mhMagic64 = 0xfeedfacf;
const int mhCigam64 = 0xcffaedfe;
const int fatMagic = 0xcafebabe;
const int fatCigam = 0xbebafeca;
const int fatMagic64 = 0xcafebabf;
const int fatCigam64 = 0xbfbafeca;
const int mhHeaderSize64 = 32;

const int cpuArchAbi64 = 0x01000000;
const int cpuTypeI386 = 0x00000007;
const int cpuTypeX86_64 = cpuTypeI386 | cpuArchAbi64; // 0x01000007
const int cpuSubtypeX86_64All = 3;
const int cpuTypeArm = 0x0000000c;
const int cpuTypeArm64 = cpuTypeArm | cpuArchAbi64; // 0x0100000c
const int cpuSubtypeArm64All = 0;

const int mhExecute = 0x2;
const int mhDylib = 0x6;
const int mhNoundefs = 0x00000001;
const int mhDyldlink = 0x00000004;
const int mhTwolevel = 0x00000080;
const int mhNoReexportedDylibs = 0x00100000;
const int mhPie = 0x00200000;

// Load command constants.
const int lcReqDyld = 0x80000000;
const int lcSegment = 0x01;
const int lcSymtab = 0x02;
const int lcSymseg = 0x03;
const int lcThread = 0x04;
const int lcUnixthread = 0x05;
const int lcLoadFvmlib = 0x06;
const int lcIdFvmlib = 0x07;
const int lcIdent = 0x08;
const int lcFvmfile = 0x09;
const int lcPrepage = 0x0a;
const int lcDysymtab = 0x0b;
const int lcLoadDylib = 0x0c;
const int lcIdDylib = 0x0d;
const int lcLoadDylinker = 0x0e;
const int lcIdDylinker = 0x0f;
const int lcPreboundDylib = 0x10;
const int lcRoutines = 0x11;
const int lcSubFramework = 0x12;
const int lcSubUmbrella = 0x13;
const int lcSubClient = 0x14;
const int lcSubLibrary = 0x15;
const int lcTwolevelHints = 0x16;
const int lcPrebindCksum = 0x17;
const int lcLoadWeakDylib = 0x18 | lcReqDyld; // 0x80000018
const int lcSegment64 = 0x19;
const int lcRoutines64 = 0x1a;
const int lcUuid = 0x1b;
const int lcRpath = 0x1c | lcReqDyld; // 0x8000001c
const int lcReexportDylib = 0x1f | lcReqDyld; // 0x8000001f
const int lcEncryptionInfo = 0x21;
const int lcCodeSignature = 0x1d;
const int lcSegmentSplitInfo = 0x1e;
const int lcDyldInfo = 0x22;
const int lcDyldInfoOnly = 0x22 | lcReqDyld; // 0x80000022
const int lcLoadUpwardDylib = 0x23 | lcReqDyld; // 0x80000023
const int lcSourceVersion = 0x2a;
const int lcDylibCodeSignDrs = 0x2b;
const int lcEncryptionInfo64 = 0x2c;
const int lcLinkerInput = 0x2d;
const int lcLinkerOptimizationHint = 0x2e;
const int lcVersionMinMacosx = 0x24;
const int lcVersionMinIphoneos = 0x25;
const int lcFunctionStarts = 0x26;
const int lcDyldEnvironment = 0x27 | lcReqDyld; // 0x80000027
const int lcMain = 0x28 | lcReqDyld; // 0x80000028
const int lcDataInCode = 0x29;
const int lcVersionMinTvos = 0x2f;
const int lcVersionMinWatchos = 0x30;
const int lcNote = 0x31;
const int lcBuildVersion = 0x32;
const int lcDyldExportsTrie = 0x33 | lcReqDyld;
const int lcDyldChainedFixups = 0x34 | lcReqDyld;
const int lcFilesetEntry = 0x35 | lcReqDyld; // 0x80000035

// `section_64` type mask and the zero-fill type: zero-fill sections occupy no
// file bytes, so the strip's range accounting skips them.
const int sectionTypeMask = 0xff;
const int sectionTypeZerofill = 0x01;

// Platform constants for LC_BUILD_VERSION.
const int platformMacos = 1;
const int platformIos = 2;
const int platformIosSimulator = 7;

// `nlist_64` symbol-table constants.
const int nStabMask = 0xe0;
const int nExtBit = 0x01;
const int nTypeMask = 0x0e;
const int nTypeUndef = 0x00;

// Indirect-symbol-table special entries.
const int indirectSymbolAbs = 0x40000000;
const int indirectSymbolLocal = 0x80000000;
const int indirectSymbolSpecialMask = 0xc0000000;

// Code signature constants (big-endian in Mach-O).
const int csMagicEmbeddedSignature = 0xfade0cc0;
const int csMagicCodeDirectory = 0xfade0c02;
const int csMagicBlobWrapper = 0xfade0b01;
const int csHashTypeSha256 = 2;

// SuperBlob index types: slot 0 names the primary CodeDirectory, 0x1000 range
// the alternates, and 0x10000 the CMS signature wrapper.
const int csSlotCodeDirectory = 0;
const int csSlotSignature = 0x10000;
