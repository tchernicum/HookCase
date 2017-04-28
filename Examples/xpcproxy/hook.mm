// The MIT License (MIT)
//
// Copyright (c) 2017 Steven Michaud
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// Template for a hook library that can be used to hook C/C++ methods and/or
// swizzle Objective-C methods for debugging/reverse-engineering.
//
// A number of methods are provided to be called from your hooks, including
// ones that make use of Apple's CoreSymbolication framework (which though
// undocumented is heavily used by Apple utilities such as atos, ReportCrash,
// crashreporterd and dtrace).  Particularly useful are LogWithFormat() and
// PrintStackTrace().
//
// Once the hook library is built, use it as follows:
//
// A) From a Terminal prompt:
//    1) HC_INSERT_LIBRARY=/full/path/to/hook.dylib /path/to/application
//
// B) From gdb:
//    1) set HC_INSERT_LIBRARY /full/path/to/hook.dylib
//    2) run
// 
// C) From lldb:
//    1) env HC_INSERT_LIBRARY=/full/path/to/hook.dylib
//    2) run

#include <asl.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <libproc.h>
#include <stdarg.h>
#include <time.h>
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <objc/Object.h>
extern "C" {
#include <mach-o/getsect.h>
}
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <mach-o/nlist.h>
#include <mach/vm_map.h>
#include <libgen.h>
#include <execinfo.h>

#include <spawn.h>
#include <xpc/xpc.h>
#include <sys/sysctl.h>

pthread_t gMainThreadID = 0;

bool IsMainThread()
{
  return (!gMainThreadID || (gMainThreadID == pthread_self()));
}

void CreateGlobalSymbolicator();

bool sGlobalInitDone = false;

void basic_init()
{
  if (!sGlobalInitDone) {
    gMainThreadID = pthread_self();
    CreateGlobalSymbolicator();
    sGlobalInitDone = true;
  }
}

// Hooked methods are sometimes called before the CoreFoundation framework is
// initialized.  Once libobjc.dylib is initialized, we can hurry the process
// along by calling __CFInitialize() ourselves.  But before then, trying to
// use CF methods (even after __CFInitialize()) leads to mysterious crashes.

extern "C" void __CFInitialize();

bool sObjcInited = false;

void (*_objc_init_caller)() = NULL;

// 64-bit only on OS X 10.11 (ElCapitan) and below, but for both 64-bit and
// 32-bit code on OS X 10.12 (Sierra) and up.
static void Hooked__objc_init()
{
  _objc_init_caller();
  sObjcInited = true;
}

void (*_ZL10_objc_initv_caller)() = NULL;

// 32-bit only on OS X 10.11 (ElCapitan) and below.
static void Hooked__ZL10_objc_initv()
{
  _ZL10_objc_initv_caller();
  sObjcInited = true;
}

bool CanUseCF()
{
  if (!sObjcInited) {
    return false;
  }
  basic_init();
  __CFInitialize();
  return true;
}

#define MAC_OS_X_VERSION_10_9_HEX  0x00000A90
#define MAC_OS_X_VERSION_10_10_HEX 0x00000AA0
#define MAC_OS_X_VERSION_10_11_HEX 0x00000AB0
#define MAC_OS_X_VERSION_10_12_HEX 0x00000AC0

char gOSVersionString[PATH_MAX] = {0};

int32_t OSX_Version()
{
  if (!CanUseCF()) {
    return 0;
  }

  static int32_t version = -1;
  if (version != -1) {
    return version;
  }

  CFURLRef url =
    CFURLCreateWithString(kCFAllocatorDefault,
                          CFSTR("file:///System/Library/CoreServices/SystemVersion.plist"),
                          NULL);
  CFReadStreamRef stream =
    CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
  CFReadStreamOpen(stream);
  CFDictionaryRef sysVersionPlist = (CFDictionaryRef)
    CFPropertyListCreateWithStream(kCFAllocatorDefault,
                                   stream, 0, kCFPropertyListImmutable,
                                   NULL, NULL);
  CFReadStreamClose(stream);
  CFRelease(stream);
  CFRelease(url);

  CFStringRef versionString = (CFStringRef)
    CFDictionaryGetValue(sysVersionPlist, CFSTR("ProductVersion"));
  CFStringGetCString(versionString, gOSVersionString,
                     sizeof(gOSVersionString), kCFStringEncodingUTF8);

  CFArrayRef versions =
    CFStringCreateArrayBySeparatingStrings(kCFAllocatorDefault,
                                           versionString, CFSTR("."));
  CFIndex count = CFArrayGetCount(versions);
  version = 0;
  for (int i = 0; i < count; ++i) {
    CFStringRef component = (CFStringRef) CFArrayGetValueAtIndex(versions, i);
    int value = CFStringGetIntValue(component);
    version += (value << ((2 - i) * 4));
  }
  CFRelease(sysVersionPlist);
  CFRelease(versions);

  return version;
}

bool OSX_Mavericks()
{
  return ((OSX_Version() & 0xFFF0) == MAC_OS_X_VERSION_10_9_HEX);
}

bool OSX_Yosemite()
{
  return ((OSX_Version() & 0xFFF0) == MAC_OS_X_VERSION_10_10_HEX);
}

bool OSX_ElCapitan()
{
  return ((OSX_Version() & 0xFFF0) == MAC_OS_X_VERSION_10_11_HEX);
}

bool macOS_Sierra()
{
  return ((OSX_Version() & 0xFFF0) == MAC_OS_X_VERSION_10_12_HEX);
}

class nsAutoreleasePool {
public:
    nsAutoreleasePool()
    {
        mLocalPool = [[NSAutoreleasePool alloc] init];
    }
    ~nsAutoreleasePool()
    {
        [mLocalPool release];
    }
private:
    NSAutoreleasePool *mLocalPool;
};

typedef struct _CSTypeRef {
  unsigned long type;
  void *contents;
} CSTypeRef;

static CSTypeRef initializer = {0};

