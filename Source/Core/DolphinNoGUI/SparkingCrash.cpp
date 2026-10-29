// Copyright 2026 Dolphin-Sparking Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DolphinNoGUI/SparkingCrash.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <exception>
#include <mutex>
#include <string>

#include "DolphinNoGUI/SparkingIO.h"

#ifdef _WIN32
#include <cwchar>
#include <windows.h>
// (after windows.h)
#include <dbghelp.h>
#else
#include <execinfo.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace Sparking
{
namespace
{
// The last events, kept in fixed buffers so the crash handler needs no allocation to read
// them. Written under s_note_mutex (the event writer is already serialised); read without it.
constexpr size_t RING_SIZE = 40;
constexpr size_t LINE_LEN = 600;
using LineBuf = std::array<char, LINE_LEN>;
std::array<LineBuf, RING_SIZE> s_ring{};
std::atomic<unsigned> s_ring_next{0};
LineBuf s_last_game{};   // the last game_booting / game_started (they scroll out of the ring)
LineBuf s_last_stats{};  // the last "stats" (frame rate, ...): they'd flood the ring
std::array<char, 512> s_context{};
std::mutex s_note_mutex;
std::atomic<bool> s_crashing{false};
std::string s_dir;  // the crash folder, "" = none

void CopyLine(LineBuf& to, std::string_view from)
{
  while (!from.empty() && (from.back() == '\n' || from.back() == '\r'))
    from.remove_suffix(1);
  const size_t n = std::min(from.size(), LINE_LEN - 1);
  std::memcpy(to.data(), from.data(), n);
  to[n] = '\0';
}

void TimeStamp(char* out, size_t size, const char* format)
{
  const std::time_t now = std::time(nullptr);
  std::tm tm{};
#ifdef _WIN32
  localtime_s(&tm, &now);
#else
  localtime_r(&now, &tm);
#endif
  std::strftime(out, size, format, &tm);
}

// --- Writing the report: a few small helpers over one open file ----------------------------

struct Out
{
#ifdef _WIN32
  HANDLE h = INVALID_HANDLE_VALUE;
#else
  int fd = -1;
#endif
  bool Ok() const
  {
#ifdef _WIN32
    return h != INVALID_HANDLE_VALUE;
#else
    return fd >= 0;
#endif
  }
  void Raw(const char* s, size_t n) const
  {
    if (!Ok() || n == 0)
      return;
#ifdef _WIN32
    DWORD written = 0;
    WriteFile(h, s, static_cast<DWORD>(n), &written, nullptr);
#else
    while (n > 0)
    {
      const ssize_t w = write(fd, s, n);
      if (w <= 0)
        return;
      s += w;
      n -= static_cast<size_t>(w);
    }
#endif
  }
  void Str(const char* s) const { Raw(s, std::strlen(s)); }
  void Line(const char* s) const
  {
    Str(s);
    Str("\n");
  }
  template <typename... Args>
  void F(const char* format, Args... args) const
  {
    char buf[1024];
    const int n = std::snprintf(buf, sizeof(buf), format, args...);
    if (n > 0)
      Raw(buf, std::min(static_cast<size_t>(n), sizeof(buf) - 1));
  }
};

void WriteCommonTail(const Out& out)
{
  out.Line("");
  out.F("Context: %s\n", s_context[0] ? s_context.data() : "(none)");
  if (s_last_game[0])
    out.F("Game: %s\n", s_last_game.data());
  if (s_last_stats[0])
    out.F("Last stats: %s\n", s_last_stats.data());
  out.Line("");
  out.Line("Last events (oldest first):");
  const unsigned next = s_ring_next.load();
  const unsigned count = std::min(next, static_cast<unsigned>(RING_SIZE));
  for (unsigned i = next - count; i != next; ++i)
  {
    const LineBuf& l = s_ring[i % RING_SIZE];
    if (l[0])
      out.F("  %s\n", l.data());
  }
}

// Tells the launcher (stdout, one event line; not through the emit lock: it may be held).
void EmitCrashEvent(const std::string& report, const std::string& dump, const char* summary)
{
  std::string line(EVENT_PREFIX);
  line += "{\"event\":\"crash\",\"report\":";
  line += Json::Escape(report);
  line += ",\"dump\":";
  line += Json::Escape(dump);
  line += ",\"summary\":";
  line += Json::Escape(summary);
  line += "}\n";
  std::fwrite(line.data(), 1, line.size(), stdout);
  std::fflush(stdout);
}

#ifdef _WIN32
// --- Windows ------------------------------------------------------------------------------

std::wstring Widen(const std::string& s)
{
  if (s.empty())
    return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

std::string Narrow(const wchar_t* w)
{
  const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1)
    return {};
  std::string s(static_cast<size_t>(n - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, s.data(), n, nullptr, nullptr);
  return s;
}

const char* ExceptionName(DWORD code)
{
  switch (code)
  {
  case EXCEPTION_ACCESS_VIOLATION:
    return "access violation";
  case EXCEPTION_STACK_OVERFLOW:
    return "stack overflow";
  case EXCEPTION_ILLEGAL_INSTRUCTION:
    return "illegal instruction";
  case EXCEPTION_PRIV_INSTRUCTION:
    return "privileged instruction";
  case EXCEPTION_INT_DIVIDE_BY_ZERO:
    return "integer divide by zero";
  case EXCEPTION_IN_PAGE_ERROR:
    return "in-page error (a file it was reading went away?)";
  case EXCEPTION_DATATYPE_MISALIGNMENT:
    return "misaligned data";
  case EXCEPTION_ARRAY_BOUNDS_EXCEEDED:
    return "array bounds exceeded";
  case 0xC0000409:
    return "stack buffer overrun / fail fast";
  case 0xC0000374:
    return "heap corruption";
  case 0xE06D7363:
    return "unhandled C++ exception";
  case 0xE0005350:
    return "abort / std::terminate";
  default:
    return "exception";
  }
}

// "DolphinNoGUI.exe+0x123456" for an address.
std::string WhereIs(DWORD64 address)
{
  HMODULE module = nullptr;
  char buf[64];
  if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                             GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         reinterpret_cast<LPCWSTR>(address), &module) &&
      module)
  {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(module, path, MAX_PATH);
    const wchar_t* name = wcsrchr(path, L'\\');
    std::snprintf(buf, sizeof(buf), "+0x%llx",
                  static_cast<unsigned long long>(address - reinterpret_cast<DWORD64>(module)));
    return Narrow(name ? name + 1 : path) + buf;
  }
  std::snprintf(buf, sizeof(buf), "0x%llx", static_cast<unsigned long long>(address));
  return buf;
}

void WriteStack(const Out& out, const CONTEXT* context)
{
  const HANDLE process = GetCurrentProcess();
  const HANDLE thread = GetCurrentThread();
  SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES | SYMOPT_FAIL_CRITICAL_ERRORS);
  const bool symbols = SymInitialize(process, nullptr, TRUE) != FALSE;

  CONTEXT ctx = *context;
  STACKFRAME64 frame{};
#if defined(_M_X64)
  const DWORD machine = IMAGE_FILE_MACHINE_AMD64;
  frame.AddrPC.Offset = ctx.Rip;
  frame.AddrFrame.Offset = ctx.Rbp;
  frame.AddrStack.Offset = ctx.Rsp;
#elif defined(_M_ARM64)
  const DWORD machine = IMAGE_FILE_MACHINE_ARM64;
  frame.AddrPC.Offset = ctx.Pc;
  frame.AddrFrame.Offset = ctx.Fp;
  frame.AddrStack.Offset = ctx.Sp;
#else
#error "Sparking crash reports: unsupported Windows architecture"
#endif
  frame.AddrPC.Mode = AddrModeFlat;
  frame.AddrFrame.Mode = AddrModeFlat;
  frame.AddrStack.Mode = AddrModeFlat;

  out.Line("");
  out.Line("Stack (crashing thread):");
  for (int i = 0; i < 64; ++i)
  {
    if (!StackWalk64(machine, process, thread, &frame, &ctx, nullptr, SymFunctionTableAccess64,
                     SymGetModuleBase64, nullptr) ||
        frame.AddrPC.Offset == 0)
    {
      break;
    }
    const DWORD64 pc = frame.AddrPC.Offset;
    std::string text = WhereIs(pc);
    if (symbols)
    {
      alignas(SYMBOL_INFO) char sym_buf[sizeof(SYMBOL_INFO) + 256] = {};
      auto* sym = reinterpret_cast<SYMBOL_INFO*>(sym_buf);
      sym->SizeOfStruct = sizeof(SYMBOL_INFO);
      sym->MaxNameLen = 255;
      DWORD64 displacement = 0;
      if (SymFromAddr(process, pc, &displacement, sym))
      {
        char buf[320];
        std::snprintf(buf, sizeof(buf), "  %s+0x%llx", sym->Name,
                      static_cast<unsigned long long>(displacement));
        text += buf;
      }
      IMAGEHLP_LINE64 line{};
      line.SizeOfStruct = sizeof(line);
      DWORD line_disp = 0;
      if (SymGetLineFromAddr64(process, pc, &line_disp, &line) && line.FileName)
      {
        const char* file = std::strrchr(line.FileName, '\\');
        char buf[320];
        std::snprintf(buf, sizeof(buf), "  (%s:%lu)", file ? file + 1 : line.FileName,
                      static_cast<unsigned long>(line.LineNumber));
        text += buf;
      }
    }
    out.F("  #%02d %s\n", i, text.c_str());
  }
  if (symbols)
    SymCleanup(process);
}

