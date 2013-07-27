/**
 * Various wrapper and utility code for the Windows API.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.windows;

import std.exception;
import std.string;
import std.typecons;
import std.utf;

import win32.windows;

LPCWSTR toWStringz(string s)
{
	return s is null ? null : toUTF16z(s);
}

class WindowsException : Exception { private this(string msg) { super(msg); } }

T wenforce(T)(T cond, string str=null)
{
	if (cond)
		return cond;

	auto code = GetLastError();

	wchar *lpMsgBuf = null;
	FormatMessageW(
		FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
		null,
		code,
		MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
		cast(LPWSTR)&lpMsgBuf,
		0,
		null);

	auto message = toUTF8(lpMsgBuf[0..wcslen(lpMsgBuf)]);
	if (lpMsgBuf)
		LocalFree(lpMsgBuf);

	message = strip(message);
	message ~= format(" (error %d)", code);
	if (str)
		message = str ~ ": " ~ message;
	throw new WindowsException(message);
}

void sendCopyData(HWND hWnd, DWORD n, in void[] buf)
{
	COPYDATASTRUCT cds;
	cds.dwData = n;
	cds.cbData = cast(uint)buf.length;
	cds.lpData = cast(PVOID)buf.ptr;
	SendMessage(hWnd, WM_COPYDATA, 0, cast(LPARAM)&cds);
}

enum MAPVK_VK_TO_VSC = 0;
void press(ubyte c, uint delay=0)
{
	if (c) keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), 0, 0);
	Sleep(delay);
	if (c) keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), KEYEVENTF_KEYUP, 0);
	Sleep(delay);
}

void pressOn(HWND h, ubyte c, uint delay=0)
{
	if (c) PostMessage(h, WM_KEYDOWN, c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16);
	Sleep(delay);
	if (c) PostMessage(h, WM_KEYUP  , c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16);
	Sleep(delay);
}

// Messages

void processWindowsMessages()
{
	MSG m;
	while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

void messageLoop()
{
	MSG m;
	while (GetMessageW(&m, null, 0, 0))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

// Windows

import std.range;

struct WindowIterator
{
private:
	LPCWSTR szClassName, szWindowName;
	HWND hParent, h;

public:
	@property
	bool empty() const { return h is null; }

	@property
	HWND front() const { return cast(HWND)h; }

	void popFront()
	{
		h = FindWindowExW(hParent, h, szClassName, szWindowName);
	}
}

WindowIterator windowIterator(string szClassName, string szWindowName, HWND hParent=null)
{
	auto iterator = WindowIterator(toWStringz(szClassName), toWStringz(szWindowName), hParent);
	iterator.popFront(); // initiate search
	return iterator;
}

private static wchar[0xFFFF] textBuf;

string getClassName(HWND h)
{
	return textBuf[0..wenforce(GetClassNameW(h, textBuf.ptr, textBuf.length), "GetClassNameW")].toUTF8();
}

string getWindowText(HWND h)
{
	return textBuf[0..wenforce(GetWindowTextW(h, textBuf.ptr, textBuf.length), "GetWindowTextW")].toUTF8();
}

/// Create an utility hidden window.
HWND createHiddenWindow(string name, WNDPROC proc)
{
	auto szName = toWStringz(name);

	HINSTANCE hInstance = GetModuleHandle(null);

	WNDCLASSEXW wcx;

	wcx.cbSize = wcx.sizeof;
	wcx.lpfnWndProc = proc;
	wcx.hInstance = hInstance;
	wcx.lpszClassName = szName;
	wenforce(RegisterClassExW(&wcx), "RegisterClassEx failed");

	HWND hWnd = CreateWindowW(
		szName,              // name of window class
		szName,              // title-bar string
		WS_OVERLAPPEDWINDOW, // top-level window
		CW_USEDEFAULT,       // default horizontal position
		CW_USEDEFAULT,       // default vertical position
		CW_USEDEFAULT,       // default width
		CW_USEDEFAULT,       // default height
		null,                // no owner window
		null,                // use class menu
		hInstance,           // handle to application instance
		null);               // no window-creation data
	wenforce(hWnd, "CreateWindow failed");

	return hWnd;
}

// Processes

static if (_WIN32_WINNT >= 0x500) {

struct CreatedProcessImpl
{
	PROCESS_INFORMATION pi;
	alias pi this;

	DWORD wait()
	{
		WaitForSingleObject(hProcess, INFINITE);
		DWORD dwExitCode;
		wenforce(GetExitCodeProcess(hProcess, &dwExitCode), "GetExitCodeProcess");
		return dwExitCode;
	}

	~this()
	{
		CloseHandle(pi.hProcess);
		CloseHandle(pi.hThread);
	}
}

alias RefCounted!CreatedProcessImpl CreatedProcess;
CreatedProcess createProcess(string applicationName, string commandLine, STARTUPINFOW si = STARTUPINFOW.init)
{
	CreatedProcess result;
	wenforce(CreateProcessW(toWStringz(applicationName), cast(LPWSTR)toWStringz(commandLine), null, null, false, 0, null, null, &si, &result.pi), "CreateProcess");
	AllowSetForegroundWindow(result.dwProcessId);
	AttachThreadInput(GetCurrentThreadId(), result.dwThreadId, TRUE);
	AllowSetForegroundWindow(result.dwProcessId);
	return result;
}

enum TOKEN_ADJUST_SESSIONID = 0x0100;
//enum SecurityImpersonation = 2;
//enum TokenPrimary = 1;
alias extern(Windows) BOOL function(
  HANDLE hToken,
  DWORD dwLogonFlags,
  LPCWSTR lpApplicationName,
  LPWSTR lpCommandLine,
  DWORD dwCreationFlags,
  LPVOID lpEnvironment,
  LPCWSTR lpCurrentDirectory,
  LPSTARTUPINFOW lpStartupInfo,
  LPPROCESS_INFORMATION lpProcessInfo
) CreateProcessWithTokenWFunc;

/// Create a non-elevated process, if the current process is elevated.
CreatedProcess createDesktopUserProcess(string applicationName, string commandLine, STARTUPINFOW si = STARTUPINFOW.init)
{
	CreateProcessWithTokenWFunc CreateProcessWithTokenW = cast(CreateProcessWithTokenWFunc)GetProcAddress(GetModuleHandle("advapi32.dll"), "CreateProcessWithTokenW");

	HANDLE hShellProcess = null, hShellProcessToken = null, hPrimaryToken = null;
	HWND hwnd = null;
	DWORD dwPID = 0;

	// Enable SeIncreaseQuotaPrivilege in this process.  (This won't work if current process is not elevated.)
	HANDLE hProcessToken = null;
	wenforce(OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &hProcessToken), "OpenProcessToken failed");
	scope(exit) CloseHandle(hProcessToken);

	TOKEN_PRIVILEGES tkp;
	tkp.PrivilegeCount = 1;
	LookupPrivilegeValueW(null, SE_INCREASE_QUOTA_NAME.ptr, &tkp.Privileges()[0].Luid);
	tkp.Privileges()[0].Attributes = SE_PRIVILEGE_ENABLED;
	wenforce(AdjustTokenPrivileges(hProcessToken, FALSE, &tkp, 0, null, null), "AdjustTokenPrivileges failed");

	// Get an HWND representing the desktop shell.
	// CAVEATS:  This will fail if the shell is not running (crashed or terminated), or the default shell has been
	// replaced with a custom shell.  This also won't return what you probably want if Explorer has been terminated and
	// restarted elevated.
	hwnd = GetShellWindow();
	enforce(hwnd, "No desktop shell is present");

	// Get the PID of the desktop shell process.
	GetWindowThreadProcessId(hwnd, &dwPID);
	enforce(dwPID, "Unable to get PID of desktop shell.");

	// Open the desktop shell process in order to query it (get the token)
	hShellProcess = wenforce(OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, dwPID), "Can't open desktop shell process");
	scope(exit) CloseHandle(hShellProcess);

	// Get the process token of the desktop shell.
	wenforce(OpenProcessToken(hShellProcess, TOKEN_DUPLICATE, &hShellProcessToken), "Can't get process token of desktop shell");
	scope(exit) CloseHandle(hShellProcessToken);

	// Duplicate the shell's process token to get a primary token.
	// Based on experimentation, this is the minimal set of rights required for CreateProcessWithTokenW (contrary to current documentation).
	const DWORD dwTokenRights = TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
	wenforce(DuplicateTokenEx(hShellProcessToken, dwTokenRights, null, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenPrimary, &hPrimaryToken), "Can't get primary token");
	scope(exit) CloseHandle(hPrimaryToken);

	CreatedProcess result;

	// Start the target process with the new token.
	wenforce(CreateProcessWithTokenW(
		hPrimaryToken,
		0,
		toWStringz(applicationName), cast(LPWSTR)toWStringz(commandLine),
		0,
		null,
		null,
		&si,
		&result.pi,
	), "CreateProcessWithTokenW failed");

	AllowSetForegroundWindow(result.dwProcessId);
	AttachThreadInput(GetCurrentThreadId(), result.dwThreadId, TRUE);
	AllowSetForegroundWindow(result.dwProcessId);

	return result;
}

} // _WIN32_WINNT >= 0x500

int messageBox(string message, string title, int style=0)
{
	return MessageBoxW(null, toWStringz(message), toWStringz(title), style);
}

uint getLastInputInfo()
{
	LASTINPUTINFO lii = { LASTINPUTINFO.sizeof };
	wenforce(GetLastInputInfo(&lii), "GetLastInputInfo");
	return lii.dwTime;
}

// ---------------------------------------

import std.traits;

/// Given a static function declaration, generate a loader with the same name in the current scope
/// that loads the function dynamically from the given DLL.
mixin template DynamicLoad(alias F, string DLL, string NAME=__traits(identifier, F))
{
	static ReturnType!F loader(ARGS...)(ARGS args)
	{
		import win32.windef;

		alias typeof(&F) FP;
		static FP fp = null;
		if (!fp)
		{
			HMODULE dll = wenforce(LoadLibrary(DLL), "LoadLibrary");
			fp = cast(FP)wenforce(GetProcAddress(dll, NAME), "GetProcAddress");
		}
		return fp(args);
	}

	mixin(`alias loader!(ParameterTypeTuple!F) ` ~ NAME ~ `;`);
}

///
unittest
{
	mixin DynamicLoad!(GetVersion, "kernel32.dll");
	GetVersion(); // called via GetProcAddress
}