void CreateGlobalSymbolicator();
const char *GetOwnerName(void *address, CSTypeRef owner = initializer);
const char *GetAddressString(void *address, CSTypeRef owner = initializer);
void PrintAddress(void *address, CSTypeRef symbolicator = initializer);
void PrintStackTrace();
BOOL SwizzleMethods(Class aClass, SEL orgMethod, SEL posedMethod, BOOL classMethods);

char gProcPath[PROC_PIDPATHINFO_MAXSIZE] = {0};

static void MaybeGetProcPath()
{
  if (gProcPath[0]) {
    return;
  }
  proc_pidpath(getpid(), gProcPath, sizeof(gProcPath) - 1);
}

static void GetThreadName(char *name, size_t size)
{
  pthread_getname_np(pthread_self(), name, size);
}

static void LogWithFormatV(bool decorate, CFStringRef format, va_list args)
{
  MaybeGetProcPath();

  CFStringRef message = CFStringCreateWithFormatAndArguments(kCFAllocatorDefault, NULL,
                                                             format, args);

  int msgLength = CFStringGetMaximumSizeForEncoding(CFStringGetLength(message),
                                                    kCFStringEncodingUTF8);
  char *msgUTF8 = (char *) calloc(msgLength + 1, 1);
  CFStringGetCString(message, msgUTF8, msgLength, kCFStringEncodingUTF8);
  CFRelease(message);

  char *finished = (char *) calloc(msgLength + 1024, 1);
  const time_t currentTime = time(NULL);
  char timestamp[30] = {0};
  ctime_r(&currentTime, timestamp);
  timestamp[strlen(timestamp) - 1] = 0;
  if (decorate) {
    char threadName[PROC_PIDPATHINFO_MAXSIZE] = {0};
    GetThreadName(threadName, sizeof(threadName) - 1);
    sprintf(finished, "(%s) %s[%u] %s[%p] %s\n",
            timestamp, gProcPath, getpid(), threadName, pthread_self(), msgUTF8);
  } else {
    sprintf(finished, "%s\n", msgUTF8);
  }
  free(msgUTF8);

  char stdout_path[PATH_MAX] = {0};
  fcntl(STDOUT_FILENO, F_GETPATH, stdout_path);

  if (!strcmp("/dev/console", stdout_path) ||
      !strcmp("/dev/null", stdout_path))
  {
    aslclient asl = asl_open(NULL, "com.apple.console", ASL_OPT_NO_REMOTE);
    aslmsg msg = asl_new(ASL_TYPE_MSG);
    asl_set(msg, ASL_KEY_LEVEL, "4"); // kCFLogLevelWarning, used by NSLog()
    asl_set(msg, ASL_KEY_MSG, finished);
    asl_send(asl, msg);
    asl_free(msg);
    asl_close(asl);
  } else {
    fputs(finished, stdout);
  }

#ifdef DEBUG_STDOUT
  struct stat stdout_stat;
  fstat(STDOUT_FILENO, &stdout_stat);
  char *stdout_info = (char *) calloc(4096, 1);
  sprintf(stdout_info, "stdout: pid \'%i\', path \"%s\", st_dev \'%i\', st_mode \'0x%x\', st_nlink \'%i\', st_ino \'%lli\', st_uid \'%i\', st_gid \'%i\', st_rdev \'%i\', st_size \'%lli\', st_blocks \'%lli\', st_blksize \'%i\', st_flags \'0x%x\', st_gen \'%i\'\n",
          getpid(), stdout_path, stdout_stat.st_dev, stdout_stat.st_mode, stdout_stat.st_nlink,
          stdout_stat.st_ino, stdout_stat.st_uid, stdout_stat.st_gid, stdout_stat.st_rdev,
          stdout_stat.st_size, stdout_stat.st_blocks, stdout_stat.st_blksize,
          stdout_stat.st_flags, stdout_stat.st_gen);

  aslclient asl = asl_open(NULL, "com.apple.console", ASL_OPT_NO_REMOTE);
  aslmsg msg = asl_new(ASL_TYPE_MSG);
  asl_set(msg, ASL_KEY_LEVEL, "4"); // kCFLogLevelWarning, used by NSLog()
  asl_set(msg, ASL_KEY_MSG, stdout_info);
  asl_send(asl, msg);
  asl_free(msg);
  asl_close(asl);
  free(stdout_info);
#endif

  free(finished);
}

// A (shared) copy of dyld is loaded into every Mach executable, and code in
// it (starting from _dyld_start) initializes the executable before jumping
// to main().  Because the code in dyld needs to be able to run before any
// other modules have been linked in, it's entirely self-contained -- it has
// no external dependencies.  So methods in it can be used from any hook, no
// matter how early it runs.  Here we're interested in the
// internal dyld::vlog(char const*, __va_list_tag*) method, which we can use
// for logging before the CoreFoundation framework has finished
// initialization.  The output from dyld::vlog() goes to stderr if it's
// available, and otherwise to the system log.

extern "C" void *module_dlsym(const char *module_name, const char *symbol);

void (*dyld_vlog_caller)(const char *format, va_list list) = NULL;

static void dyld_vlog(const char *format, va_list list)
{
  if (!dyld_vlog_caller) {
    dyld_vlog_caller = (void (*)(const char*, va_list))
      module_dlsym("dyld", "__ZN4dyld4vlogEPKcP13__va_list_tag");
    if (!dyld_vlog_caller) {
      return;
    }
  }
  size_t len = strlen(format) + 2;
  char *holder = (char *) calloc(len, 1);
  if (!holder) {
    return;
  }
  snprintf(holder, len, "%s\n", format);
  dyld_vlog_caller(holder, list);
  free(holder);
}

static void LogWithFormat(bool decorate, const char *format, ...)
{
  va_list args;
  va_start(args, format);
  if (CanUseCF()) {
    CFStringRef formatCFSTR = CFStringCreateWithCString(kCFAllocatorDefault, format,
                                                        kCFStringEncodingUTF8);
    LogWithFormatV(decorate, formatCFSTR, args);
    CFRelease(formatCFSTR);
  } else {
    dyld_vlog(format, args);
  }
  va_end(args);
}