void WriteReport(EXCEPTION_POINTERS* ep, const char* reason)
{
  if (s_crashing.exchange(true))
    return;  // crashed again while reporting

  char stamp[32];
  TimeStamp(stamp, sizeof(stamp), "%Y%m%d_%H%M%S");
  char when[64];
  TimeStamp(when, sizeof(when), "%Y-%m-%d %H:%M:%S");
  const EXCEPTION_RECORD* rec = ep->ExceptionRecord;
  const DWORD code = rec->ExceptionCode;
  const DWORD64 address = reinterpret_cast<DWORD64>(rec->ExceptionAddress);

  char summary[512];
  const std::string where = WhereIs(address);
  if (reason && *reason)
    std::snprintf(summary, sizeof(summary), "%s at %s", reason, where.c_str());
  else
    std::snprintf(summary, sizeof(summary), "%s (0x%08lX) at %s", ExceptionName(code),
                  static_cast<unsigned long>(code), where.c_str());

  std::string report, dump;
  if (!s_dir.empty())
  {
    CreateDirectoryW(Widen(s_dir).c_str(), nullptr);
    const std::string base = s_dir + "\\dolphin_crash_" + stamp;
    // The minidump first: it's the most useful part, and the heap may be in a bad state.
    dump = base + ".dmp";
    const HANDLE dh = CreateFileW(Widen(dump).c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
    if (dh != INVALID_HANDLE_VALUE)
    {
      MINIDUMP_EXCEPTION_INFORMATION mei{};
      mei.ThreadId = GetCurrentThreadId();
      mei.ExceptionPointers = ep;
      mei.ClientPointers = FALSE;
      const auto type = static_cast<MINIDUMP_TYPE>(MiniDumpNormal | MiniDumpWithThreadInfo |
                                                   MiniDumpWithUnloadedModules);
      if (!MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), dh, type, &mei, nullptr,
                             nullptr))
      {
        dump.clear();
      }
      CloseHandle(dh);
      if (dump.empty())
        DeleteFileW(Widen(base + ".dmp").c_str());
    }
    else
    {
      dump.clear();
    }
    report = base + ".txt";
  }

  Out out;
  if (!report.empty())
  {
    out.h = CreateFileW(Widen(report).c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (!out.Ok())
      report.clear();
  }
  out.F("%s crashed\n", APP_NAME);
  out.F("Time: %s\n", when);
  out.F("What: %s\n", summary);
  out.F("Exception: 0x%08lX (%s), thread %lu\n", static_cast<unsigned long>(code),
        ExceptionName(code), static_cast<unsigned long>(GetCurrentThreadId()));
  if ((code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_IN_PAGE_ERROR) &&
      rec->NumberParameters >= 2)
  {
    const ULONG_PTR kind = rec->ExceptionInformation[0];
    out.F("Access: %s address 0x%llx\n", kind == 0 ? "reading" : kind == 1 ? "writing" : "executing",
          static_cast<unsigned long long>(rec->ExceptionInformation[1]));
  }
  if (!dump.empty())
    out.F("Minidump: %s\n", dump.c_str());
  WriteStack(out, ep->ContextRecord);
  WriteCommonTail(out);
  if (out.Ok())
    CloseHandle(out.h);

  EmitCrashEvent(report, dump, summary);
}

