/* Host-native Win16 API shim for executing the real wrapper, not an ABI
 * layout emulator. The QEMU gate verifies actual 16-bit pointer layouts. */
#ifndef USOS_TEST_WINDOWS_H
#define USOS_TEST_WINDOWS_H
#include <stddef.h>
#undef NULL
#define NULL 0
#define FAR
#define PASCAL
#define __far
#define __pascal
#define __export
#define __loadds
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef unsigned int DWORD,UINT,WPARAM,HANDLE,HINSTANCE,HWND;
typedef signed int LONG,LPARAM;
typedef int BOOL;
typedef char *LPSTR;
typedef const char *LPCSTR;
typedef void (*FARPROC)(void);
typedef LONG (*WNDPROC)(HWND,UINT,WPARAM,LPARAM);
typedef struct { HWND hwnd;UINT message;WPARAM wParam;LPARAM lParam; } MSG;
typedef struct { unsigned int style;WNDPROC lpfnWndProc;int cbClsExtra,cbWndExtra;
 HINSTANCE hInstance;HANDLE hIcon,hCursor,hbrBackground;LPCSTR lpszMenuName,lpszClassName; } WNDCLASS;
#define TRUE 1
#define FALSE 0
#define WM_TIMER 0x0113
#define WM_USER 0x0400
#define PM_REMOVE 1
#define LOBYTE(v) ((BYTE)((v)&255U))
#define HIBYTE(v) ((BYTE)(((v)>>8)&255U))
#define LOWORD(v) ((WORD)((DWORD)(v)&65535U))
#define HIWORD(v) ((WORD)(((DWORD)(v)>>16)&65535U))
#define MAKEWORD(lo,hi) ((WORD)((BYTE)(lo)|((WORD)(BYTE)(hi)<<8)))
#define MAKELONG(lo,hi) ((LONG)((DWORD)(WORD)(lo)|((DWORD)(WORD)(hi)<<16)))
DWORD GetTickCount(void);
BOOL PeekMessage(MSG *,HWND,UINT,UINT,UINT);
BOOL TranslateMessage(const MSG *);
LONG DispatchMessage(const MSG *);
BOOL IsWindow(HWND);
BOOL PostMessage(HWND,UINT,WPARAM,LPARAM);
LONG DefWindowProc(HWND,UINT,WPARAM,LPARAM);
FARPROC MakeProcInstance(FARPROC,HINSTANCE);
void FreeProcInstance(FARPROC);
WORD RegisterClass(const WNDCLASS *);
BOOL UnregisterClass(LPCSTR,HINSTANCE);
HWND CreateWindow(LPCSTR,LPCSTR,DWORD,int,int,int,int,HWND,HANDLE,HINSTANCE,void *);
BOOL DestroyWindow(HWND);
UINT SetTimer(HWND,UINT,UINT,FARPROC);
BOOL KillTimer(HWND,UINT);
#endif