extern "C" void hooklib_LogWithFormatV(bool decorate, const char *format, va_list args)
{
  if (CanUseCF()) {
    CFStringRef formatCFSTR = CFStringCreateWithCString(kCFAllocatorDefault, format,
                                                        kCFStringEncodingUTF8);
    LogWithFormatV(decorate, formatCFSTR, args);
    CFRelease(formatCFSTR);
  } else {
    dyld_vlog(format, args);
  }
}

extern "C" void hooklib_PrintStackTrace()
{
  PrintStackTrace();
}

extern "C" const struct dyld_all_image_infos *_dyld_get_all_image_infos();

// Bit in mach_header.flags that indicates whether or not the (dylib) module
// is in the shared cache.
#define MH_SHAREDCACHE 0x80000000

// Helper method for GetModuleHeaderAndSlide() below.
static
#ifdef __LP64__
uintptr_t GetImageSlide(const struct mach_header_64 *mh)
#else
uintptr_t GetImageSlide(const struct mach_header *mh)
#endif
{
  if (!mh) {
    return 0;
  }

  uintptr_t retval = 0;

  if ((mh->flags & MH_SHAREDCACHE) != 0) {
    const struct dyld_all_image_infos *info = _dyld_get_all_image_infos();
    if (info) {
      retval = info->sharedCacheSlide;
    }
    return retval;
  }

  uint32_t numCommands = mh->ncmds;

#ifdef __LP64__
  const struct segment_command_64 *aCommand = (struct segment_command_64 *)
    ((uintptr_t)mh + sizeof(struct mach_header_64));
#else
  const struct segment_command *aCommand = (struct segment_command *)
    ((uintptr_t)mh + sizeof(struct mach_header));
#endif

  for (uint32_t i = 0; i < numCommands; ++i) {
#ifdef __LP64__
    if (aCommand->cmd != LC_SEGMENT_64)
#else
    if (aCommand->cmd != LC_SEGMENT)
#endif
    {
      break;
    }

    if (!aCommand->fileoff && aCommand->filesize) {
      retval = (uintptr_t) mh - aCommand->vmaddr;
      break;
    }

    aCommand =
#ifdef __LP64__
      (struct segment_command_64 *)
#else
      (struct segment_command *)
#endif
      ((uintptr_t)aCommand + aCommand->cmdsize);
  }

  return retval;
}

// Helper method for module_dysym() below.
static
void GetModuleHeaderAndSlide(const char *moduleName,
#ifdef __LP64__
                             const struct mach_header_64 **pMh,
#else
                             const struct mach_header **pMh,
#endif
                             intptr_t *pVmaddrSlide)
{
  if (pMh) {
    *pMh = NULL;
  }
  if (pVmaddrSlide) {
    *pVmaddrSlide = 0;
  }
  if (!moduleName) {
    return;
  }

  char basename_local[PATH_MAX];
  strncpy(basename_local, basename((char *)moduleName),
          sizeof(basename_local));

  // If moduleName's base name is "dyld", we take it to mean the copy of dyld
  // that's present in every Mach executable.
  if (strcmp(basename_local, "dyld") == 0) {
    const struct dyld_all_image_infos *info = _dyld_get_all_image_infos();
    if (!info || !info->dyldImageLoadAddress) {
      return;
    }
    if (pMh) {
      *pMh =
#ifdef __LP64__
      (const struct mach_header_64 *)
#endif
      info->dyldImageLoadAddress;
    }
    if (pVmaddrSlide) {
      *pVmaddrSlide = GetImageSlide(
#ifdef __LP64__
        (const struct mach_header_64 *)
#endif
        info->dyldImageLoadAddress);
    }
    return;
  }

  bool moduleNameIsBasename = (strcmp(basename_local, moduleName) == 0);
  char moduleName_local[PATH_MAX] = {0};
  if (moduleNameIsBasename) {
    strncpy(moduleName_local, moduleName, sizeof(moduleName_local));
  } else {
    // Get the canonical path for moduleName (which may be a symlink or
    // otherwise non-canonical).
    int fd = open(moduleName, O_RDONLY);
    if (fd > 0) {
      if (fcntl(fd, F_GETPATH, moduleName_local) == -1) {
        strncpy(moduleName_local, moduleName, sizeof(moduleName_local));
      }
      close(fd);
    } else {
      strncpy(moduleName_local, moduleName, sizeof(moduleName_local));
    }
  }

  for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
    const char *name = _dyld_get_image_name(i);
    bool match = false;
    if (moduleNameIsBasename) {
      match = (strstr(basename((char *)name), moduleName_local) != NULL);
    } else {
      match = (strstr(name, moduleName_local) != NULL);
    }
    if (match) {
      if (pMh) {
        *pMh =
#ifdef __LP64__
        (const struct mach_header_64 *)
#endif
        _dyld_get_image_header(i);
      }
      if (pVmaddrSlide) {
        *pVmaddrSlide = _dyld_get_image_vmaddr_slide(i);
      }
      break;
    }
  }
}

