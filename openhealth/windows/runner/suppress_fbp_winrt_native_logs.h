#ifndef RUNNER_SUPPRESS_FBP_WINRT_NATIVE_LOGS_H_
#define RUNNER_SUPPRESS_FBP_WINRT_NATIVE_LOGS_H_

// Include the Windows declarations before replacing the debug-output call.
// The reviewed flutter_blue_plus_winrt 0.0.18 implementation otherwise emits
// raw BLE names and addresses even when its Dart log level is disabled.
#include <Windows.h>

#ifdef OutputDebugStringA
#undef OutputDebugStringA
#endif
#define OutputDebugStringA(message) ((void)(message))

#endif  // RUNNER_SUPPRESS_FBP_WINRT_NATIVE_LOGS_H_