LONG WINAPI OnUnhandledException(EXCEPTION_POINTERS* ep)
{
  WriteReport(ep, nullptr);
  return EXCEPTION_EXECUTE_HANDLER;  // ends the process (no "has stopped working" box)
}

// abort(), std::terminate, pure virtual calls, bad CRT arguments: no exception to report, so
// one is made up from here.
[[noreturn]] void ReportHere(const char* reason)
{
  CONTEXT ctx{};
  RtlCaptureContext(&ctx);
  EXCEPTION_RECORD rec{};
  rec.ExceptionCode = 0xE0005350;
#if defined(_M_X64)
  rec.ExceptionAddress = reinterpret_cast<PVOID>(ctx.Rip);
#elif defined(_M_ARM64)
  rec.ExceptionAddress = reinterpret_cast<PVOID>(ctx.Pc);
#endif
  EXCEPTION_POINTERS ep{&rec, &ctx};
  WriteReport(&ep, reason);
  TerminateProcess(GetCurrentProcess(), 3);
  std::_Exit(3);
}

void OnAbortSignal(int)
{
  ReportHere("abort()");
}

void OnPureCall()
{
  ReportHere("pure virtual function call");
}

void OnInvalidParameter(const wchar_t*, const wchar_t*, const wchar_t*, unsigned int, uintptr_t)
{
  ReportHere("invalid argument to a C runtime function");
}