// Helper method for module_dysym() below.
static const
#ifdef __LP64__
struct segment_command_64 *
GetSegment(const struct mach_header_64* mh,
#else
struct segment_command *
GetSegment(const struct mach_header* mh,
#endif
           const char *segname,
           uint32_t *numFollowingCommands)
{
  if (numFollowingCommands) {
    *numFollowingCommands = 0;
  }
  uint32_t numCommands = mh->ncmds;

#ifdef __LP64__
  const struct segment_command_64 *aCommand = (struct segment_command_64 *)
    ((uintptr_t)mh + sizeof(struct mach_header_64));
#else
  const struct segment_command *aCommand = (struct segment_command *)
    ((uintptr_t)mh + sizeof(struct mach_header));
#endif

  for (uint32_t i = 1; i <= numCommands; ++i) {
#ifdef __LP64__
    if (aCommand->cmd != LC_SEGMENT_64)
#else
    if (aCommand->cmd != LC_SEGMENT)
#endif
    {
      break;
    }
    if (strcmp(segname, aCommand->segname) == 0) {
      if (numFollowingCommands) {
        *numFollowingCommands = numCommands-i;
      }
      return aCommand;
    }
    aCommand =
#ifdef __LP64__
      (struct segment_command_64 *)
#else
      (struct segment_command *)
#endif
      ((uintptr_t)aCommand + aCommand->cmdsize);
  }

  return NULL;
}

// A variant of dlsym() that can find non-exported (non-public) symbols.
// Unlike with dlsym() and friends, 'symbol' should be specified exactly as it
// appears in the symbol table (and the output of programs like 'nm').  In
// other words, 'symbol' should (most of the time) be prefixed by an "extra"
// underscore.  The reason is that some symbols (especially non-public ones)
// don't have any underscore prefix, even in the symbol table.
extern "C" void *module_dlsym(const char *module_name, const char *symbol)
{
#ifdef __LP64__
  const struct mach_header_64 *mh = NULL;
#else
  const struct mach_header *mh = NULL;
#endif
  intptr_t vmaddr_slide = 0;
  GetModuleHeaderAndSlide(module_name, &mh, &vmaddr_slide);
  if (!mh) {
    return NULL;
  }

  uint32_t numFollowingCommands = 0;
#ifdef __LP64__
  const struct segment_command_64 *linkeditSegment =
#else
  const struct segment_command *linkeditSegment =
#endif
    GetSegment(mh, "__LINKEDIT", &numFollowingCommands);
  if (!linkeditSegment) {
    return NULL;
  }
  uintptr_t fileoffIncrement =
    linkeditSegment->vmaddr - linkeditSegment->fileoff;

  struct symtab_command *symtab = (struct symtab_command *)
    ((uintptr_t)linkeditSegment + linkeditSegment->cmdsize);
  for (uint32_t i = 1;; ++i) {
    if (symtab->cmd == LC_SYMTAB) {
      break;
    }
    if (i == numFollowingCommands) {
      return NULL;
    }
    symtab = (struct symtab_command *)
      ((uintptr_t)symtab + symtab->cmdsize);
  }
  uintptr_t symbolTableOffset =
    symtab->symoff + fileoffIncrement + vmaddr_slide;
  uintptr_t stringTableOffset =
    symtab->stroff + fileoffIncrement + vmaddr_slide;

  struct dysymtab_command *dysymtab = (struct dysymtab_command *)
    ((uintptr_t)symtab + symtab->cmdsize);
  if (dysymtab->cmd != LC_DYSYMTAB) {
    return NULL;
  }

  void *retval = NULL;
  for (int i = 1; i <= 2; ++i) {
    uint32_t index;
    uint32_t count;
    if (i == 1) {
      index = dysymtab->ilocalsym;
      count = index + dysymtab->nlocalsym;
    } else {
      index = dysymtab->iextdefsym;
      count = index + dysymtab->nextdefsym;
    }

    for (uint32_t j = index; j < count; ++j) {
#ifdef __LP64__
      struct nlist_64 *symbolTableItem = (struct nlist_64 *)
        (symbolTableOffset + j * sizeof(struct nlist_64));
#else
      struct nlist *symbolTableItem = (struct nlist *)
        (symbolTableOffset + j * sizeof(struct nlist));
#endif
      uint8_t type = symbolTableItem->n_type;
      if ((type & N_STAB) || ((type & N_TYPE) != N_SECT)) {
        continue;
      }
      uint8_t sect = symbolTableItem->n_sect;
      if (!sect) {
        continue;
      }
      const char *stringTableItem = (char *)
        (stringTableOffset + symbolTableItem->n_un.n_strx);
      if (strcmp(symbol, stringTableItem)) {
        continue;
      }
      retval = (void *) (symbolTableItem->n_value + vmaddr_slide);
      break;
    }
  }

  return retval;
}

// dladdr() is normally used from libdyld.dylib.  But this isn't safe before
// our execution environment is fully initialized.  So instead we use it from
// the copy of dyld loaded in every Mach executable, which has no external
// dependencies.

int (*dyld_dladdr_caller)(const void *addr, Dl_info *info) = NULL;

int dyld_dladdr(const void *addr, Dl_info *info)
{
  if (!dyld_dladdr_caller) {
    dyld_dladdr_caller = (int (*)(const void*, Dl_info *))
      module_dlsym("dyld", "_dladdr");
    if (!dyld_dladdr_caller) {
      return 0;
    }
  }
  return dyld_dladdr_caller(addr, info);
}

// Call this from a hook to get the filename of the module from which the hook
// was called -- which of course is also the module from which the original
// method was called.
const char *GetCallerOwnerName()
{
  static char holder[1024] = {0};

  const char *ownerName = "";
  Dl_info addressInfo = {0};
  void **addresses = (void **) calloc(3, sizeof(void *));
  if (addresses) {
    int count = backtrace(addresses, 3);
    if (count == 3) {
      if (dyld_dladdr(addresses[2], &addressInfo)) {
        ownerName = basename((char *)addressInfo.dli_fname);
      }
    }
    free(addresses);
  }

  strncpy(holder, ownerName, sizeof(holder));
  return holder;
}

// Reset a patch hook after it's been unset (as it was called).  Not always
// required -- most patch hooks don't get unset when called.  But using it
// when not required does no harm.
void reset_hook(void *hook)
{
  __asm__ ("int %0" :: "N" (0x22));
}

class loadHandler
{
public:
  loadHandler();
  ~loadHandler() {}
};

loadHandler::loadHandler()
{
  basic_init();
#if (0)
  LogWithFormat(true, "Hook.mm: loadHandler()");
  PrintStackTrace();
#endif
}

loadHandler handler = loadHandler();

static BOOL gMethodsSwizzled = NO;
static void InitSwizzling()
{
  if (!gMethodsSwizzled) {
#if (0)
    LogWithFormat(true, "Hook.mm: InitSwizzling()");
    PrintStackTrace();
#endif
    gMethodsSwizzled = YES;
    // Swizzle methods here
#if (0)
    Class ExampleClass = ::NSClassFromString(@"Example");
    SwizzleMethods(ExampleClass, @selector(doSomethingWith:),
                   @selector(Example_doSomethingWith:), NO);
#endif
  }
}

extern "C" void *NSPushAutoreleasePool();

static void *Hooked_NSPushAutoreleasePool()
{
  void *retval = NSPushAutoreleasePool();
  if (IsMainThread()) {
    InitSwizzling();
  }
  return retval;
}

#if (0)
// If the PATCH_FUNCTION macro is used below, this will be set to the correct
// value by the the HookCase extension.
int (*patch_example_caller)(char *arg) = NULL;

static int Hooked_patch_example(char *arg)
{
  int retval = patch_example_caller(arg);
  LogWithFormat(true, "Hook.mm: example(): arg \"%s\", returning \'%i\'", arg, retval);
  PrintStackTrace();
  // Not always required, but using it when not required does no harm.
  reset_hook(reinterpret_cast<void*>(Hooked_example));
  return retval;
}

extern "C" int interpose_example(char *arg);

static int Hooked_interpose_example(char *arg)
{
  int retval = interpose_example(arg);
  LogWithFormat(true, "Hook.mm: example(): arg \"%s\", returning \'%i\'", arg, retval);
  PrintStackTrace();
  return retval;
}

@interface NSObject (ExampleMethodSwizzling)
- (id)Example_doSomethingWith:(id)whatever;
@end

@implementation NSObject (ExampleMethodSwizzling)

- (id)Example_doSomethingWith:(id)whatever
{
  id retval = [self Example_doSomethingWith:whatever];
  if ([self isKindOfClass:ExampleClass]) {
    LogWithFormat(true, "Hook.mm: [Example doSomethingWith:]: self %@, whatever %@, returning %@",
                  self, whatever, retval);
  }
  return retval;
}

@end
#endif // #if (0)

// Put other hooked methods and swizzled classes here

bool get_procargs(char ***argvp, char ***envp, void **buffer)
{
  if (!argvp || !envp || !buffer) {
    return false;
  }
  *argvp = NULL;
  *envp = NULL;
  *buffer = NULL;

  size_t buffer_size = 0;
  int mib[] = {CTL_KERN, KERN_PROCARGS2, getpid()};
  if (sysctl(mib, sizeof(mib), NULL, &buffer_size, NULL, 0)) {
    return false;
  }
  char *holder = (char *) calloc(buffer_size, 1);
  if (!holder) {
    return false;
  }
  // Bizarrely, without this next line we just get random noise!
  buffer_size += sizeof(int);
  if (sysctl(mib, sizeof(mib), holder, &buffer_size, NULL, 0)) {
    free(holder);
    return false;
  }

  // args_count doesn't include the process path, which is always first and
  // always present.
  int args_count = *((int *)holder);
  char *holder_begin = holder + sizeof(unsigned int);

  char *holder_past_end = holder + buffer_size;
  holder_past_end[-1] = 0;
  holder_past_end[-2] = 0;

  int args_env_count = 0;
  int i;
  char *item;
  for (i = 0, item = holder_begin; item < holder_past_end; ++i) {
    if (!item[0]) {
      args_env_count = i;
      break;
    }
    item += strlen(item) + 1;
    // The process path (the first 'item') is padded (at the end) with
    // multiple NULLs.  Presumably a fixed amount of storage has been set
    // aside for it.
    if (i == 0) {
      while (!item[0]) {
        ++item;
      }
    }
  }
  int env_count = args_env_count - (args_count + 1);

  char **argvp_holder = NULL;
  if (args_count > 0) {
    argvp_holder = (char **) calloc(args_count + 1, sizeof(char *));
    if (!argvp_holder) {
      free(holder);
      return false;
    }
  }
  char **envp_holder = NULL;
  if (env_count > 0) {
    envp_holder = (char **) calloc(env_count + 1, sizeof(char *));
    if (!envp_holder) {
      free(holder);
      free(argvp_holder);
      return false;
    }
  }

  if (!argvp_holder && !envp_holder) {
    free(holder);
    return false;
  }

  for (i = 0, item = holder_begin; i < args_env_count; ++i) {
    // Skip over the process path
    if (i > 0) {
      if (i < args_count + 1) {
        argvp_holder[i - 1] = item;
      } else {
        envp_holder[i - (args_count + 1)] = item;
      }
    }
    item += strlen(item) + 1;
    if (i == 0) {
      while (!item[0]) {
        ++item;
      }
    }
  }
  if (argvp_holder) {
    argvp_holder[args_count] = NULL;
  }
  if (envp_holder) {
    envp_holder[env_count] = NULL;
  }

  *argvp = argvp_holder;
  *envp = envp_holder;
  *buffer = holder;
  return true;
}

// setenv() is called just once from xpcproxy, very close to the start of its
// main() method.  We aren't interested in setenv() itself.  We hook it to log
// the command line and environment with which xpcproxy was called.

int (*setenv_caller)(const char *name, const char *value, int overwrite) = NULL;

static int Hooked_setenv(const char *name, const char *value, int overwrite)
{
  bool is_xpcproxy = false;
  const char *owner_name = GetCallerOwnerName();
  if (!strcmp(owner_name, "xpcproxy")) {
    is_xpcproxy = true;
  }

  int retval = setenv_caller(name, value, overwrite);
  if (is_xpcproxy) {
    char **argvp = NULL;
    char **envp = NULL;
    void *buffer = NULL;
    if (get_procargs(&argvp, &envp, &buffer)) {
      LogWithFormat(true, "xpcproxy:");
      if (argvp) {
        LogWithFormat(false, "  argv:");
        for (int i = 0; ; ++i) {
          char *arg = argvp[i];
          if (!arg) {
            break;
          }
          LogWithFormat(false, "    %s", arg);
        }
      }
      if (envp) {
        LogWithFormat(false, "  envp:");
        for (int i = 0; ; ++i) {
          char *line = envp[i];
          if (!line) {
            break;
          }
          LogWithFormat(false, "    %s", line);
        }
      }
      if (argvp) {
        free(argvp);
      }
      if (envp) {
        free(envp);
      }
      free(buffer);
    }
  }

  return retval;
}

// xpc_pipe_routine() sends a 'request' to launchd for information on the XPC
// service to be launched.  That information is received in 'reply' (mostly in
// the 'blob' field).  ('pipe' was previously created via a call to
// xpc_create_pipe_from_port().  This port and one other (the bootstrap port)
// were previously stored in shared memory (using mach_ports_register()) by
// launchd before spawning xpcproxy.  xpcproxy (via _libxpc_initializer())
// retrieved these ports with a call to mach_ports_lookup(), and stored both
// in the os_alloc_once region for OS_ALLOC_ONCE_KEY_LIBXPC (1).  The two
// ports are stored at offsets 0x10 and 0x14 in this region -- offset 0x10 for
// what will become xpcproxy's bootstrap port (via a call to
// task_set_special_port()) and offset 0x14 for the port used to create
// 'pipe'.)

typedef struct _xpc_pipe *xpc_pipe_t;

extern "C" int xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t request,
                                xpc_object_t *reply);

