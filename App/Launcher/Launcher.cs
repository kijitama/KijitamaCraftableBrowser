using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
[assembly: AssemblyTitle("KijitamaCraftableBrowser")]
[assembly: AssemblyProduct("KijitamaCraftableBrowser")]
class Launcher {
 [STAThread] static int Main(string[] args) {
  bool shiftAtLaunch=(Control.ModifierKeys & Keys.Shift)==Keys.Shift;
  try {
   string root=AppDomain.CurrentDomain.BaseDirectory;
   string bootstrap=Path.Combine(root,"App","Launcher","Bootstrap.ps1");
   if(!File.Exists(bootstrap)) throw new FileNotFoundException("起動用ファイルがありません。ZIPをすべて展開してください。");
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe");
   string arguments="-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " + (char)34 + bootstrap + (char)34;
   arguments+=" -ShiftAtLaunch " + (shiftAtLaunch ? "1" : "0");
   var info=new ProcessStartInfo(ps,arguments);
   info.UseShellExecute=false; info.CreateNoWindow=true; info.WorkingDirectory=root;
   using(var process=Process.Start(info)){ process.WaitForExit(); return process.ExitCode; }
  } catch(Exception e) { MessageBox.Show(e.Message,"起動できませんでした",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
 }
}