#else
// --- Linux / macOS ------------------------------------------------------------------------

const char* SignalName(int sig)
{
  switch (sig)
  {
  case SIGSEGV:
    return "segmentation fault (SIGSEGV)";
  case SIGBUS:
    return "bus error (SIGBUS)";
  case SIGILL:
    return "illegal instruction (SIGILL)";
  case SIGFPE:
    return "arithmetic error (SIGFPE)";
  case SIGABRT:
    return "abort (SIGABRT)";
  default:
    return "signal";
  }
}

std::array<char, 4096> s_report_path{};
constexpr std::array<int, 5> CRASH_SIGNALS = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};

void WriteReport(int sig, const siginfo_t* info, const char* reason)
{
  if (s_crashing.exchange(true))
    return;
  char stamp[32];
  TimeStamp(stamp, sizeof(stamp), "%Y%m%d_%H%M%S");
  char when[64];
  TimeStamp(when, sizeof(when), "%Y-%m-%d %H:%M:%S");

  Out out;
  s_report_path[0] = '\0';
  if (!s_dir.empty())
  {
    std::snprintf(s_report_path.data(), s_report_path.size(), "%s/dolphin_crash_%s.txt",
                  s_dir.c_str(), stamp);
    mkdir(s_dir.c_str(), 0755);   // (one level: its parent is the launcher's data folder)
    out.fd = open(s_report_path.data(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (!out.Ok())
      s_report_path[0] = '\0';
  }
  char summary[256];
  if (reason)
    std::snprintf(summary, sizeof(summary), "%s", reason);
  else if (info && (sig == SIGSEGV || sig == SIGBUS))
    std::snprintf(summary, sizeof(summary), "%s accessing %p", SignalName(sig), info->si_addr);
  else
    std::snprintf(summary, sizeof(summary), "%s", SignalName(sig));

  out.F("%s crashed\n", APP_NAME);
  out.F("Time: %s\n", when);
  out.F("What: %s\n", summary);
  out.Line("");
  out.Line("Stack (crashing thread):");
  void* frames[64];
  const int n = backtrace(frames, 64);
  if (out.Ok())
    backtrace_symbols_fd(frames, n, out.fd);
  WriteCommonTail(out);
  if (out.Ok())
    close(out.fd);
  EmitCrashEvent(s_report_path.data(), "", summary);
}

void OnCrashSignal(int sig, siginfo_t* info, void*)
{
  WriteReport(sig, info, nullptr);
  // SA_RESETHAND put the default action back: let it happen (exit status says the signal).
  raise(sig);
}
#endif

void OnTerminate()
{
  const char* what = "std::terminate (an error nobody handled)";
#ifdef _WIN32
  ReportHere(what);
#else
  WriteReport(SIGABRT, nullptr, what);
  signal(SIGABRT, SIG_DFL);
  std::abort();
#endif
}
}  // namespace

void InstallCrashHandler(const std::string& user_dir)
{
  if (const char* env = std::getenv("SPARKING_CRASH_DIR"); env && *env)
    s_dir = env;
  else if (!user_dir.empty())
    s_dir = user_dir + "/Logs";
#ifdef _WIN32
  for (char& c : s_dir)
  {
    if (c == '/')
      c = '\\';
  }
  while (s_dir.size() > 3 && s_dir.back() == '\\')
    s_dir.pop_back();
  SetUnhandledExceptionFilter(OnUnhandledException);
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
  std::signal(SIGABRT, OnAbortSignal);
  _set_purecall_handler(OnPureCall);
  _set_invalid_parameter_handler(OnInvalidParameter);
  // Stack overflows: leave room for the handler to run on the same stack.
  ULONG guarantee = 64 * 1024;
  SetThreadStackGuarantee(&guarantee);
#else
  while (s_dir.size() > 1 && s_dir.back() == '/')
    s_dir.pop_back();
  // Stack overflows: the handler runs on its own stack (main thread).
  static std::array<char, 64 * 1024> alt_stack;
  stack_t ss{};
  ss.ss_sp = alt_stack.data();
  ss.ss_size = alt_stack.size();
  sigaltstack(&ss, nullptr);
  // backtrace() loads libgcc the first time: do it now, not inside a crash.
  void* warm[1];
  backtrace(warm, 1);
  struct sigaction sa{};
  sa.sa_sigaction = OnCrashSignal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
  // (Dolphin's fastmem handler, installed later, passes the faults it doesn't own on to this.)
  for (const int sig : CRASH_SIGNALS)
    sigaction(sig, &sa, nullptr);
#endif
  std::set_terminate(OnTerminate);
}

void SetCrashContext(std::string_view text)
{
  std::lock_guard lk(s_note_mutex);
  const size_t n = std::min(text.size(), s_context.size() - 1);
  std::memcpy(s_context.data(), text.data(), n);
  s_context[n] = '\0';
}

void NoteEventForCrash(std::string_view line)
{
  if (line.substr(0, EVENT_PREFIX.size()) == EVENT_PREFIX)
    line.remove_prefix(EVENT_PREFIX.size());
  std::lock_guard lk(s_note_mutex);
#ifdef _WIN32
  // Something else (a graphics driver, a library) may have put in its own handler since
  // start-up and swallowed crashes before ours: put ours back (cheap, and often: stats every s).
  SetUnhandledExceptionFilter(OnUnhandledException);
#endif
  if (line.starts_with("{\"event\":\"stats\""))
  {
    CopyLine(s_last_stats, line);
    return;
  }
  if (line.starts_with("{\"event\":\"game_booting\"") ||
      line.starts_with("{\"event\":\"game_started\""))
  {
    CopyLine(s_last_game, line);
  }
  const unsigned i = s_ring_next.load();
  CopyLine(s_ring[i % RING_SIZE], line);
  s_ring_next.store(i + 1);
}

void CrashForTest(std::string_view how)
{
  if (how == "abort")
    std::abort();
  if (how == "terminate")
    std::terminate();
  volatile int* volatile nowhere = nullptr;
  *nowhere = 1;
  std::abort();
}
}  // namespace Sparking