int (*xpc_pipe_routine_caller)(xpc_pipe_t, xpc_object_t, xpc_object_t *) = NULL;

static int Hooked_xpc_pipe_routine(xpc_pipe_t pipe, xpc_object_t request,
                                   xpc_object_t *reply)
{
  bool is_xpcproxy = false;
  const char *owner_name = GetCallerOwnerName();
  if (!strcmp(owner_name, "xpcproxy")) {
    is_xpcproxy = true;
  }

  int retval = xpc_pipe_routine_caller(pipe, request, reply);
  if (is_xpcproxy) {
    char *request_desc = NULL;
    if (request) {
      request_desc = xpc_copy_description(request);
    }
    char *reply_desc = NULL;
    if (reply && *reply) {
      reply_desc = xpc_copy_description(*reply);
    }
    LogWithFormat(true, "xpcproxy: xpc_pipe_routine(): request %s, reply %s, returning %i",
                  request_desc ? request_desc : "null",
                  reply_desc ? reply_desc : "null", retval);
    if (request_desc) {
      free(request_desc);
    }
    if (reply_desc) {
      free(reply_desc);
    }
  }

  return retval;
}

char *get_data_as_string(const void *data, size_t length)
{
  if (!data || !length) {
    return NULL;
  }
  char *retval = (char *) calloc((2 * length) + 1, 1);
  if (!retval) {
    return NULL;
  }
  for (int i = 0; i < length; ++i) {
    const char item = ((const char *)data)[i];
    char item_string[5] = {0};
    if ((item >= 0x20) && (item <= 0x7e)) {
      item_string[0] = item;
    } else {
      snprintf(item_string, sizeof(item_string), "%02x", item);
    }
    strncat(retval, item_string, length);
  }
  return retval;
}

