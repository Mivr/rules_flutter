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
const int lcSymtab = 0x02;
const int lcDysymtab = 0x0b;
const int lcIdDylib = 0x0d;
const int lcSegment64 = 0x19;
const int lcUuid = 0x1b;
const int lcRpath = 0x1c | lcReqDyld; // 0x8000001c
const int lcCodeSignature = 0x1d;
const int lcDyldInfo = 0x22;
const int lcDyldInfoOnly = 0x22 | lcReqDyld; // 0x80000022
const int lcVersionMinMacosx = 0x24;
const int lcVersionMinIphoneos = 0x25;
const int lcFunctionStarts = 0x26;
const int lcDataInCode = 0x29;
const int lcVersionMinTvos = 0x2f;
const int lcVersionMinWatchos = 0x30;
const int lcBuildVersion = 0x32;
const int lcDyldExportsTrie = 0x33 | lcReqDyld;
const int lcDyldChainedFixups = 0x34 | lcReqDyld;

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
const int csHashTypeSha256 = 2;
