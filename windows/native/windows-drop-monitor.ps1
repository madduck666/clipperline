# Observe native drag sessions without reading clipboard data or capturing input.
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class DropShelfMonitor {
 delegate void EventProc(IntPtr hook,uint ev,IntPtr hwnd,int obj,int child,uint thread,uint time);
 delegate bool EnumProc(IntPtr hwnd,IntPtr parameter);
 [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min,uint max,IntPtr module,EventProc callback,uint process,uint thread,uint flags);
 [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr parameter);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hwnd);
 [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
 static EventProc callback=OnEvent;
 static bool active;
 static void OnEvent(IntPtr hook,uint ev,IntPtr hwnd,int obj,int child,uint thread,uint time) {
  if(ev==0xE) {
   if(active)return;active=true;
   var windows=new List<string>();
   EnumWindows(delegate(IntPtr w,IntPtr p){Rect r;if(windows.Count<64&&IsWindowVisible(w)&&!IsIconic(w)&&GetWindowTextLength(w)>0&&GetWindowRect(w,out r)&&r.Right>r.Left&&r.Bottom>r.Top)windows.Add("{\"x\":"+r.Left+",\"y\":"+r.Top+",\"width\":"+(r.Right-r.Left)+",\"height\":"+(r.Bottom-r.Top)+"}");return true;},IntPtr.Zero);
   Console.WriteLine("{\"drag\":true,\"windows\":["+String.Join(",",windows)+"]}");Console.Out.Flush();
  } else if(ev==0xF) End();
 }
 static void End(){if(!active)return;active=false;Console.WriteLine("{\"drag\":false}");Console.Out.Flush();}
 public static void Run(){
  var hook=SetWinEventHook(0xE,0xF,IntPtr.Zero,callback,0,0,0);
  if(hook==IntPtr.Zero)throw new InvalidOperationException("Drag observation could not start.");
  var timer=new Timer();timer.Interval=100;timer.Tick+=delegate{if(active&&GetAsyncKeyState(1)>=0)End();};timer.Start();
  try{Application.Run();}finally{timer.Dispose();UnhookWinEvent(hook);}
 }
}
'@
[DropShelfMonitor]::Run()