// xpcproxy calls xpc_dictionary_get_data() on the 'reply' returned by
// xpc_pipe_routine() above, to get the data in its 'blob' field.

const void *(*xpc_dictionary_get_data_caller)
            (xpc_object_t, const char *, size_t *) = NULL;

static const void *Hooked_xpc_dictionary_get_data(xpc_object_t dictionary,
                                                  const char *key,
                                                  size_t *length)
{
  bool is_xpcproxy = false;
  const char *owner_name = GetCallerOwnerName();
  if (!strcmp(owner_name, "xpcproxy")) {
    is_xpcproxy = true;
  }
  const void *retval = xpc_dictionary_get_data_caller(dictionary, key, length);
  if (is_xpcproxy) {
    char *data_string = NULL;
    if (retval && length && *length) {
      data_string = get_data_as_string(retval, *length);
    }
    LogWithFormat(true, "xpcproxy: xpc_dictionary_get_data(): key %s, returning %s",
                  key, data_string ? data_string : "null");
    if (data_string) {
      free(data_string);
    }
  }
  return retval;
}

// Once xpcproxy has the information it needs, it uses it to "exec" the
// appropriate XPC service binary over itself.  For this it uses posix_spawn()
// with the POSIX_SPAWN_SETEXEC (0x0040) flag -- a Darwin-specific feature.
// This call doesn't (or shouldn't) return.

int (*posix_spawn_caller)(pid_t *pid, const char *path,
                          const posix_spawn_file_actions_t *file_actions,
                          const posix_spawnattr_t *attrp,
                          char *const argv[], char *const envp[]) = NULL;

static int Hooked_posix_spawn(pid_t *pid, const char *path,
                              const posix_spawn_file_actions_t *file_actions,
                              const posix_spawnattr_t *attrp,
                              char *const argv[], char *const envp[])
{
  bool is_xpcproxy = false;
  const char *owner_name = GetCallerOwnerName();
  if (!strcmp(owner_name, "xpcproxy")) {
    is_xpcproxy = true;
  }

  if (is_xpcproxy) {
    short psa_flags = 0;
    if (attrp) {
      posix_spawnattr_getflags(attrp, &psa_flags);
    }
    LogWithFormat(true, "xpcproxy: posix_spawn(): psa_flags \'0x%x\', path \"%s\"",
                  psa_flags, path);
    LogWithFormat(false, "  argv:");
    for (int i = 0; ; ++i) {
      char *arg = argv[i];
      if (!arg) {
        break;
      }
      LogWithFormat(false, "    %s", arg);
    }
    if (envp) {
      LogWithFormat(false, "  envp:");
      for (int i = 0; ; ++i) {
        char *line = envp[i];
        if (!line) {
          break;
        }
        LogWithFormat(false, "    %s", line);
      }
    }
  }
  int retval = posix_spawn_caller(pid, path, file_actions, attrp, argv, envp);
  if (is_xpcproxy) {
    LogWithFormat(true, "xpcproxy: posix_spawn(): returned \'%i\'", retval);
  }
  return retval;
}

