#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef void (WINAPI *ClosePseudoConsoleFn)(HANDLE);

typedef struct CloseConsoleContext {
  HANDLE console;
  HANDLE output;
  ClosePseudoConsoleFn close_console;
} CloseConsoleContext;

static DWORD WINAPI close_console_thread(void *parameter) {
  CloseConsoleContext *context = (CloseConsoleContext *)parameter;
  context->close_console(context->console);
  CloseHandle(context->output);
  HeapFree(GetProcessHeap(), 0, context);
  return 0;
}

int mynim_pty_close_console_async(void *console, HANDLE output) {
  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  if (kernel32 == NULL) return 0;
  ClosePseudoConsoleFn close_console = (ClosePseudoConsoleFn)
      GetProcAddress(kernel32, "ClosePseudoConsole");
  if (close_console == NULL) return 0;

  CloseConsoleContext *context = (CloseConsoleContext *)
      HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*context));
  if (context == NULL) return 0;
  context->console = (HANDLE)console;
  context->output = output;
  context->close_console = close_console;

  HANDLE thread = CreateThread(NULL, 0, close_console_thread, context, 0, NULL);
  if (thread == NULL) {
    HeapFree(GetProcessHeap(), 0, context);
    return 0;
  }
  CloseHandle(thread);
  return 1;
}