// os_alloc_once() and _os_alloc_once() are implemented in libplatform.
typedef long os_once_t;
typedef os_once_t os_alloc_token_t;
struct _os_alloc_once_s {
  os_alloc_token_t once;
  void *ptr;
};
typedef void (*os_function_t)(void *_Nullable);
extern "C" void *_os_alloc_once(struct _os_alloc_once_s *slot, size_t sz,
                                os_function_t init);

extern "C" xpc_pipe_t xpc_pipe_create_from_port(mach_port_t port, int flags);
extern "C" int xpc_pipe_simpleroutine(xpc_pipe_t pipe, xpc_object_t request);
extern "C" const char *xpc_bundle_get_executable_path(xpc_object_t bundle);
typedef bool (*xpc_dictionary_applier_func_t)(const char *key,
                                              xpc_object_t value,
                                              void *context);
extern "C" bool xpc_dictionary_apply_f(xpc_object_t xdict, void *context,
                                       xpc_dictionary_applier_func_t applier);

typedef struct _hook_desc {
  const void *hook_function;
  union {
    // For interpose hooks
    const void *orig_function;
    // For patch hooks
    const void *caller_func_ptr;
  };
  const char *orig_function_name;
  const char *orig_module_name;
} hook_desc;

#define PATCH_FUNCTION(function, module)               \
  { reinterpret_cast<const void*>(Hooked_##function),  \
    reinterpret_cast<const void*>(&function##_caller), \
    "_" #function,                                     \
    #module }

#define INTERPOSE_FUNCTION(function)                   \
  { reinterpret_cast<const void*>(Hooked_##function),  \
    reinterpret_cast<const void*>(function),           \
    "_" #function,                                     \
    "" }

__attribute__((used)) static const hook_desc user_hooks[]
  __attribute__((section("__DATA, __hook"))) =
{
  INTERPOSE_FUNCTION(NSPushAutoreleasePool),
  PATCH_FUNCTION(_objc_init, /usr/lib/libobjc.dylib),
  PATCH_FUNCTION(_ZL10_objc_initv, /usr/lib/libobjc.dylib),

  PATCH_FUNCTION(setenv, /usr/lib/system/libsystem_c.dylib),
  PATCH_FUNCTION(xpc_pipe_routine, /usr/lib/system/libxpc.dylib),
  PATCH_FUNCTION(xpc_dictionary_get_data, /usr/lib/system/libxpc.dylib),
  PATCH_FUNCTION(posix_spawn, /usr/lib/system/libsystem_kernel.dylib),
};

// What follows are declarations of the CoreSymbolication APIs that we use to
// get stack traces.  This is an undocumented, private framework available on
// OS X 10.6 and up.  It's used by Apple utilities like atos and ReportCrash.

// Defined above
#if (0)
typedef struct _CSTypeRef {
  unsigned long type;
  void *contents;
} CSTypeRef;
#endif

typedef struct _CSRange {
  unsigned long long location;
  unsigned long long length;
} CSRange;

// Defined above
typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolOwnerRef;
typedef CSTypeRef CSSymbolRef;
typedef CSTypeRef CSSourceInfoRef;

typedef unsigned long long CSArchitecture;

#define kCSNow LONG_MAX

extern "C" {
CSSymbolicatorRef CSSymbolicatorCreateWithTaskFlagsAndNotification(task_t task,
                                                                   uint32_t flags,
                                                                   uint32_t notification);
CSSymbolicatorRef CSSymbolicatorCreateWithPid(pid_t pid);
CSSymbolicatorRef CSSymbolicatorCreateWithPidFlagsAndNotification(pid_t pid,
                                                                  uint32_t flags,
                                                                  uint32_t notification);
CSArchitecture CSSymbolicatorGetArchitecture(CSSymbolicatorRef symbolicator);
CSSymbolOwnerRef CSSymbolicatorGetSymbolOwnerWithAddressAtTime(CSSymbolicatorRef symbolicator,
                                                               unsigned long long address,
                                                               long time);

const char *CSSymbolOwnerGetName(CSSymbolOwnerRef owner);
unsigned long long CSSymbolOwnerGetBaseAddress(CSSymbolOwnerRef owner);
CSSymbolRef CSSymbolOwnerGetSymbolWithAddress(CSSymbolOwnerRef owner,
                                              unsigned long long address);
CSSourceInfoRef CSSymbolOwnerGetSourceInfoWithAddress(CSSymbolOwnerRef owner,
                                                      unsigned long long address);

const char *CSSymbolGetName(CSSymbolRef symbol);
CSRange CSSymbolGetRange(CSSymbolRef symbol);

const char *CSSourceInfoGetFilename(CSSourceInfoRef info);
uint32_t CSSourceInfoGetLineNumber(CSSourceInfoRef info);

CSTypeRef CSRetain(CSTypeRef);
void CSRelease(CSTypeRef);
bool CSIsNull(CSTypeRef);
void CSShow(CSTypeRef);
const char *CSArchitectureGetFamilyName(CSArchitecture);
} // extern "C"

CSSymbolicatorRef gSymbolicator = {0};

void CreateGlobalSymbolicator()
{
  if (CSIsNull(gSymbolicator)) {
    // 0x40e0000 is the value returned by
    // uint32_t CSSymbolicatorGetFlagsForNListOnlyData(void).  We don't use
    // this method directly because it doesn't exist on OS X 10.6.  Unless
    // we limit ourselves to NList data, it will take too long to get a
    // stack trace where Dwarf debugging info is available (about 15 seconds
    // with Firefox).
    gSymbolicator =
      CSSymbolicatorCreateWithTaskFlagsAndNotification(mach_task_self(), 0x40e0000, 0);
  }
}

// Does nothing (and returns 'false') if *symbolicator is already non-null.
// Otherwise tries to set it appropriately.  Returns 'true' if the returned
// *symbolicator will need to be released after use (because it isn't the
// global symbolicator).
bool GetSymbolicator(CSSymbolicatorRef *symbolicator)
{
  bool retval = false;
  if (CSIsNull(*symbolicator)) {
    if (!CSIsNull(gSymbolicator)) {
      *symbolicator = gSymbolicator;
    } else {
      // 0x40e0000 is the value returned by
      // uint32_t CSSymbolicatorGetFlagsForNListOnlyData(void).  We don't use
      // this method directly because it doesn't exist on OS X 10.6.  Unless
      // we limit ourselves to NList data, it will take too long to get a
      // stack trace where Dwarf debugging info is available (about 15 seconds
      // with Firefox).  This means we won't be able to get a CSSourceInfoRef,
      // or line number information.  Oh well.
      *symbolicator =
        CSSymbolicatorCreateWithTaskFlagsAndNotification(mach_task_self(), 0x40e0000, 0);
      if (!CSIsNull(*symbolicator)) {
        retval = true;
      }
    }
  }
  return retval;
}

const char *GetOwnerName(void *address, CSTypeRef owner)
{
  static char holder[1024] = {0};

  const char *ownerName = "unknown";

  bool symbolicatorNeedsRelease = false;
  CSSymbolicatorRef symbolicator = {0};

  if (CSIsNull(owner)) {
    symbolicatorNeedsRelease = GetSymbolicator(&symbolicator);
    if (!CSIsNull(symbolicator)) {
      owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(
                symbolicator,
                (unsigned long long) address,
                kCSNow);
    }
  }

  if (!CSIsNull(owner)) {
    ownerName = CSSymbolOwnerGetName(owner);
  }

  snprintf(holder, sizeof(holder), "%s", ownerName);
  if (symbolicatorNeedsRelease) {
    CSRelease(symbolicator);
  }

  return holder;
}

const char *GetAddressString(void *address, CSTypeRef owner)
{
  static char holder[1024] = {0};

  const char *addressName = "unknown";
  unsigned long long addressOffset = 0;
  bool addressOffsetIsBaseAddress = false;

  bool symbolicatorNeedsRelease = false;
  CSSymbolicatorRef symbolicator = {0};

  if (CSIsNull(owner)) {
    symbolicatorNeedsRelease = GetSymbolicator(&symbolicator);
    if (!CSIsNull(symbolicator)) {
      owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(
                symbolicator,
                (unsigned long long) address,
                kCSNow);
    }
  }

  if (!CSIsNull(owner)) {
    CSSymbolRef symbol =
      CSSymbolOwnerGetSymbolWithAddress(owner, (unsigned long long) address);
    if (!CSIsNull(symbol)) {
      addressName = CSSymbolGetName(symbol);
      CSRange range = CSSymbolGetRange(symbol);
      addressOffset = (unsigned long long) address;
      if (range.location <= addressOffset) {
        addressOffset -= range.location;
      } else {
        addressOffsetIsBaseAddress = true;
      }
    } else {
      addressOffset = (unsigned long long) address;
      unsigned long long baseAddress = CSSymbolOwnerGetBaseAddress(owner);
      if (baseAddress <= addressOffset) {
        addressOffset -= baseAddress;
      } else {
        addressOffsetIsBaseAddress = true;
      }
    }
  }

  if (addressOffsetIsBaseAddress) {
    snprintf(holder, sizeof(holder), "%s 0x%llx",
             addressName, addressOffset);
  } else {
    snprintf(holder, sizeof(holder), "%s + 0x%llx",
             addressName, addressOffset);
  }
  if (symbolicatorNeedsRelease) {
    CSRelease(symbolicator);
  }

  return holder;
}

void PrintAddress(void *address, CSTypeRef symbolicator)
{
  const char *ownerName = "unknown";
  const char *addressString = "unknown + 0";

  bool symbolicatorNeedsRelease = false;
  CSSymbolOwnerRef owner = {0};

  if (CSIsNull(symbolicator)) {
    symbolicatorNeedsRelease = GetSymbolicator(&symbolicator);
    if (!CSIsNull(symbolicator)) {
      owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(
                symbolicator,
                (unsigned long long) address,
                kCSNow);
    }
  }

  if (!CSIsNull(symbolicator)) {
      owner = CSSymbolicatorGetSymbolOwnerWithAddressAtTime(
                symbolicator,
                (unsigned long long) address,
                kCSNow);
  }

  if (!CSIsNull(owner)) {
    ownerName = GetOwnerName(address, owner);
    addressString = GetAddressString(address, owner);
  }
  LogWithFormat(false, "    (%s) %s", ownerName, addressString);

  if (symbolicatorNeedsRelease) {
    CSRelease(symbolicator);
  }
}

#define STACK_MAX 256

void PrintStackTrace()
{
  if (!CanUseCF()) {
    return;
  }

  void **addresses = (void **) calloc(STACK_MAX, sizeof(void *));
  if (!addresses) {
    return;
  }

  CSSymbolicatorRef symbolicator = {0};
  bool symbolicatorNeedsRelease = GetSymbolicator(&symbolicator);
  if (CSIsNull(symbolicator)) {
    free(addresses);
    return;
  }

  uint32_t count = backtrace(addresses, STACK_MAX);
  for (uint32_t i = 0; i < count; ++i) {
    PrintAddress(addresses[i], symbolicator);
  }

  if (symbolicatorNeedsRelease) {
    CSRelease(symbolicator);
  }
  free(addresses);
}

BOOL SwizzleMethods(Class aClass, SEL orgMethod, SEL posedMethod, BOOL classMethods)
{
  Method original = nil;
  Method posed = nil;

  if (classMethods) {
    original = class_getClassMethod(aClass, orgMethod);
    posed = class_getClassMethod(aClass, posedMethod);
  } else {
    original = class_getInstanceMethod(aClass, orgMethod);
    posed = class_getInstanceMethod(aClass, posedMethod);
  }

  if (!original || !posed)
    return NO;

  method_exchangeImplementations(original, posed);

  return YES;
}
